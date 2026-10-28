# 可选轻量监控：只保留最近 30 秒的有界采样，不写监控日志。
Set-StrictMode -Version 2.0

function Initialize-GufoMonitor {
    if ($env:OS -ne 'Windows_NT') { throw '原生监控仅支持 Windows。' }
    if (-not ('GufoMonitor.Sampler' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'monitor-native.cs') -ErrorAction Stop
    }
}

function New-GufoMonitorHistory {
    @{ Samples = (New-Object 'Collections.Generic.Queue[object]'); TotalWriteBytes = [double]0; ObservedSeconds = [double]0 }
}

function Update-GufoMonitorHistory($History, [double]$Seconds, [bool]$Valid, [double]$WriteRate, $Snapshot = $null) {
    if ($Seconds -le 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) { return }
    $validRate = $Valid -and $WriteRate -ge 0 -and -not [double]::IsNaN($WriteRate) -and -not [double]::IsInfinity($WriteRate)
    if ($validRate) {
        $History.TotalWriteBytes += $WriteRate * $Seconds
        $History.ObservedSeconds += $Seconds
    }
    $readRate = $null; $memoryPercent = $null
    if ($null -ne $Snapshot) {
        if ($Snapshot.DiskValid) { $readRate = $Snapshot.DiskReadBytesPerSecond }
        if ($Snapshot.SystemMemoryValid -and $Snapshot.TotalMemoryBytes -gt 0) {
            $memoryPercent = 100 * (1 - [double]$Snapshot.AvailableMemoryBytes / $Snapshot.TotalMemoryBytes)
        }
    }
    $History.Samples.Enqueue([pscustomobject]@{
        Seconds = [Math]::Min(30, $Seconds); Valid = $validRate; Rate = $WriteRate
        ReadRate = $readRate; MemoryPercent = $memoryPercent
    })
    # 固定两秒刷新，最多保留 16 条；按时长裁剪，预防长时间运行积累内存。
    while ($History.Samples.Count -gt 16) { [void]$History.Samples.Dequeue() }
    $duration = [double]0
    foreach ($item in $History.Samples) { $duration += $item.Seconds }
    while ($History.Samples.Count -gt 1 -and $duration - $History.Samples.Peek().Seconds -ge 30) {
        $duration -= $History.Samples.Dequeue().Seconds
    }
}

function Get-GufoMonitorWriteAverage($History) {
    $items = @($History.Samples.ToArray())
    $seconds = [double]0; $bytes = [double]0
    for ($i = $items.Count - 1; $i -ge 0 -and $seconds -lt 30; $i--) {
        if (-not $items[$i].Valid) { return $null }
        $take = [Math]::Min($items[$i].Seconds, 30 - $seconds)
        $seconds += $take; $bytes += $items[$i].Rate * $take
    }
    if ($seconds -le 0) { return $null }
    [pscustomobject]@{ Rate = ($bytes / $seconds); Seconds = $seconds }
}

function Format-GufoMonitorBytes($Bytes) {
    if ($null -eq $Bytes) { return '不可用' }
    if ([double]$Bytes -ge 1GB) { return ('{0:N2} GiB' -f ([double]$Bytes / 1GB)) }
    if ([double]$Bytes -ge 1MB) { return ('{0:N1} MiB' -f ([double]$Bytes / 1MB)) }
    if ([double]$Bytes -ge 1KB) { return ('{0:N1} KiB' -f ([double]$Bytes / 1KB)) }
    '{0:N0} B' -f [double]$Bytes
}

function Get-GufoMonitorTrend($History, [string]$Kind, [int]$Width = 24) {
    $values = @(foreach ($item in $History.Samples) {
        switch ($Kind) {
            'Memory' { $item.MemoryPercent }
            'Read' { $item.ReadRate }
            'Write' { if ($item.Valid) { $item.Rate } else { $null } }
        }
    })
    if ($values.Count -eq 0) { return '采样中' }
    $maximum = if ($Kind -eq 'Memory') { [double]100 } else { [double]0 }
    foreach ($value in $values) { if ($null -ne $value -and [double]$value -gt $maximum) { $maximum = [double]$value } }
    $glyphs = '.:-=+*#@'
    $text = New-Object Text.StringBuilder
    $start = [Math]::Max(0, $values.Count - $Width)
    for ($i = $start; $i -lt $values.Count; $i++) {
        $value = $values[$i]
        if ($null -eq $value) { [void]$text.Append('?') }
        elseif ([double]$value -le 0 -or $maximum -le 0) { [void]$text.Append('.') }
        else {
            $level = [Math]::Min(7, [Math]::Max(0, [int][Math]::Ceiling(8 * [double]$value / $maximum) - 1))
            [void]$text.Append($glyphs[$level])
        }
    }
    $text.ToString().PadLeft($Width)
}

