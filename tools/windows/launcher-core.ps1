# 官方 Gufo 命令行启动器的扫描、参数和设置逻辑。兼容 Windows PowerShell 5.1。
# 交互方式参考 pixmaate/gufo 2eb0778；许可与来源见 START_WINDOWS.md。
Set-StrictMode -Version 2.0

function New-GufoOptions {
    @{
        Context = 32768; Port = 8080; Host = '127.0.0.1'; Sessions = 1
        Speculative = 'off'; DraftPath = ''; DraftTokens = 7; MinDraftTokens = 1
        Think = 'auto'; CacheRamBytes = '0'; CacheDisk = ''
        CacheDiskBytes = '8589934592'; LogProgress = $true; DraftPolicy = 'adaptive'
        MaxTokens = '-1'; EnableYarn = $false; VisionPath = ''
    }
}

function Resolve-GufoPath([string]$Path) {
    $value = $Path.Trim().Trim('"')
    if (-not $value) { throw '路径为空。' }
    (Get-Item -LiteralPath $value -ErrorAction Stop).FullName
}

function Get-GufoFileInfo([string]$Path) {
    # 只读取文件头四字节；不加载权重，也不要求首片含有张量。
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $magic = New-Object byte[] 4
        $read = $stream.Read($magic, 0, 4)
        [pscustomobject]@{
            Bytes = [int64]$stream.Length
            Valid = ($read -eq 4 -and [Text.Encoding]::ASCII.GetString($magic) -eq 'GGUF' -and $stream.Length -ge 24)
        }
    } catch {
        [pscustomobject]@{ Bytes = [int64]0; Valid = $false }
    } finally { if ($stream) { $stream.Dispose() } }
}

function Get-GufoFileKind([string]$Name) {
    if ($Name -match '(?i)(imatrix|calibration)') { return 'ignore' }
    if ($Name -match '(?i)mmproj') { return 'vision' }
    if ($Name -match '(?i)dflash') { return 'dflash' }
    if ($Name -match '(?i)dspark') { return 'dspark' }
    if ($Name -match '(?i)(^|[-_.])mtp([-_.]|$)') { return 'mtp' }
    'target'
}

