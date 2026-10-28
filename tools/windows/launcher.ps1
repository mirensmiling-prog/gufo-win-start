# 官方 Gufo 的轻量命令行入口。设置不保存 API Key；默认启动后菜单退出。
param(
    [switch]$Last,
    [switch]$DryRun,
    [switch]$Foreground,
    [string]$Models = '',
    [string]$Bin = '',
    [string]$Config = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'launcher-core.ps1')
$launcherRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Get-GufoConsoleWidth {
    $widths = New-Object 'Collections.Generic.List[int]'
    try { if ($Host.UI.RawUI.WindowSize.Width -gt 0) { $widths.Add([int]$Host.UI.RawUI.WindowSize.Width) } } catch { }
    try { if ([Console]::WindowWidth -gt 0) { $widths.Add([Console]::WindowWidth) } } catch { }
    if ($widths.Count -gt 0) { return [Math]::Max(4, (($widths | Measure-Object -Minimum).Minimum - 2)) }
    78
}

function Get-GufoCellWidth([string]$Text) {
    # 统一按文本元素计算。某些中文宿主对整串、单字和装饰符的计宽不同，不能混用。
    $width = 0
    $elements = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($elements.MoveNext()) {
        $element = [string]$elements.Current
        $point = [char]::ConvertToUtf32($element, 0)
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($element, 0)
        if ($category -in @([Globalization.UnicodeCategory]::NonSpacingMark, [Globalization.UnicodeCategory]::EnclosingMark, [Globalization.UnicodeCategory]::Format)) { continue }
        if (($point -ge 0x1100 -and $point -le 0x115f) -or
            ($point -ge 0x2e80 -and $point -le 0xa4cf) -or
            ($point -ge 0xac00 -and $point -le 0xd7a3) -or
            ($point -ge 0xf900 -and $point -le 0xfaff) -or
            ($point -ge 0xfe10 -and $point -le 0xfe6f) -or
            ($point -ge 0xff01 -and $point -le 0xff60) -or
            ($point -ge 0xffe0 -and $point -le 0xffe6) -or $point -ge 0x1f300) { $width += 2 }
        else { $width++ }
    }
    $width
}

function Split-GufoConsoleLine([string]$Text, [int]$Width, [string]$Prefix = '', [string]$ContinuationPrefix = '  ') {
    if ($Width -lt 4) { throw '终端换行宽度至少为 4 列。' }
    if ((Get-GufoCellWidth $Prefix) -gt ($Width - 2) -or
        (Get-GufoCellWidth $ContinuationPrefix) -gt ($Width - 2)) { throw '行前缀超过可用终端宽度。' }
    foreach ($paragraph in ($Text -split "`r`n|`n|`r")) {
        $line = New-Object Text.StringBuilder
        [void]$line.Append($Prefix)
        $linePrefix = $Prefix
        $columns = Get-GufoCellWidth $Prefix
        $hasContent = $false
        $isPath = $paragraph -match '(?i)(?:^|\s)(?:[a-z]:[\\/]|\\\\|/)'
        $elements = [Globalization.StringInfo]::GetTextElementEnumerator($paragraph)
        while ($elements.MoveNext()) {
            $element = [string]$elements.Current
            $cells = Get-GufoCellWidth $element
            if ($hasContent -and ($columns + $cells) -gt $Width) {
                $content = $line.ToString()
                $carry = ''
                # 优先在路径分隔符之后换行，让可完整容纳的文件名保持在同一行。
                $breakAt = [Math]::Max($content.LastIndexOf('\'), $content.LastIndexOf('/'))
                if ($isPath -and $breakAt -ge $linePrefix.Length) {
                    $tail = $content.Substring($breakAt + 1)
                    if (((Get-GufoCellWidth ($ContinuationPrefix + $tail)) + $cells) -le $Width) {
                        $carry = $tail
                        $content = $content.Substring(0, $breakAt + 1)
                    }
                }
                $content
                [void]$line.Clear()
                [void]$line.Append($ContinuationPrefix)
                [void]$line.Append($carry)
                $linePrefix = $ContinuationPrefix
                $columns = Get-GufoCellWidth $line.ToString()
                $hasContent = ($carry.Length -gt 0)
            }
            [void]$line.Append($element)
            $columns += $cells
            $hasContent = $true
        }
        $line.ToString()
    }
}

function Write-GufoMenuLine([string]$Text, [ConsoleColor]$Color = 'White', [string]$Prefix = '') {
    foreach ($line in (Split-GufoConsoleLine -Text $Text -Width (Get-GufoConsoleWidth) -Prefix $Prefix)) {
        Write-Host $line -ForegroundColor $Color
    }
}

function Clear-GufoMenu {
    try { if (-not [Console]::IsOutputRedirected) { Clear-Host } } catch { }
}

function Read-GufoMenuKey {
    # 真实终端单键响应；管道、重定向或不支持 ReadKey 的宿主使用逐行输入。
    $interactive = $false
    try { $interactive = -not [Console]::IsInputRedirected } catch { }
    if ($interactive) {
        try {
            while ($true) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Enter) { return '' }
                if ($key.Key -eq [ConsoleKey]::Escape) { return 'B' }
                if ($key.KeyChar -ne [char]0) { return ([string]$key.KeyChar).ToUpperInvariant() }
            }
        } catch { }
    }
    (Read-Host '输入选项后按 Enter').Trim().ToUpperInvariant()
}

