// 可选监控的独立引擎宿主：转发原始输出，只在内存保留最近一次请求统计。
// 统计口径依据官方 v0.25.0 generation_metrics.hpp / logging.cpp，未复制上游实现。
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace GufoEngineHost
{
    public sealed class RequestStats
    {
        public string RequestId;
        public string CompletedUtc;
        public readonly Dictionary<string, double> Values = new Dictionary<string, double>();

        public string ToJson()
        {
            StringBuilder text = new StringBuilder("{");
            text.Append("\"request_id\":").Append(RequestId == null ? "null" : "\"" + RequestId + "\"");
            foreach (KeyValuePair<string, double> item in Values)
                text.Append(",\"").Append(item.Key).Append("\":").Append(item.Value.ToString("R", CultureInfo.InvariantCulture));
            return text.Append("}").ToString();
        }
    }

    public static class Protocol
    {
        private static readonly string[] RequiredFields = {
            "ttft_ms", "prefill_tps", "decode_tps", "prompt_tokens", "prefill_tokens",
            "generated_tokens", "cached_tokens", "queue_ms", "duration_ms"
        };

        public static string QuoteArgument(string value)
        {
            // Windows CRT 参数规则；不经过 cmd.exe 或 shell。
            StringBuilder text = new StringBuilder("\"");
            int slashes = 0;
            foreach (char character in value ?? String.Empty)
            {
                if (character == '\\') { slashes++; continue; }
                if (character == '"') text.Append('\\', slashes * 2 + 1).Append('"');
                else text.Append('\\', slashes).Append(character);
                slashes = 0;
            }
            return text.Append('\\', slashes * 2).Append('"').ToString();
        }

        public static string BuildArguments(string[] values, int start)
        {
            StringBuilder text = new StringBuilder();
            for (int i = start; i < values.Length; i++)
            {
                if (i > start) text.Append(' ');
                text.Append(QuoteArgument(values[i]));
            }
            return text.ToString();
        }

        public static bool ValidPipeName(string value)
        {
            return value != null && Regex.IsMatch(value, @"\Agufo-stats-[a-f0-9]{32}\z", RegexOptions.CultureInvariant);
        }

        public static RequestStats ParseRequestLine(string line)
        {
            if (String.IsNullOrEmpty(line) || line.Length > 16384 ||
                !Regex.IsMatch(line, @"\A[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \[INFO\] \[http\] request=") ||
                !Regex.IsMatch(line, @"(?:^|\s)event=completed(?:\s|$)") ||
                !Regex.IsMatch(line, @"(?:^|\s)outcome=completed(?:\s|$)") ||
                !Regex.IsMatch(line, @"(?:^|\s)method=POST(?:\s|$)") ||
                !Regex.IsMatch(line, @"(?:^|\s)path=/(?:completion|v1/(?:chat/completions|completions|messages|responses))(?:\s|$)")) return null;
            Match status = Regex.Match(line, @"(?:^|\s)status=([0-9]{3})(?:\s|$)");
            int code;
            if (!status.Success || !Int32.TryParse(status.Groups[1].Value, out code) || code < 200 || code >= 300) return null;
            RequestStats result = new RequestStats();
            foreach (string key in RequiredFields)
            {
                MatchCollection matches = Regex.Matches(line, @"(?:^|\s)" + key + @"=([0-9]+(?:\.[0-9]+)?)(?=\s|$)");
                double value;
                if (matches.Count != 1 || !Double.TryParse(matches[0].Groups[1].Value,
                    NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out value) ||
                    Double.IsNaN(value) || Double.IsInfinity(value) || value < 0) return null;
                if (key.EndsWith("_tokens", StringComparison.Ordinal) && Math.Floor(value) != value) return null;
                result.Values[key] = value;
            }
            Match request = Regex.Match(line, @"(?:^|\s)request=(r[0-9]{1,18})(?:\s|$)");
            result.RequestId = request.Success ? request.Groups[1].Value : null;
            result.CompletedUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
            return result;
        }
    }

    internal sealed class HostState
    {
        private readonly object gate = new object();
        private int engineId;
        private long engineStartTicks;
        private bool alive;
        private long sequence;
        private RequestStats latest;

        public void Started(Process process)
        {
            lock (gate)
            {
                engineId = process.Id;
                engineStartTicks = process.StartTime.ToUniversalTime().Ticks;
                alive = true;
            }
        }
        public void Stopped() { lock (gate) { alive = false; } }
        public void Observe(string line)
        {
            RequestStats stats = Protocol.ParseRequestLine(line);
            if (stats == null) return;
            lock (gate) { latest = stats; sequence++; }
        }
        public string Snapshot()
        {
            lock (gate)
            {
                return "{\"schema\":1,\"engine_pid\":" + engineId.ToString(CultureInfo.InvariantCulture) +
                    ",\"engine_start_utc_ticks\":" + engineStartTicks.ToString(CultureInfo.InvariantCulture) +
                    ",\"alive\":" + (alive ? "true" : "false") +
                    ",\"sequence\":" + sequence.ToString(CultureInfo.InvariantCulture) +
                    ",\"completed_utc\":" + (latest == null ? "null" : "\"" + latest.CompletedUtc + "\"") +
                    ",\"last\":" + (latest == null ? "null" : latest.ToJson()) + "}";
            }
        }
    }

    internal static class PrivatePipe
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr Descriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
        }
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool GetTokenInformation(IntPtr token, int kind, IntPtr data, uint length, out uint needed);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr text);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl, uint revision, out IntPtr descriptor, out uint size);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafePipeHandle CreateNamedPipeW(string name, uint openMode, uint pipeMode,
            uint instances, uint outputBytes, uint inputBytes, uint timeout, ref SecurityAttributes security);

        private static void Check(bool success)
        {
            if (!success) throw new IOException("Win32 " + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture));
        }
        private static string CurrentSid()
        {
            IntPtr token = IntPtr.Zero, buffer = IntPtr.Zero, sidText = IntPtr.Zero;
            try
            {
                Check(OpenProcessToken(GetCurrentProcess(), 8, out token)); // TOKEN_QUERY
                uint needed;
                GetTokenInformation(token, 1, IntPtr.Zero, 0, out needed); // TokenUser
                if (needed == 0 || needed > 65536) throw new IOException("TokenUser size");
                buffer = Marshal.AllocHGlobal((int)needed);
                Check(GetTokenInformation(token, 1, buffer, needed, out needed));
                Check(ConvertSidToStringSidW(Marshal.ReadIntPtr(buffer), out sidText));
                return Marshal.PtrToStringUni(sidText);
            }
            finally
            {
                if (sidText != IntPtr.Zero) LocalFree(sidText);
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                if (token != IntPtr.Zero) CloseHandle(token);
            }
        }
        public static NamedPipeServerStream Create(string name)
        {
            IntPtr descriptor = IntPtr.Zero;
            SafePipeHandle handle = null;
            try
            {
                uint size;
                // 受保护 DACL 只允许当前用户，不授予 Everyone/网络用户访问权限。
                Check(ConvertStringSecurityDescriptorToSecurityDescriptorW("D:P(A;;GA;;;" + CurrentSid() + ")", 1, out descriptor, out size));
                SecurityAttributes security = new SecurityAttributes();
                security.Length = Marshal.SizeOf(typeof(SecurityAttributes));
                security.Descriptor = descriptor;
                security.Inherit = false;
                handle = CreateNamedPipeW(@"\\.\pipe\" + name,
                    2 | 0x40000000 | 0x00080000, 8, 1, 4096, 4096, 500, ref security);
                // OUTBOUND | OVERLAPPED | FIRST_PIPE_INSTANCE; REJECT_REMOTE_CLIENTS。
                if (handle == null || handle.IsInvalid) throw new IOException("CreateNamedPipe " + Marshal.GetLastWin32Error());
                NamedPipeServerStream pipe = new NamedPipeServerStream(PipeDirection.Out, true, false, handle);
                handle = null; // 句柄所有权移交 pipe。
                return pipe;
            }
            finally
            {
                if (handle != null) handle.Dispose();
                if (descriptor != IntPtr.Zero) LocalFree(descriptor);
            }
        }
    }

    public static class Program
    {
        private static readonly object outputGate = new object();
        private static readonly ManualResetEvent stop = new ManualResetEvent(false);
        private static readonly HostState state = new HostState();

        private static void Pump(StreamReader reader, TextWriter output)
        {
            byte[] bytes = new byte[4096];
            char[] characters = new char[4097];
            Decoder decoder = new UTF8Encoding(false, false).GetDecoder();
            StringBuilder line = new StringBuilder(1024);
            bool overflow = false;
            try
            {
                int count;
                // 直接读取底层管道当前可用字节，不等待填满字符缓冲区。
                while ((count = reader.BaseStream.Read(bytes, 0, bytes.Length)) > 0)
                {
                    int length = decoder.GetChars(bytes, 0, count, characters, 0, false);
                    // 控制台失败不停止排空管道，避免 Gufo 被输出背压卡住。
                    try { lock (outputGate) { output.Write(characters, 0, length); output.Flush(); } } catch (IOException) { }
                    for (int i = 0; i < length; i++)
                    {
                        char character = characters[i];
                        if (character == '\n' || character == '\r')
                        {
                            if (!overflow && line.Length > 0) state.Observe(line.ToString());
                            line.Length = 0; overflow = false;
                        }
                        else if (!overflow)
                        {
                            if (line.Length < 16384) line.Append(character);
                            else { line.Length = 0; overflow = true; }
                        }
                    }
                }
                int trailing = decoder.GetChars(bytes, 0, 0, characters, 0, true);
                if (trailing > 0)
                {
                    try { lock (outputGate) { output.Write(characters, 0, trailing); output.Flush(); } } catch (IOException) { }
                    if (!overflow && line.Length + trailing <= 16384) line.Append(characters, 0, trailing);
                    else overflow = true;
                }
                if (!overflow && line.Length > 0) state.Observe(line.ToString());
            }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
        }

        private static void ServePipe(string name)
        {
            while (!stop.WaitOne(0))
            {
                try
                {
                    using (NamedPipeServerStream pipe = PrivatePipe.Create(name))
                    {
                        IAsyncResult connection = pipe.BeginWaitForConnection(null, null);
                        WaitHandle ready = connection.AsyncWaitHandle;
                        try
                        {
                            int signaled = WaitHandle.WaitAny(new WaitHandle[] { stop, ready });
                            if (signaled == 0)
                            {
                                pipe.Dispose();
                                try { pipe.EndWaitForConnection(connection); } catch (IOException) { } catch (ObjectDisposedException) { }
                                return;
                            }
                            pipe.EndWaitForConnection(connection);
                        }
                        finally { ready.Close(); }
                        byte[] payload = new UTF8Encoding(false).GetBytes(state.Snapshot() + "\n");
                        if (payload.Length <= 8192)
                        {
                            IAsyncResult write = pipe.BeginWrite(payload, 0, payload.Length, null, null);
                            WaitHandle written = write.AsyncWaitHandle;
                            try
                            {
                                int signaled = WaitHandle.WaitAny(new WaitHandle[] { stop, written }, 500);
                                if (signaled != 1) pipe.Dispose();
                                try { pipe.EndWrite(write); } catch (IOException) { } catch (ObjectDisposedException) { }
                            }
                            finally { written.Close(); }
                        }
                    }
                }
                catch (Exception error)
                {
                    if (error is ThreadAbortException) return;
                    // 权限/客户端断开仅使遥测暂不可用；不会停止或重启引擎。
                    if (stop.WaitOne(250)) return;
                }
            }
        }

        public static int Main(string[] args)
        {
            if (args.Length < 3 || !Protocol.ValidPipeName(args[0]) || !Path.IsPathRooted(args[1]) || !File.Exists(args[1]))
            {
                Console.Error.WriteLine("引擎宿主参数无效；请从启动器启动。");
                return 2;
            }
            Process engine = null;
            try
            {
                Console.OutputEncoding = new UTF8Encoding(false);
                // Gufo 与宿主共享独立控制台；原生 Gufo 同时接收 Ctrl+C。
                // 宿主等待其退出，确保读取器不会先退出、关闭日志管道。
                Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs eventArgs) { eventArgs.Cancel = true; };
                ProcessStartInfo info = new ProcessStartInfo();
                info.FileName = Path.GetFullPath(args[1]);
                info.Arguments = Protocol.BuildArguments(args, 2);
                info.WorkingDirectory = Path.GetDirectoryName(info.FileName);
                info.UseShellExecute = false;
                info.CreateNoWindow = false;
                info.RedirectStandardOutput = true;
                info.RedirectStandardError = true;
                info.StandardOutputEncoding = new UTF8Encoding(false);
                info.StandardErrorEncoding = new UTF8Encoding(false);
                engine = new Process();
                engine.StartInfo = info;
                if (!engine.Start()) return 3;
                // 引擎已收到完整参数，释放宿主额外的 Key 字符串引用。
                info.Arguments = String.Empty;
                Array.Clear(args, 2, args.Length - 2);
                state.Started(engine);
                Thread stdout = new Thread(delegate() { Pump(engine.StandardOutput, Console.Out); });
                Thread stderr = new Thread(delegate() { Pump(engine.StandardError, Console.Error); });
                Thread pipe = new Thread(delegate() { ServePipe(args[0]); });
                stdout.IsBackground = true; stderr.IsBackground = true; pipe.IsBackground = true;
                stdout.Start(); stderr.Start(); pipe.Start();
                engine.WaitForExit();
                stdout.Join(2000); stderr.Join(2000);
                state.Stopped();
                stop.Set();
                pipe.Join(1000);
                return engine.ExitCode;
            }
            catch (Exception error)
            {
                // 不回显命令行/异常文本，避免可能包含 API Key 的参数泄漏。
                Console.Error.WriteLine("引擎宿主失败（" + error.GetType().Name + "），请查看引擎窗口的原始错误。");
                return 3;
            }
            finally
            {
                stop.Set();
                if (engine != null) engine.Dispose();
            }
        }
    }
}
