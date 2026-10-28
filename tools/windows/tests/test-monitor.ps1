# 轻量监控定向回归：不加载 GGUF、不启动 Gufo、不要求 Pester。
# Windows 原生采样单列；非 Windows 只编译声明，不执行 Win32 API。
param([string]$WindowsTools = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $WindowsTools 'launcher-core.ps1')
. (Join-Path $WindowsTools 'launcher-monitor.ps1')
. (Join-Path $WindowsTools 'monitor-telemetry.ps1')
$script:Passed = 0; $script:Failed = 0; $script:Skipped = 0

function Assert-True([bool]$Condition, [string]$Message = '断言失败') {
    if (-not $Condition) { throw $Message }
}
function Assert-Equal($Actual, $Expected, [string]$Message = '实际值与预期不一致') {
    if ($Actual -cne $Expected) { throw "$Message；实际=[$Actual]，预期=[$Expected]" }
}
function Assert-Near([double]$Actual, [double]$Expected, [double]$Tolerance = 0.001) {
    if ([Math]::Abs($Actual - $Expected) -gt $Tolerance) { throw "实际=[$Actual]，预期=[$Expected]" }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host "[PASS] $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "[FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Skip-Case([string]$Name, [string]$Reason) {
    $script:Skipped++; Write-Host "[SKIP] $Name : $Reason" -ForegroundColor Yellow
}
function Get-FunctionDefinitions([string]$Path, [string[]]$Names = @()) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw ($errors | Out-String) }
    @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            ($Names.Count -eq 0 -or $Names -contains $node.Name)
    }, $true) | ForEach-Object { $_.Extent.Text })
}

function Invoke-StartScenario([string[]]$Definitions, [string]$Scenario, [string]$ModuleRoot) {
    # 真实入口函数 + 隔离 runspace，临时监控模块仅记录加载/调用，不接触原生 API。
    $harness = @'
param([string]$DefinitionFile, [string]$Scenario, [string]$ModuleRoot)
. $DefinitionFile
$script:exe = 'test-only-gufo.exe'; $script:llmHelp = 'Usage: gufo serve llm [OPTIONS]'
$script:configPath = 'not-written.json'; $script:roots = @('test-models')
$script:DryRun = ($Scenario -eq 'DryRun'); $script:Foreground = ($Scenario -eq 'Foreground')
$script:ModuleLoads = 0; $script:HostLoads = 0; $script:MonitorCalls = 0; $script:Spawns = 0; $script:Saves = 0
$script:MonitorPort = 0; $script:MonitorPipe = ''; $script:MonitorKeyMatches = $false; $script:SavedKey = $false
$script:Disposed = 0; $script:Killed = 0; $script:Pauses = 0; $script:PortChecks = 0
$script:WaitCalls = 0; $script:NoNewWindowUsed = $false; $script:MonitorThrows = ($Scenario -eq 'MonitorFailure')
$script:Events = New-Object 'Collections.Generic.List[string]'
function Get-GufoModelRecord { param([string]$Path) [pscustomobject]@{ Path = $Path; Kind = 'target'; Complete = $true } }
function New-GufoArguments { param($Model, $Options, $ApiKey) @('serve', 'llm', '--model', $Model.Path) }
function Read-GufoSecret { 'test-secret-do-not-save' }
function Assert-GufoArguments { param($Arguments, $HelpText) }
function Format-GufoCommand { param($ExePath, $Arguments) 'safe-test-command' }
function Assert-GufoPort { param($ListenHost, $Port) $script:PortChecks++ }
function Get-Process { [CmdletBinding()]param([string]$Name) }
function Write-Host { param($Object, $ForegroundColor) }
function Write-Warning { param([string]$Message) $script:Events.Add('warning:' + $Message) }
function Wait-GufoMenu { $script:Pauses++ }
function Push-Location { param($Path) }
function Pop-Location { }
function Save-GufoSettings { param($Path, $Model, $Options, $Roots) $script:Saves++; $script:Events.Add('save'); $script:SavedKey = ($Options | ConvertTo-Json).Contains('test-secret-do-not-save') }
function Start-Process {
    param($FilePath, $ArgumentList, $WorkingDirectory, [switch]$PassThru, [switch]$NoNewWindow)
    $script:Spawns++; $script:NoNewWindowUsed = [bool]$NoNewWindow
    $process = [pscustomobject]@{ Id = 12345; ExitCode = 0 }
    $process | Add-Member ScriptMethod WaitForExit { param($Milliseconds) $script:WaitCalls++; return $false }
    $process | Add-Member ScriptMethod Dispose { $script:Disposed++ }
    $process | Add-Member ScriptMethod Kill { $script:Killed++ }
    $process
}
$options = New-GufoOptions
$options.Monitor = ($Scenario -ne 'Disabled')
if ($Scenario -eq 'EnabledKey') { $options.Host = '0.0.0.0'; $options.Port = 18080 }
$model = [pscustomobject]@{ Path = 'test-model.gguf'; Name = '测试模型'; Complete = $true; Kind = 'target' }
$result = Start-GufoSelection $model $options
[pscustomobject]@{
    Result = $result; ModuleLoads = $script:ModuleLoads; HostLoads = $script:HostLoads; MonitorCalls = $script:MonitorCalls
    MonitorPort = $script:MonitorPort; MonitorPipe = $script:MonitorPipe; MonitorKeyMatches = $script:MonitorKeyMatches; SavedKey = $script:SavedKey
    Spawns = $script:Spawns; Saves = $script:Saves; Disposed = $script:Disposed; Killed = $script:Killed
    Pauses = $script:Pauses; PortChecks = $script:PortChecks; WaitCalls = $script:WaitCalls
    NoNewWindowUsed = $script:NoNewWindowUsed; MonitorSaved = $options.Monitor
    Events = ($script:Events -join ',')
}
'@
    $definitionFile = Join-Path $ModuleRoot 'real-start-functions.ps1'
    [IO.File]::WriteAllText($definitionFile, ($Definitions -join [Environment]::NewLine), (New-Object Text.UTF8Encoding($true)))
    $runner = [PowerShell]::Create()
    try {
        [void]$runner.AddScript($harness)
        [void]$runner.AddParameter('DefinitionFile', $definitionFile)
        [void]$runner.AddParameter('Scenario', $Scenario)
        [void]$runner.AddParameter('ModuleRoot', $ModuleRoot)
        $result = @($runner.Invoke())
        if ($runner.HadErrors) { throw ($runner.Streams.Error | Out-String) }
        Assert-Equal $result.Count 1 '启动控制流应只返回一个结果'
        $result[0]
    } finally { $runner.Dispose() }
}