function Get-GufoNextContext([uint64]$Current) {
    $presets = @([uint64]32768, [uint64]65536, [uint64]131072, [uint64]262144, [uint64]0)
    $index = [array]::IndexOf($presets, $Current)
    if ($index -ge 0) { return $presets[($index + 1) % $presets.Count] }
    foreach ($preset in $presets) { if ($preset -gt $Current) { return $preset } }
    [uint64]0
}

function Get-GufoContextLabel([uint64]$Current) {
    if ($Current -eq 0) { return '原生（0，跟随模型）' }
    if (@(32768, 65536, 131072, 262144) -contains $Current) { return ('{0}K（{1} token）' -f ($Current / 1024), $Current) }
    '自定义（{0} token）' -f $Current
}

function Wait-GufoMenu {
    Write-GufoMenuLine '按任意键返回菜单。' 'DarkGray'
    [void](Read-GufoMenuKey)
}

function Read-GufoSecret {
    $secure = Read-Host 'API Key（可留空，直接 Enter 不启用鉴权；不保存、不回显）' -AsSecureString
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        $secure.Dispose()
    }
}

function Get-GufoDraftCandidates($Model, $Inventory, [string]$Mode) {
    $candidates = switch ($Mode) {
        'mtp' { @($Inventory.Mtp) }
        'dflash2' { @($Inventory.DFlash) }
        'dspark' { @($Inventory.DSpark) }
        default { @() }
    }
    $directory = [IO.Path]::GetDirectoryName($Model.Path)
    @($candidates | Where-Object { $_.Complete } | Sort-Object -Property @{
        Expression = {
            $score = 0
            if ([IO.Path]::GetDirectoryName($_.Path) -eq $directory) { $score += 100 }
            if ([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($_.Path)) -eq [IO.Path]::GetDirectoryName($directory)) { $score += 50 }
            if ($_.Name -match '(?i)shared') { $score += 10 }
            if ($_.Name -match '(?i)Q8_0') { $score += 5 }
            $score
        }; Descending = $true
    }, Path)
}