function Get-GufoMonitorPanel([string]$Title, [string[]]$Lines, [int]$Width) {
    $inside = $Width - 4
    $heading = '- ' + $Title + ' '
    '+' + $heading + ('-' * [Math]::Max(0, $Width - 2 - (Get-GufoCellWidth $heading))) + '+'
    foreach ($line in $Lines) {
        foreach ($part in @(Split-GufoConsoleLine -Text $line -Width $inside -ContinuationPrefix '')) {
            '| ' + $part + (' ' * [Math]::Max(0, $inside - (Get-GufoCellWidth $part))) + ' |'
        }
    }
    '+' + ('-' * ($Width - 2)) + '+'
}

function Get-GufoMonitorHeight {
    $heights = New-Object 'Collections.Generic.List[int]'
    try { if ($Host.UI.RawUI.WindowSize.Height -gt 0) { $heights.Add([int]$Host.UI.RawUI.WindowSize.Height) } } catch { }
    try { if ([Console]::WindowHeight -gt 0) { $heights.Add([Console]::WindowHeight) } } catch { }
    if ($heights.Count -gt 0) { return [int](($heights | Measure-Object -Minimum).Minimum) }
    30
}

function Format-GufoMonitorRate($Value) {
    if ($null -eq $Value) { return '采样中/不可用' }
    '{0:N1} tok/s' -f [double]$Value
}

function Format-GufoMonitorCount($Value) {
    if ($null -eq $Value) { return '--' }
    '{0:N0}' -f [double]$Value
}

function Get-GufoLastRequest($HostSnapshot) {
    if ($null -eq $HostSnapshot -or $null -eq $HostSnapshot.last) { return $null }
    $last = $HostSnapshot.last
    $values = @{}
    foreach ($key in @('ttft_ms', 'prefill_tps', 'decode_tps', 'prompt_tokens', 'prefill_tokens', 'generated_tokens', 'cached_tokens', 'queue_ms', 'duration_ms')) {
        $property = $last.PSObject.Properties[$key]
        if ($null -eq $property) { return $null }
        $number = ConvertTo-GufoTelemetryNumber $property.Value
        if ($null -eq $number) { return $null }
        $values[$key] = $number
    }
    $id = if ([string]$last.request_id -match '^r[0-9]{1,18}$') { [string]$last.request_id } else { '--' }
    [pscustomobject]@{
        RequestId = $id; TtftMs = $(if ($values.generated_tokens -gt 0) { $values.ttft_ms } else { $null })
        PrefillTokPerSec = $values.prefill_tps; DecodeTokPerSec = $values.decode_tps
        PromptTokens = $values.prompt_tokens; PrefillTokens = $values.prefill_tokens
        GeneratedTokens = $values.generated_tokens; CachedTokens = $values.cached_tokens
        QueueMs = $values.queue_ms; DurationMs = $values.duration_ms
    }
}

function Write-GufoMonitorFrame([string[]]$Lines, [hashtable]$State) {
    $width = Get-GufoConsoleWidth
    $height = Get-GufoMonitorHeight
    $visible = [Math]::Min($Lines.Count, [Math]::Max(1, $height - 1))
    $rows = [Math]::Min([Math]::Max($visible, $State.PreviousRows), [Math]::Max(1, $height - 1))
    $frame = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $rows; $i++) {
        $line = if ($i -lt $visible) { $Lines[$i] } else { '' }
        $cells = Get-GufoCellWidth $line
        if ($cells -gt $width) { return } # 窗口在构帧后缩小：下一轮按新宽度重排，不中断服务或监控。
        [void]$frame.Append($line)
        [void]$frame.Append(' ' * ($width - $cells))
        if ($i -lt $rows - 1) { [void]$frame.Append([Environment]::NewLine) }
    }
    # 只在首次显示清屏；后续回到屏幕起点覆盖同一帧，无 Clear-Host 闪白。
    if (-not $State.Initialized) { [Console]::Clear(); $State.Initialized = $true }
    [Console]::SetCursorPosition(0, [Console]::WindowTop)
    [Console]::Write($frame.ToString())
    $State.PreviousRows = $visible
}

