# 真实本机管道 fixture：验证宿主 JSON 与监控客户端之间的链路，不启动模型。
param([string]$WindowsTools = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $WindowsTools 'launcher-host.ps1')
. (Join-Path $WindowsTools 'launcher-monitor.ps1')
. (Join-Path $WindowsTools 'monitor-telemetry.ps1')
if (-not ('GufoEngineHost.Protocol' -as [type])) { Add-Type -Path (Join-Path $WindowsTools 'engine-host.cs') }
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
public sealed class GufoFixturePipe : IDisposable {
    private readonly NamedPipeServerStream pipe;
    private readonly Thread thread;
    public GufoFixturePipe(string name, string payload, int delay) {
        pipe = new NamedPipeServerStream(name, PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        thread = new Thread(delegate() {
            try {
                pipe.WaitForConnection();
                if (delay > 0) Thread.Sleep(delay);
                byte[] data = new UTF8Encoding(false).GetBytes(payload);
                pipe.Write(data, 0, data.Length);
            } catch (IOException) {} catch (ObjectDisposedException) {}
            finally { pipe.Dispose(); }
        });
        thread.IsBackground = true; thread.Start();
    }
    public void Dispose() { pipe.Dispose(); thread.Join(1500); }
}
'@
$script:Passed = 0; $script:Failed = 0
function Assert-True([bool]$Value, [string]$Message = '断言失败') { if (-not $Value) { throw $Message } }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host "[PASS] $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "[FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Invoke-Fixture([string]$Payload, [int]$Delay = 0) {
    $name = 'gufo-stats-' + [guid]::NewGuid().ToString('N')
    $server = New-Object GufoFixturePipe($name, $Payload, $Delay)
    try { Get-GufoEngineHostSnapshot $name } finally { $server.Dispose() }
}
$stateType = ('GufoEngineHost.Protocol' -as [type]).Assembly.GetType('GufoEngineHost.HostState')
$state = [Activator]::CreateInstance($stateType, $true)
$self = [Diagnostics.Process]::GetCurrentProcess()
try {
    [void]$stateType.GetMethod('Started').Invoke($state, @($self.PSObject.BaseObject))
    $initial = $stateType.GetMethod('Snapshot').Invoke($state, @())
    Test-Case '原宿主JSON经真实管道保留PID启动身份且首次没有假统计' {
        $reply = Invoke-Fixture ($initial + "`n")
        Assert-True ($null -ne $reply)
        Assert-True ($reply.engine_pid -eq $self.Id)
        Assert-True ([int64]$reply.engine_start_utc_ticks -eq $self.StartTime.ToUniversalTime().Ticks)
        Assert-True ($null -eq (Get-GufoLastRequest $reply))
    }
    $line = '2026-10-27 12:00:00 [INFO] [http] request=r7 event=completed method=POST path=/v1/chat/completions status=200 duration_ms=500.0 outcome=completed prompt_tokens=100 prefill_tokens=80 generated_tokens=20 cached_tokens=20 queue_ms=2.3 ttft_ms=40.5 prefill_tps=2000.0 decode_tps=43.5'
    [void]$stateType.GetMethod('Observe').Invoke($state, @($line))
    $payload = $stateType.GetMethod('Snapshot').Invoke($state, @())
    Test-Case '完成日志到原宿主JSON再到真实管道和UI数值保持一致' {
        $reply = Invoke-Fixture ($payload + "`n")
        $last = Get-GufoLastRequest $reply
        Assert-True ($last.RequestId -eq 'r7')
        Assert-True ($last.TtftMs -eq 40.5)
        Assert-True ($last.PrefillTokPerSec -eq 2000)
        Assert-True ($last.DecodeTokPerSec -eq 43.5)
        Assert-True ($last.PrefillTokens -eq 80 -and $last.GeneratedTokens -eq 20)
    }
    Test-Case '无效本机管道名不触发连接或读取' {
        foreach ($name in @('', '\\server\pipe\test', 'other', 'gufo-stats-' + ('A' * 32))) {
            Assert-True ($null -eq (Get-GufoEngineHostSnapshot $name))
        }
    }
    Test-Case '错误schema身份与JSON格式均被拒绝' {
        foreach ($text in @($payload.Replace('"schema":1', '"schema":2'), $payload.Replace(('"engine_pid":' + $self.Id), '"engine_pid":0'), 'not-json')) {
            Assert-True ($null -eq (Invoke-Fixture ($text + "`n")))
        }
    }
    Test-Case '无换行和超过8KiB的数据不当作完整快照' {
        Assert-True ($null -eq (Invoke-Fixture $payload))
        Assert-True ($null -eq (Invoke-Fixture (('x' * 9000) + "`n")))
    }
    Test-Case '已连接但不发数据时客户端有界返回且不挂住监控' {
        $name = 'gufo-stats-' + [guid]::NewGuid().ToString('N')
        $server = New-Object GufoFixturePipe($name, ($payload + "`n"), 1200)
        try {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $reply = Get-GufoEngineHostSnapshot $name
            $elapsed = $timer.ElapsedMilliseconds
            Assert-True ($null -eq $reply)
            Assert-True ($elapsed -lt 1000) "管道读取等待了 $elapsed ms"
        } finally { $server.Dispose() }
    }
} finally { $self.Dispose() }
Write-Host ("宿主链路回归：{0} 通过、{1} 失败。" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