function Set-GufoAutomaticDraft($Model, [hashtable]$Options, $Inventory) {
    # 仅按可见文件名定位辅助文件；实际支持与匹配仍由官方引擎检查。
    $mode = ''
    if ($Model.Name -match '(?i)qwen3[._-]?8.*flash[-_. ]?next') { $mode = 'mtp' }
    elseif ($Model.Name -match '(?i)qwen3[._-]?8.*27b') { $mode = 'dflash2' }
    elseif ($Model.Name -match '(?i)deepseek.*v4.*flash') { $mode = 'dspark' }
    if (-not $mode) { return }
    $candidates = @(Get-GufoDraftCandidates $Model $Inventory $mode)
    if ($mode -eq 'mtp') { $candidates = @($candidates | Where-Object { $_.Name -match '(?i)qwen3[._-]?8.*flash[-_. ]?next.*shared' }) }
    if ($mode -eq 'dflash2') { $candidates = @($candidates | Where-Object { $_.Name -match '(?i)qwen3[._-]?8.*27b' }) }
    if ($candidates.Count -eq 1) {
        $Options.Speculative = $mode; $Options.DraftPath = $candidates[0].Path
    }
}

function Select-GufoDraft($Model, [hashtable]$Options, $Inventory) {
    Clear-GufoMenu
    Write-GufoMenuLine '选择加速模式' 'Cyan'
    Write-GufoMenuLine '0  关闭投机'
    Write-GufoMenuLine '1  MTP'
    Write-GufoMenuLine '2  DFlash2'
    Write-GufoMenuLine '3  DSpark'
    $choice = Read-GufoMenuKey
    $modes = @{ '0' = 'off'; '1' = 'mtp'; '2' = 'dflash2'; '3' = 'dspark' }
    if (-not $modes.ContainsKey($choice)) { throw '请选择 0、1、2 或 3。' }
    $mode = $modes[$choice]
    if ($mode -eq 'off') { $Options.Speculative = 'off'; return }
    $candidates = @(Get-GufoDraftCandidates $Model $Inventory $mode)
    for ($i = 0; $i -lt $candidates.Count; $i++) { Write-GufoMenuLine ('{0}  {1}' -f ($i + 1), $candidates[$i].Path) }
    $selection = Read-Host '输入文件编号，或直接粘贴草稿文件完整路径'
    $index = 0
    if ([int]::TryParse($selection, [ref]$index) -and $index -ge 1 -and $index -le $candidates.Count) {
        $path = $candidates[$index - 1].Path
    } else { $path = Resolve-GufoPath $selection }
    $record = Get-GufoModelRecord $path
    if (-not $record.Complete) { throw '草稿文件缺失或不完整。' }
    if ($mode -eq 'mtp' -and [IO.Path]::GetFileName($path) -notmatch '(?i)mtp.*shared.*\.gguf$') {
        Write-Host '提示：Flash-Next 的官方 help 要求 mtp-...-shared-*.gguf；请核对所选文件。' -ForegroundColor Yellow
        Wait-GufoMenu
    }
    $Options.Speculative = $mode; $Options.DraftPath = $record.Path
}

