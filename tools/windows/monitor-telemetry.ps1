# Gufo v0.25.0 只读指标：固定官方 16e8ed4 的 /metrics、/slots 和完成日志格式。
# 实时吞吐为全服务 token 计数差分；speed gauge 只代表最近非零请求。
Set-StrictMode -Version 2.0

function New-GufoTelemetryClient([int]$Port = 8080, [string]$ApiKey = '') {
    if ($Port -lt 1 -or $Port -gt 65535) { throw '监控端口必须在 1-65535。' }
    if ($ApiKey -match '[\r\n]') { throw '监控 Key 含无效字符。' }
    @{
        BaseUri = ('http://127.0.0.1:{0}' -f $Port); ApiKey = $ApiKey
        Clock = [Diagnostics.Stopwatch]::StartNew(); Previous = $null
        TimeoutMs = 500; MaxResponseBytes = 65536
    }
}

function Close-GufoTelemetryClient($Client) {
    if ($null -eq $Client) { return }
    $Client.ApiKey = ''; $Client.Previous = $null
    $Client.Clock.Stop()
}

function Invoke-GufoTelemetryGet($Client, [string]$Path) {
    if (@('/metrics', '/slots') -notcontains $Path) { throw '监控只允许读取 metrics 和 slots。' }
    $response = $null; $stream = $null; $buffered = $null
    try {
        $request = [Net.HttpWebRequest]::Create($Client.BaseUri + $Path)
        $request.Method = 'GET'; $request.Proxy = $null; $request.AllowAutoRedirect = $false
        $request.Timeout = $Client.TimeoutMs; $request.ReadWriteTimeout = $Client.TimeoutMs
        $request.KeepAlive = $true
        if ($Client.ApiKey) { $request.Headers['Authorization'] = 'Bearer ' + $Client.ApiKey }
        $response = $request.GetResponse()
        $status = [int]$response.StatusCode
        if ($status -ne 200) { return [pscustomobject]@{ Ok = $false; Status = $status; Text = ''; Error = ('HTTP {0}' -f $status) } }
        if ($response.ContentLength -gt $Client.MaxResponseBytes) { throw 'response-too-large' }
        $stream = $response.GetResponseStream()
        $buffered = New-Object IO.MemoryStream
        $buffer = New-Object byte[] 4096
        $readClock = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            if ($readClock.ElapsedMilliseconds -gt $Client.TimeoutMs) { throw 'response-timeout' }
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -eq 0) { break }
            if ($buffered.Length + $read -gt $Client.MaxResponseBytes) { throw 'response-too-large' }
            $buffered.Write($buffer, 0, $read)
        }
        [pscustomobject]@{ Ok = $true; Status = 200; Text = [Text.Encoding]::UTF8.GetString($buffered.ToArray()); Error = '' }
    } catch {
        $code = 0
        if ($_.Exception -is [Net.WebException] -and $null -ne $_.Exception.Response) {
            try { $code = [int]$_.Exception.Response.StatusCode } finally { $_.Exception.Response.Close() }
        }
        # 不返回异常或响应正文，避免把 Key、客户内容或本地路径显示到监控。
        $message = if ($code -gt 0) { 'HTTP {0}' -f $code } else { '连接超时、服务未就绪或响应无效' }
        [pscustomobject]@{ Ok = $false; Status = $code; Text = ''; Error = $message }
    } finally {
        if ($buffered) { $buffered.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Close() }
    }
}

