# 新启动器的无 GPU 回归测试；仅在系统临时目录创建测试文件。
# Windows PowerShell 5.1 / PowerShell 7 均可运行，无需 Pester。
param(
    [string]$CorePath = (Join-Path (Join-Path $PSScriptRoot '..') 'launcher-core.ps1')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $CorePath -PathType Leaf)) {
    Write-Error "找不到核心脚本：$CorePath"
    exit 1
}
. $CorePath

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message = '断言失败')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = '实际值与预期不一致')
    if ($Actual -cne $Expected) {
        throw "$Message；实际=[$Actual]，预期=[$Expected]"
    }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Message = '预期拒绝该输入')
    $rejected = $false
    try { & $Body | Out-Null } catch { $rejected = $true }
    Assert-True $rejected $Message
}

function Assert-ArgumentValue {
    param([string[]]$Arguments, [string]$Name, [string]$Value)
    $index = [array]::IndexOf($Arguments, $Name)
    Assert-True ($index -ge 0 -and $index + 1 -lt $Arguments.Count) "缺少参数 $Name"
    Assert-Equal $Arguments[$index + 1] $Value "参数 $Name 的值不正确"
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "[PASS] $Name" -ForegroundColor Green
    } catch {
        $script:Failed++
        Write-Host "[FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-TestGguf {
    param([string]$Path, [int]$TensorCount = 0)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    # GGUF v3 空元数据头；不伪装成可用于真实推理的权重。
    $bytes = New-Object byte[] 24
    $bytes[0] = 0x47; $bytes[1] = 0x47; $bytes[2] = 0x55; $bytes[3] = 0x46
    $bytes[4] = 3
    [BitConverter]::GetBytes([uint64]$TensorCount).CopyTo($bytes, 8)
    [IO.File]::WriteAllBytes($Path, $bytes)
    return $Path
}

function New-TestShardSet {
    param([string]$Directory, [int[]]$Parts = @(1, 2, 3, 4))
    foreach ($part in $Parts) {
        $file = 'Qwen3.8-Flash-Next-UD-Q4_K_XL-{0:D5}-of-00004.gguf' -f $part
        New-TestGguf (Join-Path $Directory $file) $(if ($part -eq 1) { 0 } else { 1 }) | Out-Null
    }
}