function Start-GufoSelection($Model, [hashtable]$Options) {
    # 上次启动和菜单启动均重新检查文件、实际 help 和端口，不回放历史 argv。
    $fresh = Get-GufoModelRecord $Model.Path
    $key = ''
    try {
        if ($Options.Host -eq '0.0.0.0' -and -not $DryRun) { $key = Read-GufoSecret }
        $arguments = @(New-GufoArguments -Model $fresh -Options $Options -ApiKey $key)
        Assert-GufoArguments -Arguments $arguments -HelpText $script:llmHelp
        Write-Host ''
        Write-Host (Format-GufoCommand -ExePath $script:exe -Arguments $arguments) -ForegroundColor Cyan
        if ($DryRun) {
            Write-Host 'DryRun：仅检查和预览，未启动服务、未写设置。'
            Write-Host ('轻量监控：{0}（本次不加载、不运行）' -f $(if ($Options.Monitor) { '开启' } else { '关闭' }))
            if ($Options.Host -eq '0.0.0.0') { Write-Host 'API Key 将在实际启动时询问，可留空；本次预览未包含 Key。' }
            return $true
        }
        Assert-GufoPort -ListenHost $Options.Host -Port ([int]$Options.Port)
        $running = @(Get-Process -Name 'gufo' -ErrorAction SilentlyContinue)
        if ($running.Count -gt 0) {
            Write-Host ('检测到已有 Gufo（PID {0}），再次加载可能争用统一内存。' -f ($running.Id -join ', ')) -ForegroundColor Yellow
            if ((Read-Host '仍需并行启动请输入 YES；其他输入返回') -cne 'YES') { return $false }
        }
        $address = if ($Options.Host -eq '0.0.0.0') { '<本机局域网 IP>' } else { '127.0.0.1' }
        Write-Host ("API 地址：http://{0}:{1}/v1" -f $address, $Options.Port) -ForegroundColor Green
        Write-Host ('API 鉴权：{0}' -f $(if ($key) { '已启用 Bearer Key' } else { '未启用（API Key 留空）' }))
        Write-Host '进程启动后仍需加载模型，以 Gufo 窗口中的就绪信息为准；Ctrl+C 停止服务。'
        if ($Foreground) {
            if ($Options.Monitor) { Write-Warning '前台排障保留 Gufo 原始输出，本次不显示监控；菜单中的监控设置仍保留。' }
            # 前台模式用于排障；不捕获或改写 Gufo 的原始实时输出。
            Push-Location ([IO.Path]::GetDirectoryName($script:exe))
            try {
                $process = Start-Process -FilePath $script:exe -ArgumentList (ConvertTo-GufoArgumentString $arguments) -WorkingDirectory ([IO.Path]::GetDirectoryName($script:exe)) -NoNewWindow -PassThru
                try {
                    try { Save-GufoSettings -Path $script:configPath -Model $fresh -Options $Options -Roots $script:roots }
                    catch { Write-Warning ("无法保存设置：{0}" -f $_.Exception.Message) }
                    $process.WaitForExit(); $script:engineExitCode = $process.ExitCode
                }
                finally { $process.Dispose() }
            } finally { Pop-Location }
        } else {
            $monitored = $null
            if ($Options.Monitor) {
                . (Join-Path $PSScriptRoot 'launcher-host.ps1')
                $monitored = Start-GufoMonitoredEngine -ExePath $script:exe -Arguments $arguments
                $process = $monitored.Process
            } else {
                $process = Start-Process -FilePath $script:exe -ArgumentList (ConvertTo-GufoArgumentString $arguments) -WorkingDirectory ([IO.Path]::GetDirectoryName($script:exe)) -PassThru
            }
            try {
                if ($process.WaitForExit(1200)) { throw "Gufo 在启动阶段退出（code=$($process.ExitCode)），请用 start.cmd -Foreground 查看原始错误。" }
                try { Save-GufoSettings -Path $script:configPath -Model $fresh -Options $Options -Roots $script:roots }
                catch { Write-Warning ("服务已启动，但无法保存下次启动设置：{0}" -f $_.Exception.Message) }
                if ($Options.Monitor) {
                    Write-Host '已启动独立 Gufo 窗口；正在连接实际引擎 PID，模型就绪状态以服务窗口为准。' -ForegroundColor Green
                    $arguments = $null
                    try {
                        # 关闭时不读取或编译监控模块，不增加常驻进程。
                        . (Join-Path $PSScriptRoot 'launcher-monitor.ps1')
                        Start-GufoMonitor -Process $process -Caption $Model.Name -Port ([int]$Options.Port) -ApiKey $key -StatsPipeName $monitored.PipeName
                    } catch {
                        Write-Warning ("监控未能继续；Gufo 独立服务不受影响：{0}" -f $_.Exception.Message)
                        if (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) { Wait-GufoMenu }
                    }
                } else {
                    Write-Host ("已启动 Gufo，PID {0}。菜单现在退出，服务继续在独立窗口运行。" -f $process.Id) -ForegroundColor Green
                }
            } finally { $process.Dispose() }
        }
        return $true
    } finally { $key = ''; $arguments = $null }
}