function Get-GufoModelRecord([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($full)
    $leaf = [IO.Path]::GetFileName($full)
    $split = [regex]::Match($leaf, '(?i)^(.*)-(\d{5})-of-(\d{5})\.gguf$')
    $count = 1
    $name = [IO.Path]::GetFileNameWithoutExtension($leaf)
    if ($split.Success) {
        $count = [int]$split.Groups[3].Value
        if ($count -lt 1 -or $count -gt 1024) { throw "分片数量异常：$leaf" }
        $name = $split.Groups[1].Value
        $leaf = '{0}-{1:D5}-of-{2:D5}.gguf' -f $name, 1, $count
        $full = Join-Path $directory $leaf
    }
    $missing = New-Object 'Collections.Generic.List[int]'
    $issues = New-Object 'Collections.Generic.List[string]'
    $bytes = [int64]0
    for ($n = 1; $n -le $count; $n++) {
        $part = $full
        if ($split.Success) { $part = Join-Path $directory ('{0}-{1:D5}-of-{2:D5}.gguf' -f $name, $n, $count) }
        if (-not (Test-Path -LiteralPath $part -PathType Leaf)) {
            $missing.Add($n)
            continue
        }
        $info = Get-GufoFileInfo $part
        $bytes += $info.Bytes
        if (-not $info.Valid) { $issues.Add("文件无法读取或 GGUF 文件头不完整：$([IO.Path]::GetFileName($part))") }
    }
    [pscustomobject]@{
        Path = $full; Name = $name; Bytes = $bytes; Shards = $count
        MissingShards = @($missing.ToArray()); Issues = @($issues.ToArray())
        Complete = ($missing.Count -eq 0 -and $issues.Count -eq 0)
        Kind = (Get-GufoFileKind $leaf)
    }
}

function Get-GufoInventory([string[]]$Roots, [int]$MaxDepth = 4) {
    $models = New-Object 'Collections.Generic.List[object]'
    $mtp = New-Object 'Collections.Generic.List[object]'
    $dflash = New-Object 'Collections.Generic.List[object]'
    $dspark = New-Object 'Collections.Generic.List[object]'
    $vision = New-Object 'Collections.Generic.List[object]'
    $warnings = New-Object 'Collections.Generic.List[string]'
    $seenDirs = @{}; $seenFiles = @{}; $seenModels = @{}
    $pending = New-Object 'Collections.Generic.Queue[object]'
    foreach ($root in $Roots) {
        if ($root -and (Test-Path -LiteralPath $root -PathType Container)) {
            $pending.Enqueue(@{ Path = (Resolve-GufoPath $root); Depth = 0 })
        }
    }
    $fileCount = 0
    while ($pending.Count -gt 0) {
        $entry = $pending.Dequeue()
        if ($seenDirs.ContainsKey($entry.Path)) { continue }
        $seenDirs[$entry.Path] = $true
        if ($seenDirs.Count -gt 4096) { $warnings.Add('目录数量达到扫描上限，请选择更具体的模型目录。'); break }
        foreach ($file in (Get-ChildItem -LiteralPath $entry.Path -File -Filter '*.gguf' -ErrorAction SilentlyContinue)) {
            if ($seenFiles.ContainsKey($file.FullName)) { continue }
            $seenFiles[$file.FullName] = $true
            $fileCount++
            if ($fileCount -gt 8192) { throw 'GGUF 文件过多，请缩小模型目录范围。' }
            if ((Get-GufoFileKind $file.Name) -eq 'ignore') { continue }
            try { $record = Get-GufoModelRecord $file.FullName }
            catch { $warnings.Add($_.Exception.Message); continue }
            if ($seenModels.ContainsKey($record.Path)) { continue }
            $seenModels[$record.Path] = $true
            switch ($record.Kind) {
                'target' { $models.Add($record) }
                'mtp' { $mtp.Add($record) }
                'dflash' { $dflash.Add($record) }
                'dspark' { $dspark.Add($record) }
                'vision' { $vision.Add($record) }
            }
        }
        if ($entry.Depth -lt $MaxDepth) {
            foreach ($child in (Get-ChildItem -LiteralPath $entry.Path -Directory -ErrorAction SilentlyContinue)) {
                # 不跟随目录联接，避免扫描环和意外遍历其他磁盘。
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                    $pending.Enqueue(@{ Path = $child.FullName; Depth = ($entry.Depth + 1) })
                }
            }
        }
    }
    [pscustomobject]@{
        Models = @($models.ToArray() | Sort-Object Name, Path)
        Mtp = @($mtp.ToArray()); DFlash = @($dflash.ToArray())
        DSpark = @($dspark.ToArray()); Vision = @($vision.ToArray())
        Warnings = @($warnings.ToArray())
    }
}