function Show-GufoMonitor($Sample, $History, [int]$TargetId, [double]$MonitorBytes, [string]$Caption = '',
    $Telemetry = $null, $LastRequest = $null, [hashtable]$FrameState = $null) {
    $width = [Math]::Min(150, (Get-GufoConsoleWidth))
    $height = Get-GufoMonitorHeight
    $compact = $height -lt 30 -or ($width -lt 100 -and $height -lt 38)
    $lines = New-Object 'Collections.Generic.List[string]'
    foreach ($line in @(Split-GufoConsoleLine ('GUFO 中文监控 | PID {0} | {1:HH:mm:ss}' -f $TargetId, [DateTime]::Now) $width)) { $lines.Add($line) }
    if ($Caption) {
        $captionRows = @(Split-GufoConsoleLine $Caption $width -ContinuationPrefix '')
        $lines.Add($captionRows[0])
    }
    $status = '连接中'
    if ($null -ne $Telemetry) {
        $labels = @{ loading = '模型加载中'; idle = '空闲'; prefill = '预填充中'; decode = '生成中'; busy = '请求处理中'; unavailable = '指标暂不可用' }
        if ($labels.ContainsKey([string]$Telemetry.Status)) { $status = $labels[[string]$Telemetry.Status] }
    }
    $inference = New-Object 'Collections.Generic.List[string]'
    $inference.Add('服务状态：' + $status)
    if ($null -ne $LastRequest) {
        $ttft = if ($null -eq $LastRequest.TtftMs) { '无生成 token' } else { '{0:N1} ms' -f $LastRequest.TtftMs }
        $inference.Add(('首 token 延迟(TTFT)：{0} [最近请求 {1}]' -f $ttft, $LastRequest.RequestId))
        $inference.Add(('预填充 Prefill：{0} token / {1}' -f (Format-GufoMonitorCount $LastRequest.PrefillTokens), (Format-GufoMonitorRate $LastRequest.PrefillTokPerSec)))
        $inference.Add(('生成 Decode：{0} token / {1}' -f (Format-GufoMonitorCount $LastRequest.GeneratedTokens), (Format-GufoMonitorRate $LastRequest.DecodeTokPerSec)))
    } else {
        $inference.Add('首 token 延迟(TTFT)：等待一次请求完成')
        $inference.Add('预填充 Prefill：等待一次请求完成')
        $inference.Add('生成 Decode：等待一次请求完成')
    }
    if ($null -ne $Telemetry) {
        $inference.Add(('实时吞吐：Prefill {0} / Decode {1}' -f (Format-GufoMonitorRate $Telemetry.LivePrefillTokPerSec), (Format-GufoMonitorRate $Telemetry.LiveDecodeTokPerSec)))
        $inference.Add(('活动请求：{0} / 排队：{1} / 已预填充：{2} / 已生成：{3} token' -f
            (Format-GufoMonitorCount $Telemetry.ActiveRequests), (Format-GufoMonitorCount $Telemetry.QueuedRequests),
            (Format-GufoMonitorCount $Telemetry.PromptProcessed), (Format-GufoMonitorCount $Telemetry.GeneratedTokens)))
    } else { $inference.Add('实时吞吐：正在连接本机 Gufo 指标接口') }
    $used = $null
    if ($Sample.SystemMemoryValid) { $used = [double]$Sample.TotalMemoryBytes - $Sample.AvailableMemoryBytes }
    $memoryLines = @(
        ('Gufo 工作集：{0}' -f (Format-GufoMonitorBytes $(if ($Sample.ProcessMemoryValid) { $Sample.WorkingSetBytes }))),
        ('Gufo 私有提交：{0}' -f (Format-GufoMonitorBytes $(if ($Sample.ProcessMemoryValid) { $Sample.PrivateBytes }))),
        ('系统已用 / 总量：{0} / {1}' -f (Format-GufoMonitorBytes $used), (Format-GufoMonitorBytes $(if ($Sample.SystemMemoryValid) { $Sample.TotalMemoryBytes }))),
        ('系统可用：{0}' -f (Format-GufoMonitorBytes $(if ($Sample.SystemMemoryValid) { $Sample.AvailableMemoryBytes }))),
        ('监控总工作集：{0}' -f (Format-GufoMonitorBytes $MonitorBytes))
    )
    $average = Get-GufoMonitorWriteAverage $History
    $averageText = if ($null -eq $average) { '不可用' } else { '{0}/s' -f (Format-GufoMonitorBytes $average.Rate) }
    $totalText = if ($History.ObservedSeconds -gt 0) { Format-GufoMonitorBytes $History.TotalWriteBytes } else { '尚无有效样本' }
    $diskLines = @(
        ('读取：{0}' -f $(if ($Sample.DiskValid) { (Format-GufoMonitorBytes $Sample.DiskReadBytesPerSecond) + '/s' } else { '不可用' })),
        ('写入：{0}' -f $(if ($Sample.DiskValid) { (Format-GufoMonitorBytes $Sample.DiskWriteBytesPerSecond) + '/s' } else { '不可用' })),
        ('近30秒平均写入：{0}' -f $averageText),
        ('本次写入估算：{0}' -f $totalText),
        ('写趋势 {0}' -f (Get-GufoMonitorTrend $History 'Write' ([Math]::Max(4, [Math]::Min(30, $width - 16)))))
    )
    if ($width -ge 100) {
        foreach ($line in @(Get-GufoMonitorPanel '推理性能 / 最近请求与实时采样' $inference.ToArray() $width)) { $lines.Add($line) }
        $panelWidth = [int][Math]::Floor(($width - 2) / 2)
        $left = @(Get-GufoMonitorPanel '内存占用' $memoryLines $panelWidth)
        $right = @(Get-GufoMonitorPanel '整机磁盘读写' $diskLines $panelWidth)
        for ($i = 0; $i -lt [Math]::Max($left.Count, $right.Count); $i++) {
            $first = if ($i -lt $left.Count) { $left[$i] } else { ' ' * $panelWidth }
            $second = if ($i -lt $right.Count) { $right[$i] } else { '' }
            $lines.Add($first + '  ' + $second)
        }
    } elseif ($width -ge 40 -and -not $compact) {
        foreach ($line in @(Get-GufoMonitorPanel '推理性能' $inference.ToArray() $width)) { $lines.Add($line) }
        foreach ($line in @(Get-GufoMonitorPanel '内存占用' $memoryLines $width)) { $lines.Add($line) }
        foreach ($line in @(Get-GufoMonitorPanel '整机磁盘读写' $diskLines $width)) { $lines.Add($line) }
    } else {
        # 矮窗以核心指标优先，避免三个高框将性能数据挤出屏幕。
        foreach ($line in $inference) { foreach ($part in @(Split-GufoConsoleLine $line $width)) { $lines.Add($part) } }
        $hardware = @($memoryLines) + @($diskLines)
        foreach ($line in $hardware) { foreach ($part in @(Split-GufoConsoleLine $line $width)) { $lines.Add($part) } }
    }
    $notes = @(
        'TTFT/Prefill/Decode 来自最近完成请求；实时吞吐为采样区间全服务计数差分。',
        '磁盘是整机总量，含其他程序/分页；私有提交非页文件实写，工作集非完整 GPU 分配。',
        'Q/Esc 关闭监控，Gufo 继续运行 | 每2秒刷新 | 无监控日志'
    )
    if ($null -ne $Telemetry -and $Telemetry.Error) { $notes = @('指标：' + $Telemetry.Error) + $notes }
    if (-not $Sample.DiskValid) { $notes = @('磁盘：' + $Sample.DiskError) + $notes }
    foreach ($note in $notes) { foreach ($line in @(Split-GufoConsoleLine $note $width)) { $lines.Add($line) } }
    # 小窗口优先保留指标与退出提示，完整口径见使用说明。
    if ($lines.Count -ge $height) {
        $exit = @(Split-GufoConsoleLine 'Q/Esc 仅退监控，Gufo 继续 | 每2秒刷新' $width)
        $limit = [Math]::Max(1, $height - 1 - $exit.Count)
        $trimmed = @($lines.ToArray() | Select-Object -First $limit) + $exit
        $lines.Clear(); foreach ($line in $trimmed) { $lines.Add($line) }
    }
    if ($null -ne $FrameState) { Write-GufoMonitorFrame -Lines $lines.ToArray() -State $FrameState }
    else { foreach ($line in $lines) { Write-Host $line -ForegroundColor Cyan } }
}