function Show-GufoFeatures($Model, [hashtable]$Options) {
    Clear-GufoMenu
    $specLabel = @{ off = '关闭'; mtp = 'MTP'; dflash2 = 'DFlash2'; dspark = 'DSpark' }[$Options.Speculative]
    $thinkLabel = @{ auto = '跟随引擎'; on = '开启'; off = '关闭' }[$Options.Think]
    $ramLabel = if ([string]$Options.CacheRamBytes -eq '0') { '自动' } else { '{0:0.##} GiB' -f ([decimal]$Options.CacheRamBytes / 1073741824) }
    $tokenLabel = if ([string]$Options.MaxTokens -eq '-1') { '不限（直到 EOS 或上下文满）' } else { '{0} token' -f $Options.MaxTokens }
    Write-Host ''
    Write-GufoMenuLine ('模型：{0}' -f $Model.Name) 'Cyan'
    Write-GufoMenuLine ('分片：{0}/{0}' -f $Model.Shards) 'DarkGray'
    Write-GufoMenuLine '模型文件：' 'DarkGray'
    Write-GufoMenuLine $Model.Path 'DarkGray' '  '
    if ($Options.Speculative -ne 'off' -and $Options.DraftPath) {
        Write-GufoMenuLine '草稿文件：' 'DarkGray'
        Write-GufoMenuLine $Options.DraftPath 'DarkGray' '  '
    }
    Write-Host ''
    Write-GufoMenuLine ('1  加速模式：{0}' -f $specLabel)
    Write-GufoMenuLine ('2  草稿上限：{0}' -f $Options.DraftTokens)
    Write-GufoMenuLine ('3  思考模式：{0}（按键循环切换）' -f $thinkLabel)
    Write-GufoMenuLine ('4  服务端口：{0}' -f $Options.Port)
    Write-GufoMenuLine ('5  预分配会话：{0}' -f $Options.Sessions)
    Write-GufoMenuLine ('6  RAM 快照预算：{0}' -f $ramLabel)
    Write-GufoMenuLine ('7  上下文长度：{0}' -f (Get-GufoContextLabel ([uint64]$Options.Context))) 'Cyan'
    Write-GufoMenuLine '   按 7 循环：32K -> 64K -> 128K -> 256K -> 原生' 'DarkGray'
    Write-GufoMenuLine ('8  监听地址：{0}' -f $Options.Host)
    Write-GufoMenuLine ('9  实时进度：{0}' -f $(if ($Options.LogProgress) { '开启' } else { '关闭' }))
    Write-GufoMenuLine ('M  轻量监控：{0}（推理 / 内存 / 磁盘）' -f $(if ($Options.Monitor) { '开启' } else { '关闭' }))
    Write-GufoMenuLine ('F  草稿下限：{0}' -f $Options.MinDraftTokens)
    Write-GufoMenuLine ('C  磁盘缓存：{0}' -f $(if ($Options.CacheDisk) { '已设置（按 C 更改）' } else { '未启用' }))
    if ($Options.CacheDisk) { Write-GufoMenuLine $Options.CacheDisk 'DarkGray' '  ' }
    Write-GufoMenuLine ('V  视觉 sidecar：{0}' -f $(if ($Options.VisionPath) { '已指定（按 V 更改）' } else { '引擎自动发现' }))
    if ($Options.VisionPath) { Write-GufoMenuLine $Options.VisionPath 'DarkGray' '  ' }
    Write-GufoMenuLine ('T  生成 token 上限：{0}' -f $tokenLabel)
    Write-GufoMenuLine ('Y  YaRN：{0}' -f $(if ($Options.EnableYarn) { '开启' } else { '关闭' }))
    if ($Options.Speculative -eq 'dflash2') { Write-GufoMenuLine ('P  DFlash2 草稿策略：{0}' -f $Options.DraftPolicy) }
    Write-GufoMenuLine 'X  自定义上下文长度'
    Write-Host ''
    Write-GufoMenuLine 'Enter  启动服务' 'Green'
    Write-GufoMenuLine 'D      预览命令' 'DarkGray'
    Write-GufoMenuLine 'H      查看实际 help' 'DarkGray'
    Write-GufoMenuLine 'B/Esc  返回模型列表' 'DarkGray'
    Write-GufoMenuLine 'Q      退出启动器' 'DarkGray'
}