function Get-GufoUnsigned([object]$Value, [string]$Name, [uint64]$Minimum = 0, [uint64]$Maximum = [uint64]::MaxValue) {
    $number = [uint64]0
    if (-not [uint64]::TryParse([string]$Value, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
            $number -lt $Minimum -or $number -gt $Maximum) { throw "$Name 数值无效：$Value" }
    $number.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function New-GufoArguments($Model, [hashtable]$Options, [string]$ApiKey = '') {
    if (-not $Model.Complete -or $Model.Kind -ne 'target') { throw '主模型分片不完整，或选中了辅助文件。' }
    $port = Get-GufoUnsigned $Options.Port 'port' 1 65535
    $sessions = Get-GufoUnsigned $Options.Sessions 'sessions' 1 2147483647
    $context = Get-GufoUnsigned $Options.Context 'context' 0 4294967295
    $draft = Get-GufoUnsigned $Options.DraftTokens 'draft-tokens' 1 4294967295
    $floor = Get-GufoUnsigned $Options.MinDraftTokens 'min-draft-tokens' 1 4294967295
    if ([uint64]$floor -gt [uint64]$draft) { throw '最小草稿数不能大于最大草稿数。' }
    if (@('off', 'mtp', 'dflash2', 'dspark') -notcontains $Options.Speculative) { throw '投机模式无效。' }
    if (@('auto', 'on', 'off') -notcontains $Options.Think) { throw '思考模式无效。' }
    if (@('fixed', 'adaptive') -notcontains $Options.DraftPolicy) { throw 'DFlash2 草稿策略无效。' }
    if ([string]$Options.Host -notin @('127.0.0.1', '0.0.0.0')) { throw '监听地址应为 127.0.0.1 或 0.0.0.0。' }
    $maxTokens = [string]$Options.MaxTokens
    if ($maxTokens -ne '-1') { $maxTokens = Get-GufoUnsigned $maxTokens 'max-tokens' 1 4294967295 }
    $ram = Get-GufoUnsigned $Options.CacheRamBytes 'cache-ram-bytes'
    $argsList = New-Object 'Collections.Generic.List[string]'
    foreach ($value in @('serve', 'llm', '--model', $Model.Path, '--host', [string]$Options.Host,
        '--port', $port, '--sessions', $sessions, '--context', $context,
        '--max-tokens', $maxTokens, '--cache-ram-bytes', $ram, '--think', [string]$Options.Think,
        '--speculative', [string]$Options.Speculative)) { $argsList.Add([string]$value) }
    if ($Options.EnableYarn) { $argsList.Add('--enable-yarn') }
    if ($Options.Speculative -ne 'off') {
        if (-not $Options.DraftPath) { throw '请先选择独立草稿文件。' }
        $draftInfo = Get-GufoFileInfo ([string]$Options.DraftPath)
        if (-not $draftInfo.Valid) { throw '草稿文件缺失或 GGUF 文件头不完整。' }
        $flag = @{ mtp = '--mtp-model'; dflash2 = '--dflash-model'; dspark = '--dspark-model' }[$Options.Speculative]
        foreach ($value in @($flag, [string]$Options.DraftPath, '--draft-tokens', $draft, '--min-draft-tokens', $floor)) { $argsList.Add($value) }
        if ($Options.Speculative -eq 'dflash2') { $argsList.Add('--draft-policy'); $argsList.Add([string]$Options.DraftPolicy) }
    }
    if ($Options.CacheDisk) {
        if (-not (Test-Path -LiteralPath $Options.CacheDisk -PathType Container)) { throw '磁盘缓存目录不存在，请选择已有目录。' }
        $argsList.Add('--cache-disk'); $argsList.Add([string]$Options.CacheDisk)
        $argsList.Add('--cache-disk-bytes'); $argsList.Add((Get-GufoUnsigned $Options.CacheDiskBytes 'cache-disk-bytes' 1))
    }
    if ($Options.VisionPath) {
        if (-not (Get-GufoFileInfo ([string]$Options.VisionPath)).Valid) { throw '视觉 sidecar 文件不可读。' }
        $argsList.Add('--mmproj'); $argsList.Add([string]$Options.VisionPath)
    }
    if ($Options.LogProgress) { $argsList.Add('--log-level'); $argsList.Add('info'); $argsList.Add('--log-progress') }
    if ($ApiKey) { $argsList.Add('--api-key'); $argsList.Add($ApiKey) }
    $argsList.ToArray()
}

function Assert-GufoArguments([string[]]$Arguments, [string]$HelpText) {
    if (-not $HelpText -or $HelpText -notmatch 'serve\s+llm') { throw '未取得有效的官方 serve llm help。' }
    $supported = @{}
    foreach ($match in [regex]::Matches($HelpText, '(?m)^\s*(?:-[A-Za-z],\s*)?(--[a-z][a-z0-9-]*)(?:\s|$)')) {
        $supported[$match.Groups[1].Value] = $true
    }
    # 只检查选项位置，参数值以 -- 开头时也按字面值处理。
    $flags = @('--enable-yarn', '--log-progress')
    for ($i = 2; $i -lt $Arguments.Count; $i++) {
        $option = $Arguments[$i]
        if (-not $supported.ContainsKey($option)) { throw "当前 gufo.exe 的实际 help 不支持：$option" }
        if ($flags -notcontains $option) {
            $i++
            if ($i -ge $Arguments.Count) { throw "选项缺少值：$option" }
        }
    }
}

function ConvertTo-GufoArgumentString([string[]]$Arguments) {
    # Windows CRT 引用规则；直接传给 EXE，不经 cmd /c 或 Invoke-Expression。
    $quoted = foreach ($argument in $Arguments) {
        $builder = New-Object Text.StringBuilder
        [void]$builder.Append('"')
        $slashes = 0
        foreach ($character in ([string]$argument).ToCharArray()) {
            if ($character -eq '\') { $slashes++; continue }
            if ($character -eq '"') {
                [void]$builder.Append(('\' * ($slashes * 2 + 1)))
                [void]$builder.Append('"')
            } else {
                [void]$builder.Append(('\' * $slashes))
                [void]$builder.Append($character)
            }
            $slashes = 0
        }
        [void]$builder.Append(('\' * ($slashes * 2)))
        [void]$builder.Append('"')
        $builder.ToString()
    }
    $quoted -join ' '
}

function Format-GufoCommand([string]$ExePath, [string[]]$Arguments) {
    $display = @($Arguments)
    for ($i = 0; $i -lt $display.Count - 1; $i++) {
        if ($display[$i] -eq '--api-key') { $display[$i + 1] = '<本次输入的 API Key>' }
    }
    ConvertTo-GufoArgumentString (@($ExePath) + $display)
}

function Read-GufoSettings([string]$Path) {
    $state = @{ SchemaVersion = 1; ModelPath = ''; Roots = @(); Options = (New-GufoOptions) }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $state }
    try {
        $file = Get-Item -LiteralPath $Path
        if ($file.Length -gt 65536) { throw '设置文件超过 64 KiB。' }
        $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.SchemaVersion -ne 1) { throw '设置版本不支持。' }
        if ($saved.ModelPath -is [string]) { $state.ModelPath = $saved.ModelPath }
        $state.Roots = @($saved.Roots | Where-Object { $_ -is [string] })
        foreach ($key in @($state.Options.Keys)) {
            $property = $saved.Options.PSObject.Properties[$key]
            if ($null -ne $property) { $state.Options[$key] = $property.Value }
        }
    } catch { Write-Warning ("无法完整读取上次设置，将使用可恢复的默认值：{0}" -f $_.Exception.Message) }
    $state
}

function Save-GufoSettings([string]$Path, $Model, [hashtable]$Options, [string[]]$Roots) {
    $safe = New-GufoOptions
    foreach ($key in @($safe.Keys)) { if ($Options.ContainsKey($key)) { $safe[$key] = $Options[$key] } }
    $state = @{ SchemaVersion = 1; ModelPath = $Model.Path; Roots = @($Roots); Options = $safe }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    $temporary = Join-Path $parent ([IO.Path]::GetRandomFileName())
    try {
        $json = $state | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($true)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, [IO.Path]::GetFullPath($Path), $null) }
        else { [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path)) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Invoke-GufoCapture([string]$ExePath, [string[]]$Arguments, [int]$TimeoutMs = 15000) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $ExePath
    $info.Arguments = ConvertTo-GufoArgumentString $Arguments
    $info.WorkingDirectory = [IO.Path]::GetDirectoryName($ExePath)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            $process.Kill(); [void]$process.WaitForExit(2000)
            throw 'Gufo 帮助/版本探测超时。请用 start.cmd -Foreground 排查。'
        }
        $text = $stdout.Result + $stderr.Result
        if ($process.ExitCode -ne 0) { throw "Gufo 探测退出码 $($process.ExitCode)：$text" }
        if ($text.Length -gt 262144) { throw '帮助输出超过合理大小。' }
        $text
    } finally { $process.Dispose() }
}

function Assert-GufoPort([string]$ListenHost, [int]$Port) {
    $listener = $null
    try {
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse($ListenHost), $Port)
        $listener.Start()
    } catch { throw "端口 $Port 无法监听或已被占用，请在设置中换端口；启动器不会停止其他进程。" }
    finally { if ($listener) { $listener.Stop() } }
}