function ConvertTo-GufoTelemetryNumber($Value) {
    $number = [double]0
    if ($null -eq $Value -or -not [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
        [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0) { return $null }
    $number
}

function ConvertFrom-GufoMetrics([string]$Text) {
    if ($Text.Length -gt 65536) { throw '指标响应超过上限。' }
    $result = @{}
    foreach ($line in ($Text -split "`n")) {
        if ($line -match '^\s*(llamacpp:[a-z_]+|gufo_device_lost_total)\s+(\S+)\s*$') {
            $name = $Matches[1]; $number = ConvertTo-GufoTelemetryNumber $Matches[2]
            if ($result.ContainsKey($name)) { throw '指标包含重复字段。' }
            $result[$name] = $number
        }
    }
    if ($result.Count -eq 0) { throw '未识别到 Gufo 指标。' }
    $result
}

function New-GufoTelemetrySnapshot {
    [pscustomobject]@{
        Available = $false; Status = 'unavailable'; Error = ''; SlotsAvailable = $false
        LivePrefillTokPerSec = $null; LiveDecodeTokPerSec = $null
        LastPrefillTokPerSec = $null; LastDecodeTokPerSec = $null
        ActiveRequests = $null; QueuedRequests = $null
        PromptTokens = $null; PromptCached = $null; PromptProcessed = $null; GeneratedTokens = $null
        CounterReset = $false; TtftMs = $null; TtftSource = 'HTTP 接口未提供；需请求完成日志'
    }
}

function Get-GufoTelemetrySnapshot($Client) {
    $snapshot = New-GufoTelemetrySnapshot
    $reply = Invoke-GufoTelemetryGet $Client '/metrics'
    if (-not $reply.Ok) {
        $Client.Previous = $null
        $snapshot.Status = if ($reply.Status -eq 503) { 'loading' } else { 'unavailable' }
        $snapshot.Error = $reply.Error
        return $snapshot
    }
    try { $metrics = ConvertFrom-GufoMetrics $reply.Text }
    catch { $Client.Previous = $null; $snapshot.Error = '指标响应格式无效'; return $snapshot }
    $snapshot.Available = $true
    $snapshot.ActiveRequests = $metrics['llamacpp:requests_processing']
    $snapshot.QueuedRequests = $metrics['llamacpp:requests_deferred']
    foreach ($entry in @(@('llamacpp:prompt_tokens_seconds', 'LastPrefillTokPerSec'), @('llamacpp:predicted_tokens_seconds', 'LastDecodeTokPerSec'))) {
        $value = $metrics[$entry[0]]
        if ($null -ne $value -and $value -gt 0) { $snapshot.($entry[1]) = $value }
    }
    $prompt = $metrics['llamacpp:prompt_tokens_total']; $generated = $metrics['llamacpp:tokens_predicted_total']
    $now = $Client.Clock.Elapsed.TotalSeconds
    if ($null -ne $prompt -and $null -ne $generated) {
        if ($null -ne $Client.Previous) {
            $seconds = $now - $Client.Previous.Time
            if ($prompt -lt $Client.Previous.Prompt -or $generated -lt $Client.Previous.Generated) { $snapshot.CounterReset = $true }
            elseif ($seconds -gt 0 -and $seconds -le 30) {
                $snapshot.LivePrefillTokPerSec = ($prompt - $Client.Previous.Prompt) / $seconds
                $snapshot.LiveDecodeTokPerSec = ($generated - $Client.Previous.Generated) / $seconds
            }
        }
        $Client.Previous = @{ Prompt = $prompt; Generated = $generated; Time = $now }
    } else { $Client.Previous = $null; $snapshot.Error = '部分 token 计数字段不可用' }
    $snapshot.Status = if ($null -eq $snapshot.ActiveRequests) { 'busy' } elseif ($snapshot.ActiveRequests -gt 0) { 'busy' } else { 'idle' }
    $slotsReply = Invoke-GufoTelemetryGet $Client '/slots'
    if (-not $slotsReply.Ok) { $snapshot.Error = ('slots 不可用：{0}' -f $slotsReply.Error); return $snapshot }
    try {
        if (-not $slotsReply.Text.TrimStart().StartsWith('[')) { throw 'slots-not-array' }
        $slots = @($slotsReply.Text | ConvertFrom-Json)
        $totals = @{ PromptTokens = [double]0; PromptCached = [double]0; PromptProcessed = [double]0; GeneratedTokens = [double]0 }
        $active = 0
        foreach ($slot in $slots) {
            $processing = $slot.PSObject.Properties['is_processing']
            if ($null -eq $processing -or $processing.Value -isnot [bool]) { throw 'slots-processing-missing' }
            if (-not $processing.Value) { continue }
            $active++
            foreach ($entry in @(@('n_prompt_tokens', 'PromptTokens'), @('n_prompt_tokens_cache', 'PromptCached'), @('n_prompt_tokens_processed', 'PromptProcessed'))) {
                $property = $slot.PSObject.Properties[$entry[0]]
                $value = if ($null -ne $property) { ConvertTo-GufoTelemetryNumber $property.Value } else { $null }
                if ($null -eq $value) { throw 'slots-count-missing' }
                $totals[$entry[1]] += $value
            }
            $next = $slot.PSObject.Properties['next_token']
            if ($null -eq $next -or @($next.Value).Count -eq 0) { throw 'slots-next-token-missing' }
            $decoded = @($next.Value)[0].PSObject.Properties['n_decoded']
            $value = if ($null -ne $decoded) { ConvertTo-GufoTelemetryNumber $decoded.Value } else { $null }
            if ($null -eq $value) { throw 'slots-decoded-missing' }
            $totals.GeneratedTokens += $value
        }
        foreach ($name in $totals.Keys) { $snapshot.$name = $totals[$name] }
        $snapshot.SlotsAvailable = $true
        # metrics 与 slots 并非原子快照；只将 slots 用于请求进度，不反推单请求速度或首 token 延迟。
        if ($active -gt 0) { $snapshot.Status = if ($totals.GeneratedTokens -gt 0) { 'decode' } elseif ($totals.PromptProcessed -gt 0) { 'prefill' } else { 'busy' } }
        elseif ($snapshot.ActiveRequests -gt 0) { $snapshot.Status = 'busy' }
    } catch { $snapshot.Error = 'slots 格式或计数字段不可用' }
    $snapshot
}

function ConvertFrom-GufoRequestLogLine([string]$Line) {
    # 来源：generation_metrics.hpp:143 与 logging.cpp:173。只保留固定数值，不保留正文、路径或任意日志。
    if (-not $Line -or $Line.Length -gt 16384) { return $null }
    $clean = [regex]::Replace($Line, '\x1B\[[0-?]*[ -/]*[@-~]', '')
    if ($clean -notmatch '\[INFO\]\s+\[http\]\s+request=(r[0-9]+)\s+event=completed\s+method=POST\s+') { return $null }
    $requestId = $Matches[1]; $fields = @{}
    foreach ($match in [regex]::Matches($clean, '(?<!\S)([a-z_]+)=([^\s]+)')) {
        $name = $match.Groups[1].Value
        if ($fields.ContainsKey($name)) { return $null }
        $fields[$name] = $match.Groups[2].Value
    }
    if ($fields['outcome'] -ne 'completed' -or $fields['status'] -notmatch '^2[0-9][0-9]$' -or
        @('/v1/chat/completions', '/v1/completions', '/v1/messages', '/v1/responses', '/completion') -notcontains $fields['path']) { return $null }
    $numbers = @{}
    foreach ($name in @('ttft_ms', 'prefill_tps', 'decode_tps', 'prompt_tokens', 'prefill_tokens', 'generated_tokens', 'cached_tokens', 'queue_ms', 'duration_ms')) {
        $number = ConvertTo-GufoTelemetryNumber $fields[$name]
        if ($null -eq $number) { return $null }
        $numbers[$name] = $number
    }
    [pscustomobject]@{
        RequestId = $requestId; TtftMs = $(if ($numbers.generated_tokens -gt 0) { $numbers.ttft_ms } else { $null })
        PrefillTokPerSec = $numbers.prefill_tps; DecodeTokPerSec = $numbers.decode_tps
        PromptTokens = $numbers.prompt_tokens; PrefillTokens = $numbers.prefill_tokens
        GeneratedTokens = $numbers.generated_tokens; CachedTokens = $numbers.cached_tokens
        QueueMs = $numbers.queue_ms; DurationMs = $numbers.duration_ms; FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}