function Edit-GufoFeatures($Model, [hashtable]$Options, $Inventory) {
    while ($true) {
        Show-GufoFeatures $Model $Options
        $choice = Read-GufoMenuKey
        try {
            switch ($choice) {
                '' { if (Start-GufoSelection $Model $Options) { return $true } }
                '1' { Select-GufoDraft $Model $Options $Inventory }
                '2' { $Options.DraftTokens = Get-GufoUnsigned (Read-Host '最大草稿数（官方默认 7；具体模型范围由引擎检查）') 'draft-tokens' 1 4294967295 }
                '3' { $modes = @('auto', 'on', 'off'); $Options.Think = $modes[([array]::IndexOf($modes, [string]$Options.Think) + 1) % $modes.Count] }
                '4' { $Options.Port = Get-GufoUnsigned (Read-Host '端口 1-65535') 'port' 1 65535 }
                '5' { $Options.Sessions = Get-GufoUnsigned (Read-Host '预分配会话数（建议先用 1）') 'sessions' 1 2147483647 }
                '6' {
                    $value = (Read-Host 'RAM 快照预算 GiB（0=自动；支持小数）').Trim()
                    $number = [decimal]0
                    if (-not [decimal]::TryParse($value, [Globalization.NumberStyles]::AllowDecimalPoint, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or $number -lt 0 -or $number -gt 1048576) { throw '预算数值无效。' }
                    $Options.CacheRamBytes = ([uint64]($number * 1073741824)).ToString([Globalization.CultureInfo]::InvariantCulture)
                }
                '7' { $Options.Context = Get-GufoNextContext ([uint64]$Options.Context) }
                '8' { $Options.Host = if ($Options.Host -eq '127.0.0.1') { '0.0.0.0' } else { '127.0.0.1' } }
                '9' { $Options.LogProgress = -not [bool]$Options.LogProgress }
                'M' { $Options.Monitor = -not [bool]$Options.Monitor }
                'F' { $Options.MinDraftTokens = Get-GufoUnsigned (Read-Host '最小草稿数（官方默认 1）') 'min-draft-tokens' 1 4294967295 }
                'C' {
                    $path = (Read-Host '已有磁盘缓存目录（留空关闭）').Trim().Trim('"')
                    if ($path) { $path = Resolve-GufoPath $path; if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw '请选择目录。' } }
                    $Options.CacheDisk = $path
                }
                'V' {
                    $path = (Read-Host '视觉 sidecar 完整路径（留空使用引擎自动发现）').Trim().Trim('"')
                    if ($path) { $path = Resolve-GufoPath $path; if (-not (Get-GufoFileInfo $path).Valid) { throw '请选择可读的 GGUF 文件。' } }
                    $Options.VisionPath = $path
                }
                'T' { $value = (Read-Host '生成 token 上限（-1=直到 EOS/上下文满）').Trim(); if ($value -ne '-1') { $value = Get-GufoUnsigned $value 'max-tokens' 1 4294967295 }; $Options.MaxTokens = $value }
                'Y' { $Options.EnableYarn = -not [bool]$Options.EnableYarn }
                'X' { $Options.Context = Get-GufoUnsigned (Read-Host '自定义上下文 token 数（0=原生）') 'context' 0 4294967295 }
                'P' { if ($Options.Speculative -eq 'dflash2') { $Options.DraftPolicy = if ($Options.DraftPolicy -eq 'adaptive') { 'fixed' } else { 'adaptive' } } }
                'D' {
                    $arguments = @(New-GufoArguments -Model $Model -Options $Options)
                    Assert-GufoArguments $arguments $script:llmHelp
                    Write-Host (Format-GufoCommand $script:exe $arguments) -ForegroundColor Cyan
                    if ($Options.Host -eq '0.0.0.0') { Write-GufoMenuLine 'API Key 在实际启动时可选输入；本次预览未包含 Key。' 'DarkGray' }
                    Wait-GufoMenu
                }
                'H' { Write-Host $script:llmHelp; Wait-GufoMenu }
                'B' { return $false }
                'Q' { exit 0 }
                default { Write-GufoMenuLine '选项无效，请按菜单中的快捷键。' 'Yellow'; Wait-GufoMenu }
            }
        } catch { Write-GufoMenuLine $_.Exception.Message 'Yellow'; Wait-GufoMenu }
    }
}

