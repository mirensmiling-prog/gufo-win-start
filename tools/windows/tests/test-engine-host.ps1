# 独立宿主定向回归：仅读取源码；临时编译不加载模型，不执行真实推理。
param([string]$WindowsTools = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$script:Passed = 0; $script:Failed = 0; $script:Skipped = 0
function Assert-True([bool]$Value, [string]$Message = '断言失败') { if (-not $Value) { throw $Message } }
function Assert-Equal($Actual, $Expected) { if ($Actual -cne $Expected) { throw "实际=[$Actual] 预期=[$Expected]" } }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host "[PASS] $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "[FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Skip-Case([string]$Name, [string]$Reason) { $script:Skipped++; Write-Host "[SKIP] $Name : $Reason" -ForegroundColor Yellow }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('gufo-host-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try {
    Test-Case '独立宿主C#可编译且无需额外包' {
        if (-not ('GufoEngineHost.Protocol' -as [type])) { Add-Type -Path (Join-Path $WindowsTools 'engine-host.cs') }
        Assert-True ($null -ne ('GufoEngineHost.Program' -as [type]))
    }
    . (Join-Path $WindowsTools 'launcher-core.ps1')
    Test-Case 'CRT引用与现有启动器一致，空格中文引号反斜杠按字面传递' {
        $values = @('', 'serve', '中文 模型 [v2]', 'E:\路径 with space\', 'foo"bar', '\\host\share\', 'abc\"def', '--api-key', 'test-only; $() & < > ! %PATH%')
        Assert-Equal ([GufoEngineHost.Protocol]::BuildArguments($values, 0)) (ConvertTo-GufoArgumentString $values)
    }
    Test-Case '管道名只允许启动器生成的随机命名，拒绝路径和外部命名' {
        Assert-True ([GufoEngineHost.Protocol]::ValidPipeName('gufo-stats-' + ('a' * 32)))
        foreach ($name in @('', 'gufo-stats-', 'other-' + ('a' * 32), '\\.\pipe\test', 'gufo-stats-' + ('A' * 32), 'gufo-stats-' + ('a' * 31) + '/')) {
            Assert-True (-not [GufoEngineHost.Protocol]::ValidPipeName($name)) $name
        }
    }
    $line = '2026-10-27 12:00:00 [INFO] [http] request=r7 event=completed method=POST path=/v1/chat/completions status=200 duration_ms=500.0 outcome=completed prompt_tokens=100 prefill_tokens=80 generated_tokens=20 finish=stop cache=memory cached_tokens=20 cache_restore_ms=0.1 queue_ms=2.3 ttft_ms=40.5 prefill_tps=2000.0 decode_tps=43.5'
    Test-Case '官方请求完成行解析TTFT预填充decode和数量，不保留原始日志' {
        $record = [GufoEngineHost.Protocol]::ParseRequestLine($line)
        Assert-True ($null -ne $record)
        $json = $record.ToJson() | ConvertFrom-Json
        Assert-Equal $json.request_id 'r7'
        Assert-Equal $json.ttft_ms 40.5
        Assert-Equal $json.prefill_tps 2000.0
        Assert-Equal $json.decode_tps 43.5
        Assert-Equal $json.prompt_tokens 100
        Assert-Equal $json.generated_tokens 20
        Assert-True (-not $record.ToJson().Contains('path='))
        Assert-Equal @($json.PSObject.Properties).Count 10
    }
    Test-Case '官方文本路由均可解析且无请求内容缓存' {
        foreach ($path in @('/completion', '/v1/completions', '/v1/chat/completions', '/v1/messages', '/v1/responses')) {
            Assert-True ($null -ne [GufoEngineHost.Protocol]::ParseRequestLine($line.Replace('/v1/chat/completions', $path))) $path
        }
        $record = [GufoEngineHost.Protocol]::ParseRequestLine($line + ' private_extra=test-only-secret')
        Assert-True (-not $record.ToJson().Contains('test-only-secret'))
        $record = [GufoEngineHost.Protocol]::ParseRequestLine($line.Replace('request=r7', 'request=private-client-id'))
        Assert-True ($null -eq ($record.ToJson() | ConvertFrom-Json).request_id)
    }
    Test-Case '非完成非http非info或非成功POST均不得伪造最近请求' {
        $invalid = @(
            $line.Replace('event=completed', 'event=started'),
            $line.Replace('outcome=completed', 'outcome=disconnected'),
            $line.Replace('[http]', '[model]'), $line.Replace('[INFO]', '[DEBUG]'),
            $line.Replace('method=POST', 'method=GET'), $line.Replace('status=200', 'status=404'),
            $line.Replace('/v1/chat/completions', '/metrics'), $line.Substring(20)
        )
        foreach ($value in $invalid) { Assert-True ($null -eq [GufoEngineHost.Protocol]::ParseRequestLine($value)) }
    }
    Test-Case '缺失重复负数非有限或分数token字段不得当作有效统计' {
        foreach ($value in @(
            $line.Replace('ttft_ms=40.5 ', ''), ($line + ' ttft_ms=1.0'),
            $line.Replace('ttft_ms=40.5', 'ttft_ms=-1.0'),
            $line.Replace('ttft_ms=40.5', 'ttft_ms=NaN'),
            $line.Replace('ttft_ms=40.5', 'ttft_ms=Infinity'),
            $line.Replace('prompt_tokens=100', 'prompt_tokens=1.5'),
            ($line + ('x' * 16384))
        )) { Assert-True ($null -eq [GufoEngineHost.Protocol]::ParseRequestLine($value)) }
    }
    Test-Case '零token零速率可以是真实有效值' {
        $zero = $line.Replace('40.5', '0.0').Replace('2000.0', '0.0').Replace('43.5', '0.0').Replace('generated_tokens=20', 'generated_tokens=0')
        $record = [GufoEngineHost.Protocol]::ParseRequestLine($zero)
        Assert-True ($null -ne $record)
        Assert-Equal ($record.ToJson() | ConvertFrom-Json).decode_tps 0
    }
    Test-Case '小数解析与JSON输出不受系统区域小数分隔符影响' {
        $prior = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
            $record = [GufoEngineHost.Protocol]::ParseRequestLine($line)
            Assert-True ($record.ToJson().Contains('"ttft_ms":40.5'))
            Assert-Equal ($record.ToJson() | ConvertFrom-Json).prefill_tps 2000
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $prior }
    }
    Test-Case '内存状态仅保留最近一条数字记录，序号只随真完成请求增长' {
        $stateType = ('GufoEngineHost.Protocol' -as [type]).Assembly.GetType('GufoEngineHost.HostState')
        $state = [Activator]::CreateInstance($stateType, $true)
        $empty = $stateType.GetMethod('Snapshot').Invoke($state, @()) | ConvertFrom-Json
        Assert-True ($null -eq $empty.last)
        Assert-Equal $empty.sequence 0
        for ($i = 0; $i -lt 1000; $i++) {
            [void]$stateType.GetMethod('Observe').Invoke($state, @($line.Replace('request=r7', ('request=r' + $i))))
        }
        [void]$stateType.GetMethod('Observe').Invoke($state, @('not a request ttft_ms=1'))
        $payload = $stateType.GetMethod('Snapshot').Invoke($state, @())
        $snapshot = $payload | ConvertFrom-Json
        Assert-Equal $snapshot.sequence 1000
        Assert-Equal $snapshot.last.request_id 'r999'
        Assert-True ($payload.Length -lt 8192)
        Assert-True (-not $payload.Contains('r998'))
        Assert-Equal $snapshot.schema 1
    }
    Test-Case 'UTF8跨缓冲边界及短日志行立即排空且输出不改写' {
        # 通过真实Pump读取内存流；4096字节边界落在中文UTF8中间。
        $text = ('a' * 4095) + '中文' + "`n" + $line + "`n"
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        $stream = New-Object IO.MemoryStream(,$bytes)
        $reader = New-Object IO.StreamReader($stream)
        $output = New-Object IO.StringWriter
        try {
            $pump = [GufoEngineHost.Program].GetMethod('Pump', [Reflection.BindingFlags]'NonPublic,Static')
            [void]$pump.Invoke($null, [object[]]@($reader.PSObject.BaseObject, $output.PSObject.BaseObject))
            Assert-Equal $output.ToString() $text
        } finally { $output.Dispose(); $reader.Dispose(); $stream.Dispose() }
    }
    Test-Case '超长单行只转发不解析且后续完整统计仍可恢复' {
        $programType = 'GufoEngineHost.Program' -as [type]
        $state = $programType.GetField('state', [Reflection.BindingFlags]'NonPublic,Static').GetValue($null)
        $stateType = $state.GetType()
        $before = ($stateType.GetMethod('Snapshot').Invoke($state, @()) | ConvertFrom-Json).sequence
        $text = $line + ('x' * 18000) + "`n" + $line.Replace('request=r7', 'request=r8') + "`n"
        $stream = New-Object IO.MemoryStream(,[Text.Encoding]::UTF8.GetBytes($text))
        $reader = New-Object IO.StreamReader($stream); $output = New-Object IO.StringWriter
        try {
            [void]$programType.GetMethod('Pump', [Reflection.BindingFlags]'NonPublic,Static').Invoke($null, [object[]]@($reader.PSObject.BaseObject, $output.PSObject.BaseObject))
            $after = $stateType.GetMethod('Snapshot').Invoke($state, @()) | ConvertFrom-Json
            Assert-Equal $after.sequence ($before + 1)
            Assert-Equal $after.last.request_id 'r8'
            Assert-Equal $output.ToString() $text
        } finally { $output.Dispose(); $reader.Dispose(); $stream.Dispose() }
    }
    if ($env:OS -ne 'Windows_NT') {
        Skip-Case 'Windows带当前用户ACL的命名管道与独立控制台生命周期' '当前为非Windows，未执行CreateNamedPipe或控制台事件'
    } else {
        Test-Case 'Windows真实管道回传引擎身份与统计且宿主转发后退出' {
            $hostExe = Join-Path $temporary 'gufo-engine-host.exe'
            Add-Type -Path (Join-Path $WindowsTools 'engine-host.cs') -OutputAssembly $hostExe -OutputType ConsoleApplication
            $fakeExe = Join-Path $temporary '测试 引擎 [v2].exe'
            $fakeCode = 'using System; using System.Threading; public class FakeGufoHostTest { public static int Main(string[] args) { Console.Error.WriteLine("' + $line.Replace('"', '\"') + '"); Thread.Sleep(5000); return 17; }}'
            Add-Type -TypeDefinition $fakeCode -OutputAssembly $fakeExe -OutputType ConsoleApplication
            $name = 'gufo-stats-' + [guid]::NewGuid().ToString('N')
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = $hostExe; $start.Arguments = ConvertTo-GufoArgumentString @($name, $fakeExe, 'serve')
            $start.UseShellExecute = $false; $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
            $process = New-Object Diagnostics.Process; $process.StartInfo = $start
            try {
                [void]$process.Start(); $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
                $snapshot = $null; $due = [DateTime]::UtcNow.AddSeconds(4)
                while ([DateTime]::UtcNow -lt $due -and $null -eq $snapshot) {
                    $client = New-Object IO.Pipes.NamedPipeClientStream('.', $name, [IO.Pipes.PipeDirection]::In)
                    try {
                        $client.Connect(200); $reader = New-Object IO.StreamReader($client, [Text.Encoding]::UTF8)
                        try { $value = $reader.ReadLine() | ConvertFrom-Json; if ($value.sequence -gt 0) { $snapshot = $value } } finally { $reader.Dispose() }
                    } catch { Start-Sleep -Milliseconds 50 } finally { $client.Dispose() }
                }
                Assert-True ($null -ne $snapshot) '未获取到真实命名管道统计'
                Assert-True ($snapshot.engine_pid -gt 0)
                Assert-True ($snapshot.engine_start_utc_ticks -gt 0)
                Assert-Equal $snapshot.last.ttft_ms 40.5
                Assert-True ($process.WaitForExit(7000))
                Assert-Equal $process.ExitCode 17
                Assert-True ($stderr.Result.Contains($line))
            } finally { $process.Dispose() }
        }
        Skip-Case 'Windows独立窗口Ctrl+C与monitor退出后服务继续' '需要Windows真实交互终端人工验收；无GPU测试不模拟通过'
    }
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
Write-Host ("引擎宿主回归：{0} 通过、{1} 失败、{2} 跳过。" -f $script:Passed, $script:Failed, $script:Skipped)
if ($script:Failed -gt 0) { exit 1 }
exit 0