function Invoke-RealGufoMenuScenario {
    param([string[]]$FunctionTexts, [string]$Scenario, $Model, [hashtable]$Options)
    # 只加载可信本仓源码中的指定函数；独立 runspace 隔离全部 mock 与 $script: 状态。
    $harnessText = @'
        param([string[]]$Definitions, [string]$TestScenario, $TestModel, [hashtable]$TestOptions)
        foreach ($definition in $Definitions) {
            . ([scriptblock]::Create($definition))
        }
        $script:llmHelp = 'Usage: gufo serve llm [OPTIONS]'
        $script:exe = 'test-only-gufo.exe'
        $script:DryRun = $false
        $script:Foreground = $false
        $script:Inputs = New-Object 'Collections.Generic.Queue[string]'
        $script:MenuKeys = New-Object 'Collections.Generic.Queue[string]'
        $script:Prompts = New-Object 'Collections.Generic.List[string]'
        $script:ContextHistory = New-Object 'Collections.Generic.List[uint64]'
        $script:ThinkHistory = New-Object 'Collections.Generic.List[string]'
        $script:MenuKeyReads = 0
        $script:PauseCalls = 0
        $script:DrawCount = 0
        $script:ModelReads = 0
        $script:ArgumentBuilds = 0
        $script:HelpChecks = 0
        $script:PortChecks = 0
        $script:SpawnCalls = 0
        $script:SaveCalls = 0

        function Get-GufoModelRecord {
            param([string]$Path)
            $script:ModelReads = $script:ModelReads + 1
            [pscustomobject]@{ Path = $Path; Complete = $true; Kind = 'target' }
        }
        function New-GufoArguments {
            param($Model, [hashtable]$Options, [string]$ApiKey)
            $script:ArgumentBuilds = $script:ArgumentBuilds + 1
            @('serve', 'llm', '--model', $Model.Path)
        }
        function Assert-GufoArguments {
            param([string[]]$Arguments, [string]$HelpText)
            $script:HelpChecks = $script:HelpChecks + 1
        }
        function Assert-GufoPort {
            param([string]$ListenHost, [int]$Port)
            $script:PortChecks = $script:PortChecks + 1
        }
        function Get-Process {
            [CmdletBinding()]
            param([string]$Name)
            [pscustomobject]@{ Id = 4321; ProcessName = 'gufo' }
        }
        function Read-Host {
            param([string]$Prompt)
            $script:Prompts.Add($Prompt)
            if ($script:Inputs.Count -eq 0) { throw "菜单读取了未预期的输入：$Prompt" }
            $script:Inputs.Dequeue()
        }
        function Read-GufoMenuKey {
            $script:MenuKeyReads++
            if ($script:MenuKeys.Count -eq 0) { throw '菜单读取了未预期的按键。' }
            $script:MenuKeys.Dequeue()
        }
        function Write-Host {
            param([object]$Object, [ConsoleColor]$ForegroundColor, [switch]$NoNewline)
            # 隐藏菜单绘制，只观察控制流结果。
        }
        function Clear-GufoMenu { }
        function Write-GufoMenuLine {
            param([Parameter(ValueFromRemainingArguments = $true)]$Values)
        }
        function Wait-GufoMenu { $script:PauseCalls++ }
        function Format-GufoCommand {
            param([string]$ExePath, [string[]]$Arguments)
            'test-only safe command preview'
        }
        function Show-GufoFeatures {
            param($Model, [hashtable]$Options)
            $script:DrawCount = $script:DrawCount + 1
            $script:ContextHistory.Add([uint64]$Options.Context)
            $script:ThinkHistory.Add([string]$Options.Think)
        }
        function Start-Process {
            $script:SpawnCalls = $script:SpawnCalls + 1
            throw '用户取消后不应创建进程。'
        }
        function Save-GufoSettings {
            $script:SaveCalls = $script:SaveCalls + 1
            throw '用户取消后不应保存启动记录。'
        }
        if ($TestScenario -eq 'Start') {
            $script:Inputs.Enqueue('NO')
            $result = Start-GufoSelection $TestModel $TestOptions
        } elseif ($TestScenario -eq 'Edit') {
            $script:MenuKeys.Enqueue('')
            $script:Inputs.Enqueue('NO')
            $script:MenuKeys.Enqueue('B')
            $result = Edit-GufoFeatures $TestModel $TestOptions $null
        } elseif ($TestScenario -eq 'ContextCycle') {
            foreach ($key in @('7', '7', '7', '7', '7', 'B')) { $script:MenuKeys.Enqueue($key) }
            $result = Edit-GufoFeatures $TestModel $TestOptions $null
        } elseif ($TestScenario -eq 'ContextOnce') {
            foreach ($key in @('7', 'B')) { $script:MenuKeys.Enqueue($key) }
            $result = Edit-GufoFeatures $TestModel $TestOptions $null
        } elseif ($TestScenario -eq 'CustomEntry') {
            foreach ($key in @('X', 'B')) { $script:MenuKeys.Enqueue($key) }
            $script:Inputs.Enqueue('49152')
            $result = Edit-GufoFeatures $TestModel $TestOptions $null
        } elseif ($TestScenario -eq 'Back') {
            $script:MenuKeys.Enqueue('B')
            $result = Edit-GufoFeatures $TestModel $TestOptions $null
        } elseif ($TestScenario -eq 'Progress') {
            foreach ($key in @('9', 'B')) { $script:MenuKeys.Enqueue($key) }
            $result = Edit-GufoFeatures $TestModel $TestOptions $null
        } elseif ($TestScenario -eq 'Think') {
            foreach ($key in @('3', '3', '3', 'B')) { $script:MenuKeys.Enqueue($key) }
            $result = Edit-GufoFeatures $TestModel $TestOptions $null
        } elseif ($TestScenario -eq 'Preview') {
            foreach ($key in @('D', 'B')) { $script:MenuKeys.Enqueue($key) }
            $result = Edit-GufoFeatures $TestModel $TestOptions $null
        } else { throw '未知菜单测试场景。' }
        [pscustomobject]@{
            ReturnValue = $result; RemainingInputs = $script:Inputs.Count
            RemainingKeys = $script:MenuKeys.Count; MenuKeyReads = $script:MenuKeyReads
            PromptCount = $script:Prompts.Count; DrawCount = $script:DrawCount
            ContextHistory = @($script:ContextHistory.ToArray()); ThinkHistory = @($script:ThinkHistory.ToArray())
            Context = $TestOptions.Context; LogProgress = $TestOptions.LogProgress
            ModelReads = $script:ModelReads; ArgumentBuilds = $script:ArgumentBuilds
            HelpChecks = $script:HelpChecks; PortChecks = $script:PortChecks
            SpawnCalls = $script:SpawnCalls; SaveCalls = $script:SaveCalls; PauseCalls = $script:PauseCalls
        }
'@
    $runner = [PowerShell]::Create()
    try {
        [void]$runner.AddScript($harnessText)
        [void]$runner.AddParameter('Definitions', $FunctionTexts)
        [void]$runner.AddParameter('TestScenario', $Scenario)
        [void]$runner.AddParameter('TestModel', $Model)
        [void]$runner.AddParameter('TestOptions', $Options)
        $output = @($runner.Invoke())
        if ($runner.HadErrors) { throw ($runner.Streams.Error | Out-String) }
        if ($output.Count -ne 1) { throw "菜单测试返回数量异常：$($output.Count)" }
        $output[0]
    } finally { $runner.Dispose() }
}

