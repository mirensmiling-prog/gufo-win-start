# HTTP 指标与完成日志回归；全部 fixture 依据官方 16e8ed4 格式，不启动推理。
param([string]$WindowsTools = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $WindowsTools 'monitor-telemetry.ps1')
$script:Passed = 0; $script:Failed = 0
function Assert-True([bool]$Value, [string]$Message = '断言失败') { if (-not $Value) { throw $Message } }
function Assert-Equal($Actual, $Expected) { if ($Actual -cne $Expected) { throw "实际=[$Actual]，预期=[$Expected]" } }
function Assert-Near([double]$Actual, [double]$Expected) { if ([Math]::Abs($Actual - $Expected) -gt 0.001) { throw "实际=[$Actual]，预期=[$Expected]" } }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host "[PASS] $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "[FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-Throws([scriptblock]$Body) {
    $caught = $false; try { & $Body | Out-Null } catch { $caught = $true }
    Assert-True $caught
}

$script:ActualGet = (Get-Command Invoke-GufoTelemetryGet).ScriptBlock
$script:Replies = $null
function Invoke-GufoTelemetryGet($Client, [string]$Path) {
    if ($null -eq $script:Replies) { return & $script:ActualGet $Client $Path }
    if ($script:Replies.Count -eq 0) { throw '读取了未准备的 fixture。' }
    $reply = $script:Replies.Dequeue()
    Assert-Equal $Path $reply.Path
    $reply
}
function New-Reply([string]$Path, [string]$Text, [int]$Status = 200) {
    [pscustomobject]@{ Path = $Path; Text = $Text; Status = $Status; Ok = ($Status -eq 200); Error = $(if ($Status -eq 200) { '' } else { 'HTTP ' + $Status }) }
}
function Set-Replies([object[]]$Values) {
    $script:Replies = New-Object 'Collections.Generic.Queue[object]'
    foreach ($value in $Values) { $script:Replies.Enqueue($value) }
}
function New-TestClient {
    $client = New-GufoTelemetryClient
    $client.Clock.Stop()
    $client.Clock = @{ Elapsed = @{ TotalSeconds = [double]2 } }
    $client
}
function Metrics([double]$Prompt = 100, [double]$Generated = 50, [int]$Active = 1) {
@"
# TYPE llamacpp:prompt_tokens_total counter
llamacpp:prompt_tokens_total $Prompt
llamacpp:tokens_predicted_total $Generated
llamacpp:prompt_tokens_seconds 890.5
llamacpp:predicted_tokens_seconds 42.5
llamacpp:requests_processing $Active
llamacpp:requests_deferred 0
"@
}
function Slots([int]$Decoded = 0, [bool]$Active = $true) {
    $value = @([ordered]@{
        id = 0; is_processing = $Active; id_task = $(if ($Active) { 42 } else { -1 }); state = $(if ($Active) { 1 } else { 0 })
        n_prompt_tokens = 1000; n_prompt_tokens_cache = 500; n_prompt_tokens_processed = 300
        next_token = @(@{ n_decoded = $Decoded; n_remain = 128 }); prompt = ''; model = 'Qwen3.8 Flash Next'
    })
    ConvertTo-Json -InputObject $value -Depth 5 -Compress
}

Test-Case 'HTTP客户端仅使用数字loopback且Key不进入URL' {
    $client = New-GufoTelemetryClient -Port 8088 -ApiKey 'private-key'
    Assert-Equal $client.BaseUri 'http://127.0.0.1:8088'
    Assert-True (-not $client.BaseUri.Contains('private-key'))
    Close-GufoTelemetryClient $client
    Assert-Equal $client.ApiKey ''
}
Test-Case '端口和换行Key提前拒绝' {
    Assert-Throws { New-GufoTelemetryClient -Port 0 }
    Assert-Throws { New-GufoTelemetryClient -ApiKey "key`r`ninjected" }
}
Test-Case '首次快照显示真实进度但不伪造实时速度或TTFT' {
    $client = New-TestClient
    Set-Replies @((New-Reply '/metrics' (Metrics)), (New-Reply '/slots' (Slots)))
    $value = Get-GufoTelemetrySnapshot $client
    Assert-True $value.Available
    Assert-Equal $value.Status 'prefill'
    Assert-Equal $value.PromptTokens 1000
    Assert-Equal $value.PromptCached 500
    Assert-Equal $value.PromptProcessed 300
    Assert-Equal $value.GeneratedTokens 0
    Assert-True ($null -eq $value.LivePrefillTokPerSec)
    Assert-True ($null -eq $value.LiveDecodeTokPerSec)
    Assert-True ($null -eq $value.TtftMs)
    Assert-Equal $value.LastPrefillTokPerSec 890.5
    Assert-Equal $value.LastDecodeTokPerSec 42.5
}
Test-Case '实时prefill和decode按token计数差分而非旧speed gauge' {
    $client = New-TestClient
    Set-Replies @((New-Reply '/metrics' (Metrics 100 50)), (New-Reply '/slots' (Slots)))
    $null = Get-GufoTelemetrySnapshot $client
    $client.Clock.Elapsed.TotalSeconds = 4
    Set-Replies @((New-Reply '/metrics' (Metrics 300 100)), (New-Reply '/slots' (Slots 20)))
    $value = Get-GufoTelemetrySnapshot $client
    Assert-Near $value.LivePrefillTokPerSec 100
    Assert-Near $value.LiveDecodeTokPerSec 25
    Assert-Equal $value.Status 'decode'
    Assert-Equal $value.GeneratedTokens 20
}
Test-Case '无增量时实时速度确为零且旧均值分开保留' {
    $client = New-TestClient
    Set-Replies @((New-Reply '/metrics' (Metrics)), (New-Reply '/slots' (Slots)))
    $null = Get-GufoTelemetrySnapshot $client
    $client.Clock.Elapsed.TotalSeconds = 4
    Set-Replies @((New-Reply '/metrics' (Metrics)), (New-Reply '/slots' (Slots)))
    $value = Get-GufoTelemetrySnapshot $client
    Assert-Near $value.LiveDecodeTokPerSec 0
    Assert-Equal $value.LastDecodeTokPerSec 42.5
}
Test-Case '服务重启计数回退时重置基线且不产生负速度' {
    $client = New-TestClient
    Set-Replies @((New-Reply '/metrics' (Metrics 1000 500)), (New-Reply '/slots' (Slots)))
    $null = Get-GufoTelemetrySnapshot $client
    $client.Clock.Elapsed.TotalSeconds = 4
    Set-Replies @((New-Reply '/metrics' (Metrics 1 1)), (New-Reply '/slots' (Slots)))
    $value = Get-GufoTelemetrySnapshot $client
    Assert-True $value.CounterReset
    Assert-True ($null -eq $value.LivePrefillTokPerSec)
    Assert-True ($null -eq $value.LiveDecodeTokPerSec)
}
Test-Case '超过30秒的缺口不平均冒充当前实时速度' {
    $client = New-TestClient
    Set-Replies @((New-Reply '/metrics' (Metrics)), (New-Reply '/slots' (Slots)))
    $null = Get-GufoTelemetrySnapshot $client
    $client.Clock.Elapsed.TotalSeconds = 100
    Set-Replies @((New-Reply '/metrics' (Metrics 300 100)), (New-Reply '/slots' (Slots)))
    Assert-True ($null -eq (Get-GufoTelemetrySnapshot $client).LiveDecodeTokPerSec)
}
Test-Case '503加载和401鉴权错误不回显内容且清除旧基线' {
    foreach ($status in @(503, 401)) {
        $client = New-TestClient; $client.Previous = @{ Prompt = 1; Generated = 1; Time = 1 }
        Set-Replies @((New-Reply '/metrics' 'private-client-content' $status))
        $value = Get-GufoTelemetrySnapshot $client
        Assert-True (-not $value.Available)
        Assert-True ($null -eq $client.Previous)
        Assert-True (-not ($value | ConvertTo-Json).Contains('private-client-content'))
        Assert-Equal $value.Status $(if ($status -eq 503) { 'loading' } else { 'unavailable' })
    }
}
Test-Case '缺失字段不伪装成零和完整可用' {
    $client = New-TestClient
    Set-Replies @((New-Reply '/metrics' 'llamacpp:requests_processing 1'), (New-Reply '/slots' (Slots)))
    $value = Get-GufoTelemetrySnapshot $client
    Assert-True ($null -eq $value.LiveDecodeTokPerSec)
    Assert-True ($null -eq $value.LastDecodeTokPerSec)
    Assert-True ($value.Error.Contains('字段'))
}
Test-Case '非有限或负指标保持不可用且重复字段拒绝' {
    $value = ConvertFrom-GufoMetrics "llamacpp:prompt_tokens_total NaN`nllamacpp:tokens_predicted_total -3"
    Assert-True ($null -eq $value['llamacpp:prompt_tokens_total'])
    Assert-True ($null -eq $value['llamacpp:tokens_predicted_total'])
    Assert-Throws { ConvertFrom-GufoMetrics "llamacpp:prompt_tokens_total 1`nllamacpp:prompt_tokens_total 2" }
    Assert-Throws { ConvertFrom-GufoMetrics ('x' * 65537) }
}
Test-Case 'slots缺字段时整体进度不可用而保留独立metrics吞吐' {
    $client = New-TestClient
    Set-Replies @((New-Reply '/metrics' (Metrics)), (New-Reply '/slots' '[{"is_processing":true}]'))
    $value = Get-GufoTelemetrySnapshot $client
    Assert-True $value.Available
    Assert-True (-not $value.SlotsAvailable)
    Assert-True ($null -eq $value.GeneratedTokens)
    Assert-True ($value.Error.Contains('slots'))
}
Test-Case '多个活动slot只加总数量而不推断单请求速度' {
    $client = New-TestClient
    $slot = (Slots 20 | ConvertFrom-Json)[0]
    $combined = ConvertTo-Json -InputObject @($slot, $slot) -Depth 5 -Compress
    Set-Replies @((New-Reply '/metrics' (Metrics 100 50 2)), (New-Reply '/slots' $combined))
    $value = Get-GufoTelemetrySnapshot $client
    Assert-Equal $value.PromptProcessed 600
    Assert-Equal $value.GeneratedTokens 40
    Assert-True ($null -eq $value.TtftMs)
}

$completed = '2026-10-27 14:20:00 [INFO] [http] request=r42 event=completed method=POST path=/v1/chat/completions status=200 duration_ms=12000.0 outcome=completed prompt_tokens=1000 prefill_tokens=500 generated_tokens=100 finish=stop cache=memory cached_tokens=500 cache_restore_ms=0.5 queue_depth=0 resident_at_admission=1 queue_ms=12.3 shared_prefix_wait_ms=0.0 ttft_ms=2345.6 prefill_tps=890.5 decode_tps=42.5 batch_width=1 plan=single draft_accepted=80 draft_proposed=100 draft_rounds=20 rss_mib=1000 host_available_mib=2000'
Test-Case '官方真实完成日志解析TTFT与请求平均prefill decode' {
    $value = ConvertFrom-GufoRequestLogLine $completed
    Assert-Equal $value.RequestId 'r42'
    Assert-Near $value.TtftMs 2345.6
    Assert-Near $value.PrefillTokPerSec 890.5
    Assert-Near $value.DecodeTokPerSec 42.5
    Assert-Equal $value.PrefillTokens 500
    Assert-Equal $value.GeneratedTokens 100
    Assert-True (-not ($value | ConvertTo-Json).Contains('/v1/chat/completions'))
}
Test-Case '彩色ANSI日志与普通日志解析值一致' {
    $color = $completed.Replace('[INFO]', ([char]27 + '[32m[INFO]' + [char]27 + '[0m'))
    Assert-Near (ConvertFrom-GufoRequestLogLine $color).TtftMs 2345.6
}
Test-Case '开始日志错误断连和非生成路由不得覆盖最近完成请求' {
    foreach ($line in @($completed.Replace('event=completed', 'event=received'), $completed.Replace('status=200', 'status=500'),
        $completed.Replace('outcome=completed', 'outcome=disconnected'), $completed.Replace('path=/v1/chat/completions', 'path=/metrics'),
        $completed.Replace('[http]', '[prompt]'), $completed.Replace('ttft_ms=2345.6', 'ttft_ms=NaN'), $completed.Replace(' decode_tps=42.5', ''))) {
        Assert-True ($null -eq (ConvertFrom-GufoRequestLogLine $line))
    }
}
Test-Case '没有生成token的完成结果不伪造首token延迟' {
    $value = ConvertFrom-GufoRequestLogLine ($completed.Replace('generated_tokens=100', 'generated_tokens=0'))
    Assert-True ($null -eq $value.TtftMs)
}
Test-Case '完成日志仅固定数值字段且不保留额外客户内容或Key' {
    $value = ConvertFrom-GufoRequestLogLine ($completed + ' api_key=private-secret prompt=private-content')
    $json = $value | ConvertTo-Json
    Assert-True (-not $json.Contains('private-secret'))
    Assert-True (-not $json.Contains('private-content'))
    Assert-True ($null -eq (ConvertFrom-GufoRequestLogLine ($completed + ' ttft_ms=1')))
}

# 原生 HTTP fixture：只监听loopback，独立runspace，验证真正GET/鉴权/redirect策略。
function Invoke-HttpFixture([string]$Mode, [string]$ApiKey = '') {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start(); $port = $listener.LocalEndpoint.Port
    $runner = [PowerShell]::Create()
    try {
        [void]$runner.AddScript({
            param($Listener, $Mode)
            $connection = $Listener.AcceptTcpClient()
            try {
                $stream = $connection.GetStream(); $stream.ReadTimeout = 2000
                $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 4096, $true)
                $headers = New-Object 'Collections.Generic.List[string]'
                while ($true) { $line = $reader.ReadLine(); if ($null -eq $line -or $line -eq '') { break }; $headers.Add($line) }
                $body = 'llamacpp:prompt_tokens_total 10'
                if ($Mode -eq 'large') { $answer = "HTTP/1.1 200 OK`r`nContent-Length: 70000`r`nConnection: close`r`n`r`n" }
                elseif ($Mode -eq 'redirect') { $answer = "HTTP/1.1 302 Found`r`nLocation: http://127.0.0.1:1/leak`r`nContent-Length: 0`r`nConnection: close`r`n`r`n" }
                else { $answer = "HTTP/1.1 200 OK`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body" }
                $bytes = [Text.Encoding]::ASCII.GetBytes($answer); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
                $headers -join "`n"
            } finally { $connection.Dispose() }
        }).AddArgument($listener).AddArgument($Mode)
        $pending = $runner.BeginInvoke()
        $client = New-GufoTelemetryClient -Port $port -ApiKey $ApiKey
        $script:Replies = $null
        $value = Invoke-GufoTelemetryGet $client '/metrics'
        $headers = @($runner.EndInvoke($pending))
        if ($runner.HadErrors) { throw ($runner.Streams.Error | Out-String) }
        [pscustomobject]@{ Value = $value; Headers = ($headers -join "`n") }
    } finally { $listener.Stop(); $runner.Dispose() }
}
Test-Case '真实loopback HTTP读取GET且只按需发送Bearer' {
    $value = Invoke-HttpFixture 'ok' 'fixture-secret'
    Assert-True $value.Value.Ok
    Assert-True ($value.Headers.StartsWith('GET /metrics HTTP/1.1'))
    Assert-True ($value.Headers.Contains('Authorization: Bearer fixture-secret'))
    $without = Invoke-HttpFixture 'ok'
    Assert-True (-not $without.Headers.Contains('Authorization:'))
}
Test-Case '真实HTTP拒绝redirect且不跟随到另一个地址' {
    $value = Invoke-HttpFixture 'redirect' 'fixture-secret'
    Assert-True (-not $value.Value.Ok)
    Assert-Equal $value.Value.Status 302
    Assert-True (-not ($value.Value | ConvertTo-Json).Contains('fixture-secret'))
}
Test-Case '真实HTTP拒绝超大响应而不读取无界正文' {
    $value = Invoke-HttpFixture 'large'
    Assert-True (-not $value.Value.Ok)
    Assert-Equal $value.Value.Text ''
}

Write-Host ('遥测定向回归：{0} 通过、{1} 失败。' -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