function Measure-WindowsConsoleCells([string]$Text) {
    $width = 0
    $elements = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($elements.MoveNext()) {
        $element = [string]$elements.Current
        $point = [char]::ConvertToUtf32($element, 0)
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($element, 0)
        if ($category -in @([Globalization.UnicodeCategory]::NonSpacingMark, [Globalization.UnicodeCategory]::EnclosingMark, [Globalization.UnicodeCategory]::Format)) { continue }
        if (($point -ge 0x2500 -and $point -le 0x259f) -or
            ($point -ge 0x2e80 -and $point -le 0xa4cf) -or
            ($point -ge 0xff01 -and $point -le 0xff60)) { $width += 2 }
        else { $width++ }
    }
    $width
}

function Invoke-MonitorRender([string[]]$Definitions, $Sample, $History, [int]$Width, [int]$Height = 30, $Telemetry = $null, $LastRequest = $null) {
    $Definitions = @($Definitions) + @(${function:Measure-WindowsConsoleCells}.ToString().Insert(0, 'function Measure-WindowsConsoleCells {') + '}')
    $harness = @'
param([string[]]$Definitions, $Sample, $History, [int]$Width, [int]$Height, $Telemetry, $LastRequest)
foreach ($definition in $Definitions) { . ([scriptblock]::Create($definition)) }
$script:Width = $Width; $script:Height = $Height
$script:Rows = New-Object 'Collections.Generic.List[string]'
function Clear-GufoMenu { }
function Get-GufoConsoleWidth { $script:Width }
function Get-GufoMonitorHeight { $script:Height }
function Write-Host { param($Object, $ForegroundColor) $script:Rows.Add([string]$Object) }
Show-GufoMonitor $Sample $History 12345 (64MB) '模型：Qwen3.8-Flash-Next-UD-Q4_K_XL 中文标题' $Telemetry $LastRequest
[pscustomobject]@{
    Lines = @($script:Rows.ToArray())
    Widths = @($script:Rows | ForEach-Object { Measure-WindowsConsoleCells $_ })
}
'@
    $runner = [PowerShell]::Create()
    try {
        [void]$runner.AddScript($harness)
        [void]$runner.AddParameter('Definitions', $Definitions)
        [void]$runner.AddParameter('Sample', $Sample)
        [void]$runner.AddParameter('History', $History)
        [void]$runner.AddParameter('Width', $Width)
        [void]$runner.AddParameter('Height', $Height)
        [void]$runner.AddParameter('Telemetry', $Telemetry)
        [void]$runner.AddParameter('LastRequest', $LastRequest)
        $result = @($runner.Invoke())
        if ($runner.HadErrors) { throw ($runner.Streams.Error | Out-String) }
        Assert-Equal $result.Count 1 '绘制函数应只返回一个结果'
        $result[0]
    } finally { $runner.Dispose() }
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('gufo-monitor-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try {
    Test-Case '默认关闭监控且无历史样本时平均写入不可用' {
        Assert-Equal (New-GufoOptions).Monitor $false
        $history = New-GufoMonitorHistory
        Assert-Equal $history.Samples.Count 0
        Assert-True ($null -eq (Get-GufoMonitorWriteAverage $history))
    }
    Test-Case '有效样本按真实间隔累计写入而不是固定假定两秒' {
        $history = New-GufoMonitorHistory
        Update-GufoMonitorHistory $history 2 $true 100
        Update-GufoMonitorHistory $history 5 $true 200
        Assert-Near $history.TotalWriteBytes 1200
        Assert-Near $history.ObservedSeconds 7
        Assert-Near (Get-GufoMonitorWriteAverage $history).Rate (1200.0 / 7)
    }
    Test-Case '30秒窗口按时间加权并裁掉最旧样本的超出部分' {
        $history = New-GufoMonitorHistory
        Update-GufoMonitorHistory $history 20 $true 100
        Update-GufoMonitorHistory $history 20 $true 400
        $average = Get-GufoMonitorWriteAverage $history
        Assert-Near $average.Seconds 30
        Assert-Near $average.Rate 300
        Assert-Near $history.TotalWriteBytes 10000
    }
    Test-Case '持续运行一万轮仍然只保留有界短窗口' {
        $history = New-GufoMonitorHistory
        for ($index = 0; $index -lt 10000; $index++) { Update-GufoMonitorHistory $history 2 $true 1024 }
        Assert-True ($history.Samples.Count -le 16)
        Assert-Near (Get-GufoMonitorWriteAverage $history).Seconds 30
        Assert-Near $history.TotalWriteBytes 20480000
    }
    Test-Case '失效磁盘样本不累计且近期平均不可伪装成零写入' {
        $history = New-GufoMonitorHistory
        Update-GufoMonitorHistory $history 2 $true 500
        Update-GufoMonitorHistory $history 2 $false 0
        Assert-Near $history.TotalWriteBytes 1000
        Assert-Near $history.ObservedSeconds 2
        Assert-True ($null -eq (Get-GufoMonitorWriteAverage $history))
    }
    Test-Case '失效样本移出30秒窗口后平均值恢复有效' {
        $history = New-GufoMonitorHistory
        Update-GufoMonitorHistory $history 2 $false 0
        for ($index = 0; $index -lt 15; $index++) { Update-GufoMonitorHistory $history 2 $true 123 }
        Assert-Near (Get-GufoMonitorWriteAverage $history).Rate 123
        Assert-Near (Get-GufoMonitorWriteAverage $history).Seconds 30
    }
    Test-Case '零速率的有效样本与采集失败有明确区分' {
        $history = New-GufoMonitorHistory
        Update-GufoMonitorHistory $history 2 $true 0
        Assert-Near (Get-GufoMonitorWriteAverage $history).Rate 0
        Assert-Near $history.ObservedSeconds 2
    }
    Test-Case '负速率与NaN或Infinity不得污染累计和平均值' {
        foreach ($rate in @(-1, [double]::NaN, [double]::PositiveInfinity)) {
            $history = New-GufoMonitorHistory
            Update-GufoMonitorHistory $history 2 $true $rate
            Assert-Near $history.TotalWriteBytes 0
            Assert-Near $history.ObservedSeconds 0
            Assert-True ($null -eq (Get-GufoMonitorWriteAverage $history))
        }
    }
    Test-Case '无效或倒退采样时长不加入窗口' {
        $history = New-GufoMonitorHistory
        foreach ($seconds in @(0, -2, [double]::NaN, [double]::PositiveInfinity)) {
            Update-GufoMonitorHistory $history $seconds $true 100
        }
        Assert-Equal $history.Samples.Count 0
        Assert-Near $history.TotalWriteBytes 0
    }
    Test-Case '长暂停只占最近30秒窗口而累计保留观测时长' {
        $history = New-GufoMonitorHistory
        Update-GufoMonitorHistory $history 120 $true 100
        Assert-Near (Get-GufoMonitorWriteAverage $history).Seconds 30
        Assert-Near $history.ObservedSeconds 120
        Assert-Near $history.TotalWriteBytes 12000
    }
    Test-Case '监控开关写回设置但不混入Gufo命令参数' {
        $model = [pscustomobject]@{ Path = 'test.gguf'; Complete = $true; Kind = 'target' }
        $options = New-GufoOptions
        $without = @(New-GufoArguments $model $options)
        $options.Monitor = $true
        $with = @(New-GufoArguments $model $options)
        Assert-Equal ($with -join '|') ($without -join '|')
        $config = Join-Path $temporary 'monitor-settings.json'
        Save-GufoSettings $config $model $options @('test-models')
        Assert-Equal (Read-GufoSettings $config).Options.Monitor $true
    }
    Test-Case '旧设置缺少监控字段时继续默认关闭' {
        $config = Join-Path $temporary 'old-settings.json'
        [IO.File]::WriteAllText($config, '{"SchemaVersion":1,"ModelPath":"test.gguf","Roots":[],"Options":{"Context":65536}}')
        $state = Read-GufoSettings $config
        Assert-Equal $state.Options.Monitor $false
        Assert-Equal $state.Options.Context 65536
    }
    Test-Case '全部PowerShell监控源码可解析且C#原生声明可编译' {
        [void](Get-FunctionDefinitions (Join-Path $WindowsTools 'launcher-monitor.ps1'))
        [void](Get-FunctionDefinitions (Join-Path $WindowsTools 'launcher.ps1'))
        if (-not ('GufoMonitor.Sampler' -as [type])) { Add-Type -Path (Join-Path $WindowsTools 'monitor-native.cs') }
        Assert-True ($null -ne ('GufoMonitor.Sampler' -as [type]))
    }

    Test-Case '有效零写入和小量写入保留B或KiB精度' {
        Assert-Equal (Format-GufoMonitorBytes 0) '0 B'
        Assert-Equal (Format-GufoMonitorBytes 100) '100 B'
        Assert-True ((Format-GufoMonitorBytes 1024) -match 'KiB$')
        Assert-Equal (Format-GufoMonitorBytes $null) '不可用'
    }
    Test-Case '趋势区分零写入、失效和真实数据且限定显示长度' {
        $history = New-GufoMonitorHistory
        Assert-True ((Get-GufoMonitorTrend $history 'Write' 4) -match '采样中')
        Update-GufoMonitorHistory $history 2 $true 100
        Update-GufoMonitorHistory $history 2 $true 0
        Update-GufoMonitorHistory $history 2 $false 0
        Assert-True ((Get-GufoMonitorTrend $history 'Write' 4).EndsWith('@.?'))
        Assert-Equal (Get-GufoMonitorTrend $history 'Write' 2).Length 2
    }
    Test-Case '系统内存趋势使用总量与可用量且磁盘读取独立记录' {
        $history = New-GufoMonitorHistory
        $snapshot = [pscustomobject]@{
            DiskValid = $true; DiskReadBytesPerSecond = 2048
            SystemMemoryValid = $true; TotalMemoryBytes = 10000; AvailableMemoryBytes = 2500
        }
        Update-GufoMonitorHistory $history 2 $true 4096 $snapshot
        $item = $history.Samples.Peek()
        Assert-Near $item.ReadRate 2048
        Assert-Near $item.MemoryPercent 75
        Assert-True ((Get-GufoMonitorTrend $history 'Memory' 4).EndsWith('*'))
    }
    $renderDefinitions = @(Get-FunctionDefinitions (Join-Path $WindowsTools 'launcher-monitor.ps1'))
    $renderDefinitions += @(Get-FunctionDefinitions (Join-Path $WindowsTools 'launcher.ps1') @(
        'Get-GufoCellWidth', 'Split-GufoConsoleLine', 'Write-GufoMenuLine'))
    $sample = [pscustomobject]@{
        Alive = $true; ProcessMemoryValid = $true; WorkingSetBytes = 12GB; PrivateBytes = 20GB
        SystemMemoryValid = $true; TotalMemoryBytes = 128GB; AvailableMemoryBytes = 16GB
        DiskValid = $true; DiskReadBytesPerSecond = 24MB; DiskWriteBytesPerSecond = 3MB; DiskError = ''
    }
    $telemetry = [pscustomobject]@{
        Status = 'decode'; Error = ''; LivePrefillTokPerSec = 321.0; LiveDecodeTokPerSec = 23.4
        ActiveRequests = 1; QueuedRequests = 0; PromptProcessed = 1200; GeneratedTokens = 64
    }
    $lastRequest = [pscustomobject]@{
        RequestId = 'r42'; TtftMs = 125.5; PrefillTokPerSec = 888.0; DecodeTokPerSec = 25.6
        PromptTokens = 1450; PrefillTokens = 1200; GeneratedTokens = 128; CachedTokens = 250
        QueueMs = 10.0; DurationMs = 5200.0
    }
    $renderHistory = New-GufoMonitorHistory
    Update-GufoMonitorHistory $renderHistory 2 $true $sample.DiskWriteBytesPerSecond $sample
    Test-Case '中文仪表盘显示内存磁盘均值累计和监控自身且标清口径' {
        $rendered = Invoke-MonitorRender $renderDefinitions $sample $renderHistory 120
        $text = $rendered.Lines -join "`n"
        foreach ($needle in @('中文监控', 'Gufo 工作集', 'Gufo 私有提交', '系统可用', '近30秒平均写入',
            '本次写入估算', '监控总工作集', '磁盘是整机总量', '工作集非完整 GPU 分配', 'Q/Esc', '无监控日志')) {
            Assert-True ($text.Contains($needle)) "缺少监控信息或口径：$needle"
        }
        Assert-True ($text -notmatch 'True|False')
    }
    Test-Case '宽终端使用双栏框面板且长中文标题不溢出' {
        $rendered = Invoke-MonitorRender $renderDefinitions $sample $renderHistory 120
        Assert-True (@($rendered.Lines | Where-Object { $_ -match '^\+.*\+  \+.*\+$' }).Count -eq 2)
        foreach ($width in $rendered.Widths) { Assert-True ($width -le 120) "超过120列：$width" }
    }
    Test-Case '普通终端使用上下框且窄窗口保持每行列宽' {
        foreach ($width in @(52, 39, 20, 4)) {
            $rendered = Invoke-MonitorRender $renderDefinitions $sample $renderHistory $width 40
            foreach ($actual in $rendered.Widths) { Assert-True ($actual -le $width) "超过${width}列：$actual" }
            if ($width -eq 52) { Assert-Equal @($rendered.Lines | Where-Object { $_ -match '^\+- ' }).Count 3 }
            if ($width -lt 40) { Assert-Equal @($rendered.Lines | Where-Object { $_ -match '^\+- ' }).Count 0 }
        }
    }
    Test-Case '52列25行矮窗保留标题全部关键指标与退出提示且不滚屏' {
        $warming = [pscustomobject]@{
            Alive = $true; ProcessMemoryValid = $true; WorkingSetBytes = 12GB; PrivateBytes = 20GB
            SystemMemoryValid = $true; TotalMemoryBytes = 128GB; AvailableMemoryBytes = 16GB
            DiskValid = $false; DiskReadBytesPerSecond = 0; DiskWriteBytesPerSecond = 0; DiskError = '计数器预热中'
        }
        foreach ($fixture in @($sample, $warming)) {
            $rendered = Invoke-MonitorRender $renderDefinitions $fixture $renderHistory 52 25 $telemetry $lastRequest
            Assert-True ($rendered.Lines.Count -le 25) "52×25仪表盘输出了$($rendered.Lines.Count)行，会滚掉头部。"
            foreach ($actual in $rendered.Widths) { Assert-True ($actual -le 52) "超过52列：$actual" }
            $text = $rendered.Lines -join "`n"
            foreach ($needle in @('中文监控', 'Gufo 工作集', 'Gufo 私有提交', '系统已用 / 总量', '系统可用',
                '监控总工作集', '读取：', '写入：', '写趋势', '近30秒平均写入', '本次写入估算', 'Q/Esc', 'Gufo 继续',
                '首 token 延迟(TTFT)', '125.5 ms', '预填充 Prefill', '生成 Decode', '实时吞吐')) {
                Assert-True ($text.Contains($needle)) "52×25矮窗遗漏：$needle"
            }
            Assert-True ($rendered.Lines[0].Contains('中文监控'))
            Assert-True ($text -notmatch '读趋势|系统占用：') '矮窗应省略装饰趋势以保留核心数值。'
        }
    }
    Test-Case '首token延迟预填充和decode显示最近请求而实时吞吐保持独立' {
        $rendered = Invoke-MonitorRender $renderDefinitions $sample $renderHistory 120 35 $telemetry $lastRequest
        $text = $rendered.Lines -join "`n"
        foreach ($needle in @('服务状态：生成中', '125.5 ms', '最近请求 r42', '预填充 Prefill',
            '888.0 tok/s', '生成 Decode', '25.6 tok/s', '实时吞吐', '321.0 tok/s', '23.4 tok/s', '全服务计数差分')) {
            Assert-True ($text.Contains($needle)) "缺少性能指标或口径：$needle"
        }
        Assert-True (@($rendered.Lines | Where-Object { $_ -match '首 token 延迟.*实时吞吐' }).Count -eq 0)
    }
    Test-Case '尚无已完成请求时不把首token延迟或最近请求速度伪装成零' {
        $rendered = Invoke-MonitorRender $renderDefinitions $sample $renderHistory 120 35 $telemetry $null
        $text = $rendered.Lines -join "`n"
        Assert-True ($text.Contains('首 token 延迟(TTFT)：等待一次请求完成'))
        Assert-True ($text.Contains('预填充 Prefill：等待一次请求完成'))
        Assert-True ($text -notmatch 'TTFT[）)]：0(?:\.0)? ms')
        Assert-True ($text.Contains('实时吞吐'))
    }
    Test-Case 'ASCII框与趋势经Windows歧义字符双列oracle仍无超宽或二次拆框' {
        # 这个fixture会抓住旧实现的横线字符数当列宽问题。
        Assert-True ((Measure-WindowsConsoleCells ('┌' + ('─' * 118) + '┐')) -gt 120)
        $rendered = Invoke-MonitorRender $renderDefinitions $sample $renderHistory 120 35 $telemetry $lastRequest
        Assert-True (($rendered.Lines -join "`n") -notmatch '[\u2500-\u259f]') '不应输出宿主可能误判双列的框线或块图。'
        foreach ($actual in $rendered.Widths) { Assert-True ($actual -le 120) "Windows oracle检测到超宽：$actual" }
        $panelBorders = @($rendered.Lines | Where-Object { $_ -match '^\+.*\+$' })
        Assert-Equal $panelBorders.Count 4 '推理框上下两行和双栏框上下两行应保持完整。'
        foreach ($border in $panelBorders) { Assert-True ((Measure-WindowsConsoleCells $border) -ge 118) '框线被二次切开。' }
    }
    Test-Case '最近完成请求统计严格校验数字且零输出时没有TTFT' {
        $complete = [pscustomobject]@{ last = [pscustomobject]@{
            request_id = 'r42'; ttft_ms = 125.5; prefill_tps = 888; decode_tps = 25.6
            prompt_tokens = 1450; prefill_tokens = 1200; generated_tokens = 128; cached_tokens = 250
            queue_ms = 10; duration_ms = 5200
        } }
        $parsed = Get-GufoLastRequest $complete
        Assert-Near $parsed.TtftMs 125.5
        Assert-Near $parsed.PrefillTokPerSec 888
        Assert-Equal $parsed.RequestId 'r42'
        $complete.last.generated_tokens = 0
        Assert-True ($null -eq (Get-GufoLastRequest $complete).TtftMs)
        $complete.last.ttft_ms = 'NaN'
        Assert-True ($null -eq (Get-GufoLastRequest $complete))
        Assert-True ($null -eq (Get-GufoLastRequest ([pscustomobject]@{ last = [pscustomobject]@{ request_id = 'r1' } })))
    }
    Test-Case '采集失败时仪表盘显示原因和不可用而不显示零写入' {
        $unavailable = [pscustomobject]@{
            Alive = $true; ProcessMemoryValid = $false; WorkingSetBytes = 0; PrivateBytes = 0
            SystemMemoryValid = $false; TotalMemoryBytes = 0; AvailableMemoryBytes = 0
            DiskValid = $false; DiskReadBytesPerSecond = 0; DiskWriteBytesPerSecond = 0; DiskError = 'PDH 测试故障'
        }
        $rendered = Invoke-MonitorRender $renderDefinitions $unavailable (New-GufoMonitorHistory) 120
        $text = $rendered.Lines -join "`n"
        Assert-True ($text.Contains('PDH 测试故障'))
        Assert-True ($text.Contains('读取：不可用'))
        Assert-True ($text.Contains('写入：不可用'))
        Assert-True ($text.Contains('Gufo 工作集：不可用'))
        Assert-True ($text.Contains('尚无有效样本'))
        Assert-True ($text -notmatch '写入：0 B/s')
    }

    Test-Case '设置菜单按M直接切换监控并可原路返回' {
        $menu = @(Get-FunctionDefinitions (Join-Path $WindowsTools 'launcher.ps1') @('Edit-GufoFeatures'))
        $runner = [PowerShell]::Create()
        try {
            [void]$runner.AddScript(@'
param([string]$Definition)
. ([scriptblock]::Create($Definition))
$script:Keys = New-Object 'Collections.Generic.Queue[string]'
$script:Keys.Enqueue('M'); $script:Keys.Enqueue('B')
$script:Draws = 0
function Read-GufoMenuKey { $script:Keys.Dequeue() }
function Show-GufoFeatures { param($Model, $Options) $script:Draws++ }
$options = @{ Monitor = $false }
$returned = Edit-GufoFeatures $null $options $null
[pscustomobject]@{ Monitor = $options.Monitor; Returned = $returned; Draws = $script:Draws; Keys = $script:Keys.Count }
'@)
            [void]$runner.AddParameter('Definition', $menu[0])
            $result = @($runner.Invoke())
            if ($runner.HadErrors) { throw ($runner.Streams.Error | Out-String) }
            Assert-Equal $result[0].Monitor $true
            Assert-Equal $result[0].Returned $false
            Assert-Equal $result[0].Draws 2
            Assert-Equal $result[0].Keys 0
        } finally { $runner.Dispose() }
    }

    $definitions = @(Get-FunctionDefinitions (Join-Path $WindowsTools 'launcher.ps1') @('Start-GufoSelection'))
    $definitions += @(Get-FunctionDefinitions (Join-Path $WindowsTools 'launcher-core.ps1') @('New-GufoOptions', 'ConvertTo-GufoArgumentString'))
    $spy = @'
$script:ModuleLoads++
$script:Events.Add('load')
function Start-GufoMonitor {
    param($Process, [string]$Caption, [int]$Port, [string]$ApiKey, [string]$StatsPipeName)
    $script:MonitorPort = $Port; $script:MonitorPipe = $StatsPipeName
    $script:MonitorKeyMatches = ($ApiKey -ceq 'test-secret-do-not-save')
    $script:MonitorCalls++
    $script:Events.Add('monitor')
    if ($script:MonitorThrows) { throw '测试注入：磁盘计数器不可用' }
}
'@
    [IO.File]::WriteAllText((Join-Path $temporary 'launcher-monitor.ps1'), $spy, (New-Object Text.UTF8Encoding($true)))
    $hostSpy = @'
$script:HostLoads++
$script:Events.Add('host-load')
function Start-GufoMonitoredEngine {
    param([string]$ExePath, [string[]]$Arguments)
    $script:Events.Add('host-start')
    $process = Start-Process -FilePath 'test-only-engine-host.exe' -ArgumentList 'not-run' -PassThru
    [pscustomobject]@{ Process = $process; PipeName = 'gufo-stats-0123456789abcdef0123456789abcdef' }
}
'@
    [IO.File]::WriteAllText((Join-Path $temporary 'launcher-host.ps1'), $hostSpy, (New-Object Text.UTF8Encoding($true)))

    Test-Case '监控关闭时真实启动链不加载模块并只启动一个服务' {
        $run = Invoke-StartScenario $definitions 'Disabled' $temporary
        Assert-Equal $run.Result $true
        Assert-Equal $run.ModuleLoads 0
        Assert-Equal $run.HostLoads 0
        Assert-Equal $run.MonitorCalls 0
        Assert-Equal $run.Spawns 1
        Assert-Equal $run.Saves 1
        Assert-Equal $run.Disposed 1
        Assert-Equal $run.Killed 0
    }
    Test-Case '开启监控时真实启动链先保存再按需加载且复用目标进程' {
        $run = Invoke-StartScenario $definitions 'Enabled' $temporary
        Assert-Equal $run.Result $true
        Assert-Equal $run.ModuleLoads 1 ('module: ' + $run.Events)
        Assert-Equal $run.MonitorCalls 1 ('monitor: ' + $run.Events)
        Assert-Equal $run.Spawns 1
        Assert-Equal $run.Saves 1
        Assert-Equal $run.Events 'host-load,host-start,save,load,monitor'
        Assert-Equal $run.HostLoads 1
        Assert-Equal $run.MonitorPort 8080
        Assert-True ($run.MonitorPipe -match '^gufo-stats-[a-f0-9]{32}$')
        Assert-Equal $run.Killed 0
        Assert-Equal $run.Disposed 1
    }
    Test-Case '鉴权Key与端口仅传给本次监控而非设置文件' {
        $run = Invoke-StartScenario $definitions 'EnabledKey' $temporary
        Assert-Equal $run.Result $true
        Assert-Equal $run.Spawns 1
        Assert-Equal $run.MonitorPort 18080
        Assert-True $run.MonitorKeyMatches
        Assert-True (-not $run.SavedKey)
        Assert-True ($run.Events -notmatch 'test-secret-do-not-save')
    }
    Test-Case '监控失败时真实启动链仍返回成功且不重启或结束Gufo' {
        $run = Invoke-StartScenario $definitions 'MonitorFailure' $temporary
        Assert-Equal $run.Result $true
        Assert-Equal $run.Spawns 1
        Assert-Equal $run.MonitorCalls 1 ('monitor: ' + $run.Events)
        Assert-Equal $run.Killed 0
        Assert-Equal $run.Disposed 1
        Assert-True ($run.Events.Contains('warning:'))
    }
    Test-Case 'Foreground排障不加载监控并保留当前窗口与已选开关' {
        $run = Invoke-StartScenario $definitions 'Foreground' $temporary
        Assert-Equal $run.Result $true
        Assert-Equal $run.ModuleLoads 0
        Assert-Equal $run.HostLoads 0
        Assert-Equal $run.MonitorCalls 0
        Assert-Equal $run.NoNewWindowUsed $true
        Assert-Equal $run.MonitorSaved $true
        Assert-Equal $run.Spawns 1
        Assert-Equal $run.Saves 1
    }
    Test-Case 'DryRun即使开关开启也不加载监控不启动不写设置' {
        $run = Invoke-StartScenario $definitions 'DryRun' $temporary
        Assert-Equal $run.Result $true
        Assert-Equal $run.ModuleLoads 0
        Assert-Equal $run.HostLoads 0
        Assert-Equal $run.MonitorCalls 0
        Assert-Equal $run.Spawns 0
        Assert-Equal $run.Saves 0
        Assert-Equal $run.PortChecks 0
    }

    if ($env:OS -eq 'Windows_NT') {
        Test-Case 'Windows原生读取自身进程内存与系统内存' {
            $self = [Diagnostics.Process]::GetCurrentProcess(); $sampler = $null
            try {
                $sampler = New-Object GufoMonitor.Sampler -ArgumentList $self.Handle
                $sample = $sampler.Read()
                Assert-True $sample.Alive
                Assert-True $sample.ProcessMemoryValid
                Assert-True ($sample.WorkingSetBytes -gt 0)
                Assert-True $sample.SystemMemoryValid
                Assert-True ($sample.TotalMemoryBytes -ge $sample.AvailableMemoryBytes)
            } finally { if ($sampler) { $sampler.Dispose() }; $self.Dispose() }
        }
        $self = [Diagnostics.Process]::GetCurrentProcess(); $sampler = $null
        try {
            $sampler = New-Object GufoMonitor.Sampler -ArgumentList $self.Handle
            Start-Sleep -Milliseconds 2200
            $sample = $sampler.Read()
            if ($sample.DiskValid) {
                Test-Case 'Windows双样本物理盘读写返回非负有效值' {
                    Assert-True ($sample.DiskReadBytesPerSecond -ge 0)
                    Assert-True ($sample.DiskWriteBytesPerSecond -ge 0)
                }
            } else { Skip-Case 'Windows双样本物理盘读写' $sample.DiskError }
        } finally { if ($sampler) { $sampler.Dispose() }; $self.Dispose() }
    } else {
        Skip-Case 'Windows原生读取自身进程内存与系统内存' '当前为非Windows；未执行Win32 API'
        Skip-Case 'Windows双样本物理盘读写' '当前为非Windows；未执行PDH实采样'
    }
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
Write-Host ("监控定向回归：{0} 通过、{1} 失败、{2} 跳过。" -f $script:Passed, $script:Failed, $script:Skipped)
if ($script:Failed -gt 0) { exit 1 }
exit 0