function Invoke-GufoUiProbe {
    param([string[]]$FunctionTexts, [string]$ProbeText, $Model, [hashtable]$Options, [int]$Width = 52)
    # 绘制函数保留真实实现，只截取最终 Write-Host 行；避免改变测试进程的终端。
    $harnessText = @'
        param([string[]]$Definitions, [string]$Probe, $TestModel, [hashtable]$TestOptions, [int]$TestWidth)
        foreach ($definition in $Definitions) { . ([scriptblock]::Create($definition)) }
        $script:TestWidth = $TestWidth
        $script:Rendered = New-Object 'Collections.Generic.List[string]'
        function Get-GufoConsoleWidth { $script:TestWidth }
        function Clear-GufoMenu { }
        function Write-Host {
            param([object]$Object, [ConsoleColor]$ForegroundColor, [switch]$NoNewline)
            $script:Rendered.Add([string]$Object)
        }
        function Read-Host { param([string]$Prompt) '7' }
        $result = @(& ([scriptblock]::Create($Probe)))
        [pscustomobject]@{ Result = $result; Lines = @($script:Rendered.ToArray()) }
'@
    $runner = [PowerShell]::Create()
    try {
        [void]$runner.AddScript($harnessText)
        [void]$runner.AddParameter('Definitions', $FunctionTexts)
        [void]$runner.AddParameter('Probe', $ProbeText)
        [void]$runner.AddParameter('TestModel', $Model)
        [void]$runner.AddParameter('TestOptions', $Options)
        [void]$runner.AddParameter('TestWidth', $Width)
        $output = @($runner.Invoke())
        if ($runner.HadErrors) { throw ($runner.Streams.Error | Out-String) }
        if ($output.Count -ne 1) { throw "绘制测试返回数量异常：$($output.Count)" }
        $output[0]
    } finally { $runner.Dispose() }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('gufo-launcher-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

try {
    $completeDir = Join-Path $testRoot '中文 模型 [v2]'
    New-TestShardSet $completeDir
    $inventory = Get-GufoInventory -Roots @($completeDir)
    $model = @($inventory.Models)[0]

    Test-Case '四个分片只显示一个主模型' {
        Assert-Equal @($inventory.Models).Count 1
        Assert-Equal $model.Shards 4
    }
    Test-Case '四个分片全部齐全' {
        Assert-True ([bool]$model.Complete)
        Assert-Equal @($model.MissingShards).Count 0
    }
    Test-Case '模型总大小包含全部分片' {
        Assert-Equal ([int64]$model.Bytes) ([int64]96)
    }
    Test-Case '首分片没有张量仍是合法加载入口' {
        Assert-True ([bool]$model.Complete)
        Assert-True ($model.Path.EndsWith('-00001-of-00004.gguf'))
    }
    Test-Case '中文、空格和方括号路径按字面处理' {
        Assert-Equal ([IO.Path]::GetDirectoryName($model.Path)) $completeDir
    }

    $mtp = New-TestGguf (Join-Path (Join-Path $completeDir 'MTP') 'mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf')
    $dflash = New-TestGguf (Join-Path $completeDir 'Qwen3.8-27B-DFlash2-Q4_K_M.gguf')
    $dspark = New-TestGguf (Join-Path $completeDir 'DeepSeek-V4-Flash-DSpark.gguf')
    $vision = New-TestGguf (Join-Path $completeDir 'mmproj-BF16.gguf')
    New-TestGguf (Join-Path $completeDir 'imatrix_micro3.gguf') | Out-Null
    [IO.File]::WriteAllText((Join-Path $completeDir 'calibration3.txt'), 'calibration fixture')
    $withSidecars = Get-GufoInventory -Roots @($completeDir)

    Test-Case '草稿、视觉文件和 imatrix 不混入主模型' {
        Assert-Equal @($withSidecars.Models).Count 1
    }
    Test-Case '发现 MTP 子目录中的独立草稿' {
        Assert-Equal @($withSidecars.Mtp).Count 1
        Assert-Equal @($withSidecars.Mtp)[0].Path $mtp
    }
    Test-Case 'DFlash2 草稿单独归类' {
        Assert-Equal @($withSidecars.DFlash).Count 1
        Assert-Equal @($withSidecars.DFlash)[0].Path $dflash
    }
    Test-Case 'DSpark 草稿单独归类' {
        Assert-Equal @($withSidecars.DSpark).Count 1
        Assert-Equal @($withSidecars.DSpark)[0].Path $dspark
    }
    Test-Case '视觉 sidecar 单独归类' {
        Assert-Equal @($withSidecars.Vision).Count 1
        Assert-Equal @($withSidecars.Vision)[0].Path $vision
    }
    Test-Case '重叠的扫描根不产生重复模型' {
        $overlap = Get-GufoInventory -Roots @($completeDir, $completeDir, $testRoot)
        $matches = @($overlap.Models | Where-Object { $_.Path -eq $model.Path })
        Assert-Equal $matches.Count 1
    }

    $missingDir = Join-Path $testRoot '缺第三片'
    New-TestShardSet $missingDir @(1, 2, 4)
    Test-Case '缺失第三片时标为不可启动' {
        $broken = @((Get-GufoInventory -Roots @($missingDir)).Models)[0]
        Assert-True (-not [bool]$broken.Complete)
        Assert-True (@($broken.MissingShards) -contains 3)
    }
    $missingFirstDir = Join-Path $testRoot '缺第一片'
    New-TestShardSet $missingFirstDir @(2, 3, 4)
    Test-Case '缺首片仍报告分片组和缺失序号' {
        $brokenInventory = Get-GufoInventory -Roots @($missingFirstDir)
        Assert-Equal @($brokenInventory.Models).Count 1
        $broken = @($brokenInventory.Models)[0]
        Assert-True (-not [bool]$broken.Complete)
        Assert-True (@($broken.MissingShards) -contains 1)
    }
    $emptyDir = Join-Path $testRoot '零字节分片'
    New-TestShardSet $emptyDir
    [IO.File]::WriteAllBytes((Join-Path $emptyDir 'Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf'), [byte[]]@())
    Test-Case '存在但为空的分片不能通过完整性检查' {
        $broken = @((Get-GufoInventory -Roots @($emptyDir)).Models)[0]
        Assert-True (-not [bool]$broken.Complete)
    }
    Test-Case '不存在的目录返回空清单而不误报模型' {
        $absent = Get-GufoInventory -Roots @((Join-Path $testRoot '不存在'))
        Assert-Equal @($absent.Models).Count 0
    }

    $options = New-GufoOptions
    Test-Case '默认草稿上限是 help 中的 7' {
        Assert-Equal $options.DraftTokens 7
        Assert-Equal $options.MinDraftTokens 1
    }
    Test-Case '默认只监听本机且单会话' {
        Assert-Equal $options.Host '127.0.0.1'
        Assert-Equal $options.Port 8080
        Assert-Equal $options.Sessions 1
    }
    Test-Case '每次新建的选项相互独立' {
        $second = New-GufoOptions
        $second.Port = 18080
        Assert-Equal $options.Port 8080
    }

    $arguments = @(New-GufoArguments -Model $model -Options $options)
    Test-Case '启动参数只传一个主分片入口' {
        Assert-Equal @($arguments | Where-Object { $_ -eq '--model' }).Count 1
        Assert-ArgumentValue $arguments '--model' $model.Path
        Assert-True (-not ($arguments -contains (Join-Path $completeDir 'Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf')))
    }
    Test-Case '基础启动使用 serve llm' {
        Assert-Equal $arguments[0] 'serve'
        Assert-Equal $arguments[1] 'llm'
    }
    Test-Case '默认关闭投机时不携带草稿路径' {
        Assert-True (-not ($arguments -contains '--mtp-model'))
        Assert-True (-not ($arguments -contains '--dflash-model'))
        Assert-True (-not ($arguments -contains '--dspark-model'))
    }

    $mtpOptions = New-GufoOptions
    $mtpOptions.Speculative = 'mtp'; $mtpOptions.DraftPath = $mtp
    $mtpArguments = @(New-GufoArguments -Model $model -Options $mtpOptions)
    Test-Case 'MTP 模式传独立文件及对应后端' {
        Assert-ArgumentValue $mtpArguments '--speculative' 'mtp'
        Assert-ArgumentValue $mtpArguments '--mtp-model' $mtp
        Assert-True (-not ($mtpArguments -contains '--dflash-model'))
    }
    Test-Case '关闭投机不会继承上次 MTP 路径' {
        $disabled = New-GufoOptions
        $disabled.DraftPath = $mtp
        $offArguments = @(New-GufoArguments -Model $model -Options $disabled)
        Assert-True (-not ($offArguments -contains $mtp))
    }
    Test-Case 'MTP 缺草稿文件时拒绝启动' {
        $invalid = New-GufoOptions
        $invalid.Speculative = 'mtp'
        Assert-Throws { New-GufoArguments -Model $model -Options $invalid }
    }
    Test-Case '草稿上限 0 不能作为默认值透传' {
        $invalid = New-GufoOptions
        $invalid.Speculative = 'mtp'; $invalid.DraftPath = $mtp; $invalid.DraftTokens = 0
        Assert-Throws { New-GufoArguments -Model $model -Options $invalid }
    }
    Test-Case '草稿下限不能超过上限' {
        $invalid = New-GufoOptions
        $invalid.Speculative = 'mtp'; $invalid.DraftPath = $mtp
        $invalid.DraftTokens = 3; $invalid.MinDraftTokens = 4
        Assert-Throws { New-GufoArguments -Model $model -Options $invalid }
    }
    Test-Case '原生 context=0 与自动 RAM 预算=0 保留真实语义' {
        $zeroOptions = New-GufoOptions
        $zeroOptions.Context = 0; $zeroOptions.CacheRamBytes = '0'
        $zeroArguments = @(New-GufoArguments -Model $model -Options $zeroOptions)
        Assert-ArgumentValue $zeroArguments '--context' '0'
        Assert-ArgumentValue $zeroArguments '--cache-ram-bytes' '0'
    }
    Test-Case '服务 -1 生成上限原样保留' {
        Assert-ArgumentValue $arguments '--max-tokens' '-1'
    }
    Test-Case '无效端口被拒绝' {
        $invalid = New-GufoOptions; $invalid.Port = 65536
        Assert-Throws { New-GufoArguments -Model $model -Options $invalid }
    }
    Test-Case '零会话被拒绝' {
        $invalid = New-GufoOptions; $invalid.Sessions = 0
        Assert-Throws { New-GufoArguments -Model $model -Options $invalid }
    }

    # 只包含官方实际 help 中确认的参数，用于测试白名单是否精确匹配。
    $helpText = @'
Usage: gufo serve llm [OPTIONS]
  --model <PATH>
  --mmproj <PATH>
  --served-model-name <ID>
  --context <N>
  --enable-yarn
  --max-tokens <N>
  --temperature <T>
  --top-k <K>
  --top-p <P>
  --min-p <P>
  --min-keep <N>
  --seed <N>
  --repeat-penalty <N>
  --repeat-last-n <N>
  --frequency-penalty <N>
  --presence-penalty <N>
  --think <MODE>
  --reasoning-effort <LEVEL>
  --preserve-thinking <MODE>
  --reasoning-budget <N>
  --speculative <MODE>
  --mtp-model <PATH>
  --dflash-model <PATH>
  --dspark-model <PATH>
  --draft-tokens <N>
  --min-draft-tokens <N>
  --draft-policy <POLICY>
  --prefill-chunk <N>
  --max-pending <N>
  --max-pending-per-client <N>
  --request-timeout-ms <MS>
  --stall-timeout-ms <MS>
  --max-output-bytes <N>
  --max-buffered-output-bytes <N>
  --max-buffered-output-total <N>
  --cache-ram-bytes <N>
  --cache-disk <DIR>
  --cache-disk-bytes <N>
  --cache-disk-staging-bytes <N>
  --log-progress
  --log-level <LEVEL>
  --trace <PATH>
  --host <IP>
  --port <N>
  --sessions <N>
  --max-connections <N>
  --max-request-bytes <N>
  --api-key <KEY>
'@
    Test-Case '基础参数全部在实际 help 白名单中' {
        Assert-GufoArguments -Arguments $arguments -HelpText $helpText
    }
    Test-Case 'MTP 参数全部在实际 help 白名单中' {
        Assert-GufoArguments -Arguments $mtpArguments -HelpText $helpText
    }
    Test-Case '拒绝旧分支 mtp-policy 参数' {
        Assert-Throws { Assert-GufoArguments -Arguments @('serve', 'llm', '--mtp-policy', 'survival') -HelpText $helpText }
    }
    Test-Case '拒绝旧分支 prompt-lookup 参数' {
        Assert-Throws { Assert-GufoArguments -Arguments @('serve', 'llm', '--prompt-lookup') -HelpText $helpText }
    }
    Test-Case '参数名不能通过子串误匹配' {
        Assert-Throws { Assert-GufoArguments -Arguments @('serve', 'llm', '--model-other', 'x') -HelpText $helpText }
    }

    Test-Case 'Windows 引用保留带空格的路径' {
        Assert-Equal (ConvertTo-GufoArgumentString -Arguments @('E:\中文 模型\a.gguf')) '"E:\中文 模型\a.gguf"'
    }
    Test-Case 'Windows 引用保留空参数' {
        Assert-Equal (ConvertTo-GufoArgumentString -Arguments @('')) '""'
    }
    Test-Case 'Windows 引用保留内嵌双引号' {
        Assert-Equal (ConvertTo-GufoArgumentString -Arguments @('say "hi"')) '"say \"hi\""'
    }
    Test-Case 'Windows 引用正确处理引号前的路径尾反斜杠' {
        Assert-Equal (ConvertTo-GufoArgumentString -Arguments @('E:\a b\')) '"E:\a b\\"'
    }

    $secret = 'test-only-secret-9f37'
    $lanOptions = New-GufoOptions
    $lanOptions.Host = '0.0.0.0'
    Test-Case '局域网显式空 Key 可启动且不发送 api-key 参数' {
        $lanArguments = @(New-GufoArguments -Model $model -Options $lanOptions -ApiKey '')
        Assert-ArgumentValue $lanArguments '--host' '0.0.0.0'
        Assert-True ($lanArguments -notcontains '--api-key')
    }
    Test-Case '局域网不提供 Key 时默认保持空值而不伪造凭据' {
        $lanArguments = @(New-GufoArguments -Model $model -Options $lanOptions)
        Assert-True ($lanArguments -notcontains '--api-key')
        $shown = Format-GufoCommand -ExePath 'E:\gufo\gufo.exe' -Arguments $lanArguments
        Assert-True (-not $shown.Contains('--api-key'))
    }
    Test-Case '局域网填写 Key 时继续传递真实值并脱敏预览' {
        $lanArguments = @(New-GufoArguments -Model $model -Options $lanOptions -ApiKey $secret)
        Assert-ArgumentValue $lanArguments '--api-key' $secret
        Assert-True (-not (Format-GufoCommand -ExePath 'E:\gufo\gufo.exe' -Arguments $lanArguments).Contains($secret))
    }
    $keyArguments = @(New-GufoArguments -Model $model -Options $options -ApiKey $secret)
    Test-Case '鉴权参数传给引擎时保持原值' {
        Assert-ArgumentValue $keyArguments '--api-key' $secret
    }
    Test-Case '命令预览隐藏 API Key' {
        $shown = Format-GufoCommand -ExePath 'E:\Gufo tools\gufo.exe' -Arguments $keyArguments
        Assert-True (-not $shown.Contains($secret))
        Assert-True ($shown.Contains('--api-key'))
        Assert-True ($shown.Contains('gufo.exe'))
    }
    Test-Case '命令预览不修改实际参数数组' {
        $null = Format-GufoCommand -ExePath 'E:\Gufo tools\gufo.exe' -Arguments $keyArguments
        Assert-ArgumentValue $keyArguments '--api-key' $secret
    }

    $settingsPath = Join-Path $testRoot 'settings.json'
    $saveOptions = New-GufoOptions
    $saveOptions['ApiKey'] = $secret
    $saveOptions['ExtraArgs'] = @('--api-key', $secret)
    $saveOptions['UnknownSetting'] = 'should-not-survive'
    Save-GufoSettings -Path $settingsPath -Model $model -Options $saveOptions -Roots @($completeDir)
    Test-Case '设置文件不保存 API Key 或额外原始命令' {
        $savedText = [IO.File]::ReadAllText($settingsPath)
        Assert-True (-not $savedText.Contains($secret))
        Assert-True (-not $savedText.Contains('ExtraArgs'))
        Assert-True (-not $savedText.Contains('UnknownSetting'))
    }
    Test-Case '结构化设置可回读模型目录和非敏感参数' {
        $saved = Read-GufoSettings -Path $settingsPath
        Assert-Equal $saved.SchemaVersion 1
        Assert-Equal $saved.ModelPath $model.Path
        Assert-Equal $saved.Options.Port 8080
        Assert-True (@($saved.Roots) -contains $completeDir)
    }
    Test-Case '不存在的设置文件返回默认结构' {
        $fresh = Read-GufoSettings -Path (Join-Path $testRoot 'not-created.json')
        Assert-Equal $fresh.SchemaVersion 1
        Assert-Equal $fresh.Options.Port 8080
    }

    $launcherPath = Join-Path (Split-Path $CorePath -Parent) 'launcher.ps1'
    $parseTokens = $null; $parseErrors = $null
    $launcherAst = [Management.Automation.Language.Parser]::ParseFile(
        $launcherPath, [ref]$parseTokens, [ref]$parseErrors)
    Test-Case 'API Key 提示直接回车得到空值且安全释放 SecureString' {
        $definition = @($launcherAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-GufoSecret'
        }, $true))[0].Extent.Text
        $runner = [PowerShell]::Create()
        try {
            [void]$runner.AddScript($definition + @'

function Read-Host { param([string]$Prompt, [switch]$AsSecureString) New-Object Security.SecureString }
$value = Read-GufoSecret
([string]$value).Length
'@)
            $result = @($runner.Invoke())
            Assert-True (-not $runner.HadErrors)
            Assert-Equal $result.Count 1
            Assert-Equal $result[0] 0
        } finally { $runner.Dispose() }
    }
    $menuFunctions = @('Start-GufoSelection', 'Edit-GufoFeatures', 'Get-GufoNextContext')
    $functionDefinitions = @($launcherAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $menuFunctions -contains $node.Name
    }, $true))
    $functionTexts = @($functionDefinitions | ForEach-Object { $_.Extent.Text })
    $coreTokens = $null; $coreErrors = $null
    $coreAst = [Management.Automation.Language.Parser]::ParseFile($CorePath, [ref]$coreTokens, [ref]$coreErrors)
    $unsignedFunction = @($coreAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-GufoUnsigned'
    }, $true))
    $functionTexts += @($unsignedFunction | ForEach-Object { $_.Extent.Text })
    Test-Case '菜单源码可解析并找到真实控制流与上下文切换函数' {
        Assert-Equal @($parseErrors).Count 0
        Assert-Equal $functionDefinitions.Count 3
    }
    Test-Case '已有 Gufo 时取消并行启动返回 false 且不产生副作用' {
        $cancelled = Invoke-RealGufoMenuScenario -FunctionTexts $functionTexts -Scenario 'Start' -Model $model -Options (New-GufoOptions)
        Assert-Equal $cancelled.ReturnValue $false
        Assert-Equal $cancelled.RemainingInputs 0
        Assert-Equal $cancelled.ModelReads 1
        Assert-Equal $cancelled.ArgumentBuilds 1
        Assert-Equal $cancelled.HelpChecks 1
        Assert-Equal $cancelled.PortChecks 1
        Assert-Equal $cancelled.PromptCount 1
        Assert-Equal $cancelled.SpawnCalls 0
        Assert-Equal $cancelled.SaveCalls 0
    }
    Test-Case '配置菜单 Enter 启动取消后继续显示菜单并由 B 返回' {
        $back = Invoke-RealGufoMenuScenario -FunctionTexts $functionTexts -Scenario 'Edit' -Model $model -Options (New-GufoOptions)
        Assert-Equal $back.ReturnValue $false
        Assert-Equal $back.DrawCount 2
        Assert-Equal $back.PromptCount 1
        Assert-Equal $back.MenuKeyReads 2
        Assert-Equal $back.RemainingInputs 0
        Assert-Equal $back.RemainingKeys 0
        Assert-Equal $back.ModelReads 1
        Assert-Equal $back.ArgumentBuilds 1
        Assert-Equal $back.SpawnCalls 0
        Assert-Equal $back.SaveCalls 0
    }
    Test-Case '按 7 连续循环预设上下文且不要求输入长度或回车' {
        $cycleOptions = New-GufoOptions
        $cycleOptions.Context = 0
        $cycle = Invoke-RealGufoMenuScenario -FunctionTexts $functionTexts -Scenario 'ContextCycle' -Model $model -Options $cycleOptions
        Assert-Equal ($cycle.ContextHistory -join ',') '0,32768,65536,131072,262144,0'
        Assert-Equal $cycle.MenuKeyReads 6
        Assert-Equal $cycle.PromptCount 0
        Assert-Equal $cycle.RemainingKeys 0
        Assert-Equal $cycle.SpawnCalls 0
        Assert-Equal $cycle.SaveCalls 0
    }
    Test-Case '原生上下文按一次 7 切回 32K' {
        $nativeOptions = New-GufoOptions
        $nativeOptions.Context = 0
        $native = Invoke-RealGufoMenuScenario -FunctionTexts $functionTexts -Scenario 'ContextOnce' -Model $model -Options $nativeOptions
        Assert-Equal ([uint64]$native.Context) 32768
        Assert-Equal $native.PromptCount 0
    }
    Test-Case '打开菜单后返回不改变已有自定义上下文' {
        $customOptions = New-GufoOptions
        $customOptions.Context = 49152
        $custom = Invoke-RealGufoMenuScenario -FunctionTexts $functionTexts -Scenario 'Back' -Model $model -Options $customOptions
        Assert-Equal ([uint64]$custom.Context) 49152
        Assert-Equal $custom.PromptCount 0
    }
    Test-Case '自定义上下文按 7 前进到下一个更大的预设' {
        $customOptions = New-GufoOptions
        $customOptions.Context = 49152
        $next = Invoke-RealGufoMenuScenario -FunctionTexts $functionTexts -Scenario 'ContextOnce' -Model $model -Options $customOptions
        Assert-Equal ([uint64]$next.Context) 65536
        $customOptions.Context = 300000
        $native = Invoke-RealGufoMenuScenario -FunctionTexts $functionTexts -Scenario 'ContextOnce' -Model $model -Options $customOptions
        Assert-Equal ([uint64]$native.Context) 0
    }
    Test-Case 'X 入口保留自定义上下文的真实数值输入' {
        $custom = Invoke-RealGufoMenuScenario -FunctionTexts $functionTexts -Scenario 'CustomEntry' -Model $model -Options (New-GufoOptions)
        Assert-Equal ([uint64]$custom.Context) 49152
        Assert-Equal $custom.PromptCount 1
        Assert-Equal $custom.RemainingInputs 0
        Assert-Equal $custom.RemainingKeys 0
    }
    Test-Case '实时进度移到 9 且不会误改上下文' {
        $progressOptions = New-GufoOptions
        $progressOptions.Context = 65536
        $progress = Invoke-RealGufoMenuScenario -FunctionTexts $functionTexts -Scenario 'Progress' -Model $model -Options $progressOptions
        Assert-Equal $progress.LogProgress $false
        Assert-Equal ([uint64]$progress.Context) 65536
        Assert-Equal $progress.PromptCount 0
    }
    Test-Case '思考模式按 3 循环切换且不进入额外输入提示' {
        $thinking = Invoke-RealGufoMenuScenario -FunctionTexts $functionTexts -Scenario 'Think' -Model $model -Options (New-GufoOptions)
        Assert-Equal ($thinking.ThinkHistory -join ',') 'auto,on,off,auto'
        Assert-Equal $thinking.PromptCount 0
    }
    Test-Case '预览命令后等待确认再重绘菜单' {
        $preview = Invoke-RealGufoMenuScenario -FunctionTexts $functionTexts -Scenario 'Preview' -Model $model -Options (New-GufoOptions)
        Assert-Equal $preview.PauseCalls 1
        Assert-Equal $preview.DrawCount 2
        Assert-Equal $preview.SpawnCalls 0
        Assert-Equal $preview.SaveCalls 0
    }

    $uiFunctions = @('Get-GufoConsoleWidth', 'Get-GufoCellWidth', 'Split-GufoConsoleLine',
        'Write-GufoMenuLine', 'Clear-GufoMenu', 'Read-GufoMenuKey', 'Get-GufoNextContext',
        'Get-GufoContextLabel', 'Show-GufoFeatures')
    $uiDefinitions = @($launcherAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $uiFunctions -contains $node.Name
    }, $true))
    $uiTexts = @($uiDefinitions | ForEach-Object { $_.Extent.Text })
    Test-Case '菜单绘制和宽度函数均可单独解析' {
        Assert-Equal $uiDefinitions.Count $uiFunctions.Count
    }
    Test-Case '中文按双列宽计算且上下文标签可读' {
        $probe = Invoke-GufoUiProbe -FunctionTexts $uiTexts -ProbeText "Get-GufoCellWidth '中文 A'; Get-GufoContextLabel 0; Get-GufoContextLabel 65536" -Model $model -Options (New-GufoOptions)
        Assert-Equal $probe.Result[0] 6
        Assert-True ($probe.Result[1] -match '原生')
        Assert-True ($probe.Result[2] -match '64K')
    }
    Test-Case '长中文路径按列宽续行且空格方括号反斜杠不丢失' {
        $probeText = @'
            $path = 'E:\新建文件夹\模型 [V2]\unsloth-UD-Q4_K_XL-V2\Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf'
            $lines = @(Split-GufoConsoleLine -Text $path -Width 32 -Prefix '  ')
            [pscustomobject]@{
                Count = $lines.Count
                Widths = @($lines | ForEach-Object { Get-GufoCellWidth $_ })
                Recovered = ($lines | ForEach-Object { $_.Substring(2) }) -join ''
                Original = $path
            }
'@
        $probe = Invoke-GufoUiProbe -FunctionTexts $uiTexts -ProbeText $probeText -Model $model -Options (New-GufoOptions)
        $wrapped = $probe.Result[0]
        Assert-True ($wrapped.Count -gt 1)
        foreach ($width in $wrapped.Widths) { Assert-True ($width -le 32) "续行超过 32 列：$width" }
        Assert-Equal $wrapped.Recovered $wrapped.Original
    }
    Test-Case '等宽边界不产生多余空行且原始换行保留' {
        $probe = Invoke-GufoUiProbe -FunctionTexts $uiTexts -ProbeText @'
            $exact = @(Split-GufoConsoleLine -Text '123456789' -Width 9 -ContinuationPrefix '')
            $paragraphs = @(Split-GufoConsoleLine -Text "a`r`nb`nc`rd" -Width 20)
            [pscustomobject]@{ ExactCount = $exact.Count; Exact = $exact[0]; Paragraphs = ($paragraphs -join '|') }
'@ -Model $model -Options (New-GufoOptions)
        Assert-Equal $probe.Result[0].ExactCount 1
        Assert-Equal $probe.Result[0].Exact '123456789'
        Assert-Equal $probe.Result[0].Paragraphs 'a|b|c|d'
    }
    Test-Case '组合字符和 emoji 换行不截断文本元素' {
        $probe = Invoke-GufoUiProbe -FunctionTexts $uiTexts -ProbeText @'
            $text = '模型 e' + [char]0x0301 + ' 👮 [v2] path\test.gguf'
            $lines = @(Split-GufoConsoleLine -Text $text -Width 12 -ContinuationPrefix '')
            [pscustomobject]@{ Original = $text; Recovered = ($lines -join ''); Lines = $lines }
'@ -Model $model -Options (New-GufoOptions)
        Assert-Equal $probe.Result[0].Recovered $probe.Result[0].Original
        foreach ($line in $probe.Result[0].Lines) {
            Assert-True (-not $line.StartsWith([string][char]0x0301)) '组合附加符不能成为续行首字符。'
        }
    }

    $displayModel = [pscustomobject]@{
        Name = 'Qwen3.8-Flash-Next-UD-Q4_K_XL'; Shards = 4
        Path = 'E:\新建文件夹\gufo-v0.25.0-windows-x86_64\models\unsloth-UD-Q4_K_XL-V2\Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf'
    }
    $displayOptions = New-GufoOptions
    $displayOptions.Context = 0
    $displayOptions.Speculative = 'mtp'
    $displayOptions.DraftPath = 'E:\新建文件夹\gufo-v0.25.0-windows-x86_64\models\MTP\mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf'
    $rendered = Invoke-GufoUiProbe -FunctionTexts $uiTexts -ProbeText 'Show-GufoFeatures $TestModel $TestOptions' -Model $displayModel -Options $displayOptions -Width 52
    Test-Case '每个配置快捷键独占一行且没有并排选项' {
        $rows = @($rendered.Lines | Where-Object { $_ -match '^[1-9FCTVYPX] {2}' })
        Assert-Equal $rows.Count 15
        $keys = @($rows | ForEach-Object { $_.Substring(0, 1) })
        Assert-Equal ($keys -join ',') '1,2,3,4,5,6,7,8,9,F,C,V,T,Y,X'
        foreach ($line in $rows) {
            Assert-Equal ([regex]::Matches($line, '(?:^| {2,})([1-9FCTVYPX]) {2}').Count) 1
        }
    }
    Test-Case '布尔和空目录使用中文状态而非 True False 或空白' {
        $text = $rendered.Lines -join "`n"
        Assert-True ($text -notmatch '\b(?:True|False)\b')
        Assert-True ($text -match '9  实时进度：开启')
        Assert-True ($text -match 'Y  YaRN：关闭')
        Assert-True ($text -match 'C  磁盘缓存：未启用')
        Assert-True ($text -match 'V  视觉 sidecar：引擎自动发现')
    }
    Test-Case '模型和分片独立成行且两条长路径均完整保留' {
        Assert-Equal @($rendered.Lines | Where-Object { $_ -match '^模型：' }).Count 1
        Assert-Equal @($rendered.Lines | Where-Object { $_ -match '^分片：4/4$' }).Count 1
        $paths = @{}
        foreach ($label in @('模型文件：', '草稿文件：')) {
            $index = [array]::IndexOf($rendered.Lines, $label)
            Assert-True ($index -ge 0) "缺少独立路径标题：$label"
            $segments = New-Object 'Collections.Generic.List[string]'
            for ($i = $index + 1; $i -lt $rendered.Lines.Count -and $rendered.Lines[$i].StartsWith('  '); $i++) {
                $segments.Add($rendered.Lines[$i].Substring(2))
            }
            $paths[$label] = $segments.ToArray() -join ''
        }
        Assert-Equal $paths['模型文件：'] $displayModel.Path
        Assert-Equal $paths['草稿文件：'] $displayOptions.DraftPath
    }
    Test-Case '设置菜单所有行均符合指定的窄终端列宽' {
        $probe = Invoke-GufoUiProbe -FunctionTexts $uiTexts -ProbeText @'
            Show-GufoFeatures $TestModel $TestOptions
            @($script:Rendered | ForEach-Object { Get-GufoCellWidth $_ })
'@ -Model $displayModel -Options $displayOptions -Width 52
        foreach ($width in $probe.Result) { Assert-True ($width -le 52) "菜单行超过 52 列：$width" }
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host ""
Write-Host ("测试结果：{0} 通过，{1} 失败。" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
