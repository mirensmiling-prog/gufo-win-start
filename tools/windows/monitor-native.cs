// Windows 原生只读采样；按需编译，不启动 WMI、后台任务或日志写入。
using System;
using System.Runtime.InteropServices;

namespace GufoMonitor
{
    public sealed class Snapshot
    {
        public bool Alive;
        public bool ProcessMemoryValid;
        public ulong WorkingSetBytes;
        public ulong PrivateBytes;
        public bool SystemMemoryValid;
        public ulong TotalMemoryBytes;
        public ulong AvailableMemoryBytes;
        public bool DiskValid;
        public double DiskReadBytesPerSecond;
        public double DiskWriteBytesPerSecond;
        public string DiskError;
    }

    public sealed class Sampler : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct MemoryCounters
        {
            public uint Size, PageFaultCount;
            public UIntPtr PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage;
            public UIntPtr QuotaPagedPoolUsage, QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage;
            public UIntPtr PagefileUsage, PeakPagefileUsage, PrivateUsage;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MemoryStatus
        {
            public uint Length, MemoryLoad;
            public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile;
            public ulong TotalVirtual, AvailVirtual, AvailExtendedVirtual;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct CounterValue
        {
            [FieldOffset(0)] public uint Status;
            [FieldOffset(8)] public double Value;
        }

        [DllImport("psapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetProcessMemoryInfo(IntPtr process, ref MemoryCounters counters, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("pdh.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint PdhOpenQueryW(string source, UIntPtr data, out IntPtr query);
        [DllImport("pdh.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint PdhAddEnglishCounterW(IntPtr query, string path, UIntPtr data, out IntPtr counter);
        [DllImport("pdh.dll", ExactSpelling = true)]
        private static extern uint PdhCollectQueryData(IntPtr query);
        [DllImport("pdh.dll", ExactSpelling = true)]
        private static extern uint PdhGetFormattedCounterValue(IntPtr counter, uint format, out uint type, out CounterValue value);
        [DllImport("pdh.dll", ExactSpelling = true)]
        private static extern uint PdhCloseQuery(IntPtr query);

        // 句柄由调用方 Process 对象持有，监控不自行按 PID 重开，避免 PID 复用。
        private readonly IntPtr process;
        private IntPtr query, readCounter, writeCounter;
        private string diskError;
        private bool disposed;
        private readonly System.Diagnostics.Stopwatch warmup = System.Diagnostics.Stopwatch.StartNew();

        public Sampler(IntPtr processHandle)
        {
            process = processHandle;
            try
            {
                Check(PdhOpenQueryW(null, UIntPtr.Zero, out query));
                Check(PdhAddEnglishCounterW(query, @"\PhysicalDisk(_Total)\Disk Read Bytes/sec", UIntPtr.Zero, out readCounter));
                Check(PdhAddEnglishCounterW(query, @"\PhysicalDisk(_Total)\Disk Write Bytes/sec", UIntPtr.Zero, out writeCounter));
                // 速率计数器先取基线，首次有效显示至少间隔一个采样周期。
                Check(PdhCollectQueryData(query));
                warmup.Restart();
            }
            catch (Exception error)
            {
                diskError = error.Message;
                if (query != IntPtr.Zero) { PdhCloseQuery(query); query = IntPtr.Zero; }
            }
        }

        private static void Check(uint status)
        {
            if (status != 0) throw new InvalidOperationException("PDH 0x" + status.ToString("X8"));
        }

        private static bool ReadRate(IntPtr counter, out double rate)
        {
            uint type;
            CounterValue value;
            uint result = PdhGetFormattedCounterValue(counter, 0x200, out type, out value); // PDH_FMT_DOUBLE
            rate = value.Value;
            return result == 0 && (value.Status == 0 || value.Status == 1) &&
                !Double.IsNaN(rate) && !Double.IsInfinity(rate) && rate >= 0;
        }

        public Snapshot Read()
        {
            if (disposed) throw new ObjectDisposedException("Sampler");
            Snapshot result = new Snapshot();
            uint wait = WaitForSingleObject(process, 0);
            if (wait == 0) return result;
            if (wait != 258) throw new InvalidOperationException("进程句柄失效，Win32=" + Marshal.GetLastWin32Error());
            result.Alive = true;
            MemoryCounters counters = new MemoryCounters();
            counters.Size = (uint)Marshal.SizeOf(typeof(MemoryCounters));
            result.ProcessMemoryValid = GetProcessMemoryInfo(process, ref counters, counters.Size);
            if (result.ProcessMemoryValid)
            {
                result.WorkingSetBytes = counters.WorkingSetSize.ToUInt64();
                result.PrivateBytes = counters.PrivateUsage.ToUInt64();
            }
            MemoryStatus memory = new MemoryStatus();
            memory.Length = (uint)Marshal.SizeOf(typeof(MemoryStatus));
            result.SystemMemoryValid = GlobalMemoryStatusEx(ref memory);
            if (result.SystemMemoryValid)
            {
                result.TotalMemoryBytes = memory.TotalPhys;
                result.AvailableMemoryBytes = memory.AvailPhys;
            }
            result.DiskError = diskError;
            if (query != IntPtr.Zero)
            {
                if (warmup.Elapsed.TotalSeconds < 1)
                {
                    result.DiskError = "计数器预热中";
                    return result;
                }
                uint status = PdhCollectQueryData(query);
                double read = 0, write = 0;
                result.DiskValid = status == 0 && ReadRate(readCounter, out read) && ReadRate(writeCounter, out write);
                if (result.DiskValid)
                {
                    result.DiskReadBytesPerSecond = read;
                    result.DiskWriteBytesPerSecond = write;
                }
                else result.DiskError = status == 0 ? "计数器预热中或数据不可用" : "PDH 0x" + status.ToString("X8");
            }
            return result;
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            if (query != IntPtr.Zero) { PdhCloseQuery(query); query = IntPtr.Zero; }
        }
    }
}
