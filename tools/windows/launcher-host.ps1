# 监控开启时才加载：独立引擎窗口转发原生日志，通过只读本机管道取数。
Set-StrictMode -Version 2.0

function Get-GufoEngineHostPath {
    if ($env:OS -ne 'Windows_NT') { throw '统计宿主只能在 Windows 编译。' }
    $source = Join-Path $PSScriptRoot 'engine-host.cs'
    $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    $cacheRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GufoLauncher'
    [void][IO.Directory]::CreateDirectory($cacheRoot)
    $destination = Join-Path $cacheRoot ('engine-host-' + $hash + '.exe')
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        $temporary = Join-Path $cacheRoot ([guid]::NewGuid().ToString('N') + '.exe')
        try {
            # 使用 Windows PowerShell 5.1 支持的参数；CompilerOptions 是较新版本的参数。
            Add-Type -Path $source -OutputAssembly $temporary -OutputType ConsoleApplication -ErrorAction Stop
            try { [IO.File]::Move($temporary, $destination) }
            catch { if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { throw } }
        } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    }
    $destination
}

function Start-GufoMonitoredEngine([string]$ExePath, [string[]]$Arguments) {
    $hostExe = Get-GufoEngineHostPath
    $pipeName = 'gufo-stats-' + [guid]::NewGuid().ToString('N')
    # 仍直接传给 EXE，不经 cmd；Key 与原启动一样只在进程 argv/内存中，不落 plan 文件。
    $hostArguments = ConvertTo-GufoArgumentString (@($pipeName, $ExePath) + $Arguments)
    try { $process = Start-Process -FilePath $hostExe -ArgumentList $hostArguments -WorkingDirectory ([IO.Path]::GetDirectoryName($ExePath)) -PassThru }
    catch { throw '无法启动独立 Gufo 窗口，请用 start.cmd -Foreground 排查。' }
    finally { $hostArguments = ''; $Arguments = $null }
    [pscustomobject]@{ Process = $process; PipeName = $pipeName }
}

function Get-GufoEngineHostSnapshot([string]$PipeName) {
    if ($PipeName -notmatch '^gufo-stats-[a-f0-9]{32}$') { return $null }
    $pipe = $null
    try {
        $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', $PipeName, [IO.Pipes.PipeDirection]::In, [IO.Pipes.PipeOptions]::Asynchronous)
        $pipe.Connect(120)
        $buffer = New-Object byte[] 8192
        $used = 0; $done = $false
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not $done -and $used -lt $buffer.Length) {
            $pending = $pipe.BeginRead($buffer, $used, ($buffer.Length - $used), $null, $null)
            try {
                $remaining = [Math]::Max(1, 300 - [int]$timer.ElapsedMilliseconds)
                if (-not $pending.AsyncWaitHandle.WaitOne($remaining)) {
                    $pipe.Dispose()
                    try { [void]$pipe.EndRead($pending) } catch { }
                    return $null
                }
                $read = $pipe.EndRead($pending)
            } finally { $pending.AsyncWaitHandle.Close() }
            if ($read -le 0) { break }
            $used += $read
            for ($i = 0; $i -lt $used; $i++) { if ($buffer[$i] -eq 10) { $done = $true; break } }
            if ($timer.ElapsedMilliseconds -ge 300 -and -not $done) { return $null }
        }
        if (-not $done) { return $null }
        $json = [Text.Encoding]::UTF8.GetString($buffer, 0, $used).Trim()
        $snapshot = $json | ConvertFrom-Json
        if ($snapshot.schema -ne 1 -or [int64]$snapshot.engine_pid -le 0 -or [int64]$snapshot.engine_start_utc_ticks -le 0) { return $null }
        $snapshot
    } catch { $null }
    finally { if ($pipe) { $pipe.Dispose() } }
}