try {
    if ($env:OS -ne 'Windows_NT' -and -not $DryRun) { throw '实际启动请在 Windows 使用；其他平台仅支持 -DryRun。' }
    $script:exe = ''
    $candidates = @((Join-Path $launcherRoot 'gufo.exe'), (Join-Path $launcherRoot 'bin/gufo.exe'))
    if ($Bin) {
        if (Test-Path -LiteralPath $Bin -PathType Container) { $candidates = @((Join-Path $Bin 'gufo.exe')) }
        else { $candidates = @($Bin) }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $script:exe = Resolve-GufoPath $candidate; break }
    }
    if (-not $script:exe) { throw '未找到 gufo.exe，请把 start.cmd 和 tools 文件夹放在官方发行包内。' }
    $script:configPath = if ($Config) { [IO.Path]::GetFullPath($Config) } else { Join-Path $launcherRoot 'gufo-launcher.json' }
    $state = Read-GufoSettings $script:configPath
    $script:roots = @($state.Roots)
    if ($Models) {
        $directory = Resolve-GufoPath $Models
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw '-Models 需要目录路径。' }
        $script:roots = @($directory)
    }
    if ($script:roots.Count -eq 0) { $script:roots = @((Join-Path $launcherRoot 'models')) }
    Write-Host '读取所选 Gufo 的实际版本和 serve llm help…' -ForegroundColor DarkGray
    $version = (Invoke-GufoCapture $script:exe @('--version')).Trim()
    $script:llmHelp = Invoke-GufoCapture $script:exe @('serve', 'llm', '--help')
    Write-Host $version -ForegroundColor Cyan
    if ($Last) {
        if (-not $state.ModelPath) { throw '没有上次启动记录，请先运行 start.cmd 选择一次模型。' }
        $selected = Get-GufoModelRecord $state.ModelPath
        [void](Start-GufoSelection $selected $state.Options)
        if ($null -ne (Get-Variable engineExitCode -Scope Script -ErrorAction SilentlyContinue)) { exit $script:engineExitCode }
        exit 0
    }
    $refresh = $true
    while ($true) {
        if ($refresh) {
            Write-Host '扫描模型目录（最多 4 层）…' -ForegroundColor DarkGray
            $inventory = Get-GufoInventory -Roots $script:roots
            $refresh = $false
        }
        Clear-GufoMenu
        Write-Host ''
        Write-GufoMenuLine 'Gufo 官方版 · 选择模型' 'Cyan'
        Write-GufoMenuLine $version 'DarkGray'
        Write-GufoMenuLine '模型目录：' 'DarkGray'
        foreach ($root in $script:roots) { Write-GufoMenuLine $root 'DarkGray' '  ' }
        for ($i = 0; $i -lt $inventory.Models.Count; $i++) {
            $model = $inventory.Models[$i]
            $status = if ($model.Complete) { '{0}/{0} 分片' -f $model.Shards } else { '不可启动：缺片 {0}；{1}' -f ($model.MissingShards -join ','), ($model.Issues -join '; ') }
            $color = if ($model.Complete) { 'White' } else { 'Yellow' }
            Write-GufoMenuLine ('{0,3}  {1}' -f ($i + 1), $model.Name) $color
            Write-GufoMenuLine ('    {0:N2} GiB；{1}' -f ($model.Bytes / 1GB), $status) $color
        }
        if ($inventory.Models.Count -eq 0) { Write-Host '未找到主模型。可把 GGUF 放入 models，或按 D 粘贴模型目录。' -ForegroundColor Yellow }
        foreach ($warning in $inventory.Warnings) { Write-GufoMenuLine $warning 'Yellow' }
        if ($state.ModelPath) {
            Write-GufoMenuLine 'Enter  使用上次设置直接启动' 'Green'
            Write-GufoMenuLine ([IO.Path]::GetFileName($state.ModelPath)) 'DarkGray' '  '
        }
        Write-GufoMenuLine '输入模型编号并回车，进入设置' 'Green'
        Write-GufoMenuLine 'D  更换模型目录' 'DarkGray'
        Write-GufoMenuLine 'A  添加模型目录' 'DarkGray'
        Write-GufoMenuLine 'R  刷新模型列表' 'DarkGray'
        Write-GufoMenuLine 'L  使用上次设置启动' 'DarkGray'
        Write-GufoMenuLine 'H  查看实际 help' 'DarkGray'
        Write-GufoMenuLine 'G  运行诊断' 'DarkGray'
        Write-GufoMenuLine 'Q  退出启动器' 'DarkGray'
        $choice = (Read-Host '请选择').Trim()
        if (-not $choice -and $state.ModelPath) { $choice = 'L' }
        try {
            if ($choice -match '^[0-9]+$') {
                $index = 0
                if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $inventory.Models.Count) { throw '模型编号无效。' }
                $selected = $inventory.Models[$index - 1]
                if (-not $selected.Complete) { throw '请先补齐分片或修复无法读取的文件。' }
                $options = New-GufoOptions
                if ($state.ModelPath -eq $selected.Path) { $options = $state.Options }
                else { Set-GufoAutomaticDraft $selected $options $inventory }
                if (Edit-GufoFeatures $selected $options $inventory) { break }
                continue
            }
            switch ($choice.ToUpperInvariant()) {
                'D' { $directory = Resolve-GufoPath (Read-Host '粘贴模型目录完整路径'); if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw '请选择目录。' }; $script:roots = @($directory); $refresh = $true }
                'A' { $directory = Resolve-GufoPath (Read-Host '粘贴要添加的模型目录'); if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw '请选择目录。' }; $script:roots = @($script:roots + @($directory) | Select-Object -Unique); $refresh = $true }
                'R' { $refresh = $true }
                'L' { if (-not $state.ModelPath) { throw '没有上次启动记录。' }; if (Start-GufoSelection (Get-GufoModelRecord $state.ModelPath) $state.Options) { $script:leaveMenu = $true } }
                'H' {
                    $command = (Read-Host '命令（留空=顶层；如 prompt、chat、bench、serve llm）').Trim()
                    if (@('', 'serve', 'serve llm', 'prompt', 'chat', 'bench', 'eval', 'video', 'transcribe', 'diagnose') -notcontains $command) { throw '请从实际顶层 help 列出的命令中选择。' }
                    $helpArguments = @()
                    if ($command) { $helpArguments += @($command -split ' ') }
                    $helpArguments += '--help'
                    Write-Host (Invoke-GufoCapture $script:exe $helpArguments)
                    Wait-GufoMenu
                }
                'G' { Write-Host (Invoke-GufoCapture $script:exe @('diagnose') 60000); Wait-GufoMenu }
                'Q' { exit 0 }
                default { Write-GufoMenuLine '选项无效，请输入模型编号或菜单中的字母。' 'Yellow'; Wait-GufoMenu }
            }
            if ($null -ne (Get-Variable leaveMenu -Scope Script -ErrorAction SilentlyContinue) -and $script:leaveMenu) { break }
        } catch { Write-GufoMenuLine $_.Exception.Message 'Yellow'; Wait-GufoMenu }
    }
    if ($null -ne (Get-Variable engineExitCode -Scope Script -ErrorAction SilentlyContinue)) { exit $script:engineExitCode }
    exit 0
} catch {
    Write-Host ("启动失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