function Test-GufoMonitorQuit {
    try {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::Escape) { return $true }
        }
    } catch { }
    $false
}

function Start-GufoMonitor([Diagnostics.Process]$Process, [string]$Caption = '', [int]$Port = 8080,
    [string]$ApiKey = '', [string]$StatsPipeName = '') {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { throw '监控需要交互终端；本次未保留监控，Gufo 继续运行。' }
    . (Join-Path $PSScriptRoot 'monitor-telemetry.ps1')
    . (Join-Path $PSScriptRoot 'launcher-host.ps1')
    Initialize-GufoMonitor
    $sampler = $null; $self = $null; $client = $null; $engine = $null; $ownEngineHandle = $false
    $cursor = $true
    try {
        $client = New-GufoTelemetryClient -Port $Port -ApiKey $ApiKey
        $ApiKey = ''
        $engine = $Process
        $hostSnapshot = $null
        if ($StatsPipeName) {
            $wait = [Diagnostics.Stopwatch]::StartNew()
            while ($wait.Elapsed.TotalSeconds -lt 5 -and -not $Process.HasExited) {
                $hostSnapshot = Get-GufoEngineHostSnapshot $StatsPipeName
                if ($null -ne $hostSnapshot) { break }
                Start-Sleep -Milliseconds 100
            }
            if ($null -eq $hostSnapshot) { throw '未取得引擎统计连接；请查看 Gufo 服务窗口。' }
            $engine = [Diagnostics.Process]::GetProcessById([int]$hostSnapshot.engine_pid)
            $ownEngineHandle = $true
            if ($engine.StartTime.ToUniversalTime().Ticks -ne [int64]$hostSnapshot.engine_start_utc_ticks) { throw '引擎进程身份已变化，已停止监控。' }
        }
        $sampler = New-Object GufoMonitor.Sampler -ArgumentList $engine.Handle
        $self = [Diagnostics.Process]::GetCurrentProcess()
        $history = New-GufoMonitorHistory
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $previous = $timer.Elapsed.TotalSeconds
        $sample = $sampler.Read()
        $frameState = @{ Initialized = $false; PreviousRows = 0 }
        $last = Get-GufoLastRequest $hostSnapshot
        try { $cursor = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { }
        while ($sample.Alive) {
            $cycleStarted = $timer.Elapsed.TotalSeconds
            if (Test-GufoMonitorQuit) { return }
            $telemetry = Get-GufoTelemetrySnapshot $client
            if ($StatsPipeName) { $hostSnapshot = Get-GufoEngineHostSnapshot $StatsPipeName }
            $candidate = Get-GufoLastRequest $hostSnapshot
            if ($null -ne $candidate) { $last = $candidate }
            $self.Refresh()
            $overhead = [double]$self.WorkingSet64
            if ($StatsPipeName) { $Process.Refresh(); $overhead += $Process.WorkingSet64 }
            Show-GufoMonitor $sample $history $engine.Id $overhead $Caption $telemetry $last $frameState
            $due = $cycleStarted + 2
            while ($timer.Elapsed.TotalSeconds -lt $due) {
                if (Test-GufoMonitorQuit) { return }
                if ($Process.WaitForExit(200)) { return }
            }
            $sample = $sampler.Read()
            $now = $timer.Elapsed.TotalSeconds
            Update-GufoMonitorHistory $history ($now - $previous) $sample.DiskValid $sample.DiskWriteBytesPerSecond $sample
            $previous = $now
        }
    } finally {
        if ($sampler) { $sampler.Dispose() }
        if ($self) { $self.Dispose() }
        if ($ownEngineHandle -and $engine) { $engine.Dispose() }
        if ($client) { Close-GufoTelemetryClient $client }
        $ApiKey = ''
        try { [Console]::CursorVisible = $cursor; [Console]::ResetColor(); [Console]::WriteLine() } catch { }
    }
}
