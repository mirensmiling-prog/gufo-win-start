# 以 Windows PowerShell 5.1 的 Add-Type 参数合同执行真实生产编译语句。
# 非 Windows 也能发现参数绑定问题；此处不冒充实际 Windows EXE 编译。
param([string]$WindowsTools = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$script:Passed = 0; $script:Failed = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host "[PASS] $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "[FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-True([bool]$Value, [string]$Message = '断言失败') { if (-not $Value) { throw $Message } }
function Invoke-WinPS51CompileContract([string]$CommandText) {
    $runner = [PowerShell]::Create()
    try {
        [void]$runner.AddScript(@'
param([string]$CompileStatement)
function Add-Type {
    [CmdletBinding()]
    param([string[]]$Path, [string]$OutputAssembly,
        [ValidateSet('Library', 'ConsoleApplication', 'WindowsApplication')][string]$OutputType)
    # 只声明生产语句所需的 5.1 参数；未知的 7.x 参数必须在绑定阶段失败。
    [pscustomobject]@{ Source = @($Path); Destination = $OutputAssembly; Kind = $OutputType }
}
$source = 'E:\中文 模型 [v2]\tools\windows\engine-host.cs'
$temporary = 'E:\临时 编译 [v2]\test-host.exe'
& ([scriptblock]::Create($CompileStatement))
'@)
        [void]$runner.AddParameter('CompileStatement', $CommandText)
        $output = @($runner.Invoke())
        if ($runner.HadErrors) { throw ($runner.Streams.Error | Out-String) }
        $output
    } finally { $runner.Dispose() }
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $WindowsTools 'launcher-host.ps1'), [ref]$tokens, [ref]$errors)
$function = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-GufoEngineHostPath'
}, $true))[0]
$calls = @($function.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-Type'
}, $true))
Test-Case '找到首次未缓存宿主分支的实际Add-Type编译入口' {
    Assert-True (@($errors).Count -eq 0)
    Assert-True ($calls.Count -eq 1)
    Assert-True ($calls[0].Extent.Text.Contains('-OutputAssembly'))
}
Test-Case '真实生产编译语句可绑定WindowsPowerShell5.1参数且保留EXE与中文路径' {
    $result = @(Invoke-WinPS51CompileContract $calls[0].Extent.Text)
    Assert-True ($result.Count -eq 1)
    Assert-True ($result[0].Source[0] -ceq 'E:\中文 模型 [v2]\tools\windows\engine-host.cs')
    Assert-True ($result[0].Destination -ceq 'E:\临时 编译 [v2]\test-host.exe')
    Assert-True ($result[0].Kind -ceq 'ConsoleApplication')
}
Test-Case '同一合同可重现旧CompilerOptions参数错误，避免测试假通过' {
    $rejected = $false
    try { Invoke-WinPS51CompileContract "Add-Type -Path `$source -OutputAssembly `$temporary -OutputType ConsoleApplication -CompilerOptions '/optimize+ /platform:x64' -ErrorAction Stop" | Out-Null }
    catch { $rejected = $_.Exception.Message -match 'CompilerOptions' }
    Assert-True $rejected '旧语句必须因未知 CompilerOptions 参数被拒绝。'
}
Write-Host ("编译参数兼容回归：{0} 通过、{1} 失败。" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
