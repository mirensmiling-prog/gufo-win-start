# Gufo 官方版命令行启动器

适用于本目录的官方 Gufo v0.25.0。运行只需要 Windows 自带的 Windows PowerShell 5.1，不需要 Python、PyQt 或安装额外模块。

<img width="1129" height="446" alt="image" src="https://github.com/user-attachments/assets/4ba4f538-c23f-4a54-9429-b5aef6535e5d" />

## 日常使用

1. 保留完整官方发行包，将 `start.cmd`、`tools/windows/` 放在 `gufo.exe` 同级。
2. 模型放入同级 `models/`，或者启动后按 `D` 粘贴已有模型目录。四个分片保持原文件名，放在同一目录。MTP 可放在所选目录的 `MTP/` 中，也可按 `A` 添加另一个模型根目录。
3. 双击 `start.cmd`，输入模型编号。检查加速文件、上下文、端口等设置，按 Enter 启动。已有启动记录后，在模型列表直接按 Enter 可重复上次设置。
4. 默认启动独立的 Gufo 命令窗口，启动菜单随后退出。模型加载和推理由 Gufo 自己运行；启动器没有后台监控进程。以 Gufo 的就绪输出为准。
5. 在 Gufo 窗口按 Ctrl+C 停止服务。关闭菜单不等于停止已经启动的独立服务。

```bat
start.cmd
start.cmd -Last
start.cmd -DryRun
start.cmd -Last -DryRun
start.cmd -Models "E:\我的模型\Flash-Next"
start.cmd -Foreground
start.cmd -Last -Foreground
```

`-Last` 使用上次非敏感设置重新检查文件、分片和实际 help，再生成命令。`-DryRun` 仍会读取 EXE 的版本和 help，但不启动推理、不写设置。`-Foreground` 保留当前窗口，便于查看引擎启动错误。

设置只在实际启动时写入发行包根目录 `gufo-launcher.json`，API Key 不保存、不回显。局域网模式启动时可直接按 Enter 留空，此时不传 `--api-key`、不启用鉴权；填写 Key 时照常启用 Bearer 鉴权。命令预览/DryRun 不虚构 Key，实际启动时再询问。配置中保留模型绝对路径，移动模型或发行包后可以重新选目录。旧 fork 的 `%LOCALAPPDATA%\gufo\launcher.json` 不会被读取或覆盖。

## 设置菜单与按键

设置菜单中直接按快捷键生效，无需再按 Enter；模型列表仍使用“编号 + Enter”，支持超过 9 个模型。

| 快捷键      | 操作                                                         |
| ----------- | ------------------------------------------------------------ |
| `7`         | 循环上下文：32K → 64K → 128K → 256K → 原生（0）→ 32K         |
| `X`         | 输入自定义上下文；原有自定义值保留，按 7 后前进到下一个更大的预设，超过最大预设则回原生 |
| `3`         | 循环思考模式：跟随引擎 → 开启 → 关闭                         |
| `9`         | 开关实时进度                                                 |
| `2` / `F`   | 输入草稿上限 / 下限                                          |
| `D` / `H`   | 查看命令 / 实际 help，按键确认后返回                         |
| `B` / `Esc` | 返回模型列表                                                 |
| `Enter`     | 启动服务                                                     |

所有设置及操作各占独立一行。模型、草稿和缓存长路径单独缩进，按终端显示列宽换行，优先保留完整的路径段及文件名。布尔状态使用“开启／关闭”；每次修改后重绘，帮助、预览及错误提示会等待确认。重定向输入或宿主不支持单键读取时，回退为输入选项后按 Enter。

## 参数与低开销边界

- 每次启动读取所选 `gufo.exe --version` 和 `gufo.exe serve llm --help`，只发送实际 help 存在的参数。
- 首次上下文使用明确可见的 32768、sessions=1；可改成 0 使用原生上下文。这是启动器的保守初始选择，不是引擎默认值。
- 草稿默认上限 7、下限 1。关闭投机时不发送草稿参数。多个草稿候选时由用户选择；自动发现仅按文件名/位置，实际兼容由引擎检查。
- RAM 快照预算 0 表示自动；它不是整个推理进程的内存总上限。输入自定义预算时使用 GiB，启动器转换为字节。
- 缓存目录留空时不启用磁盘缓存；启用后的保留预算当前使用官方默认 8 GiB。
- 实时速度/进度采用官方 `--log-progress --log-level info` 的原始输出。这里没有额外的 token/s 图表或 `/metrics` 采样进程。
- 保持引擎的默认采样预设；启动器没有搬用旧 fork 的采样、GPU 内存估算或私有环境变量。
- 不发送旧 fork 的 `--mtp-policy`、`--mtp-draft-vocab`、`--prompt-lookup`。不自动换端口或结束其他进程。
- 只读取 GGUF 文件头和文件大小，不加载权重。默认扫描深度 4，不递归进入目录联接。读取文件头不等于验证全部权重；引擎启动可能发现额外问题。
- `mmproj` 留空时沿用 help 中的引擎自动发现行为；该留空状态不表示强制禁用视觉。
- 快速退出或缺 DLL 时使用 `start.cmd -Foreground`。引擎独立窗口中后续发生的错误需要在该窗口查看。

## 需求覆盖与验收

主角色：Windows/DevOps 工程；辅助角色：只读代码审查和测试。

| ID     | 原始要求或约束                     | 实现与验收边界                                               |
| ------ | ---------------------------------- | ------------------------------------------------------------ |
| CLI-01 | 像旧项目 start.cmd 一样便捷启动    | 数字选模型、目录输入、Last、DryRun、前台排障；双击与新窗口行为需 Windows 验收 |
| CLI-02 | 使用官方 Gufo 的实际 help          | 运行时采集 help 并校验参数；不引入旧 fork 专用开关           |
| CLI-03 | 模型选择目录、四文件 GGUF          | 有界目录扫描、四片归组、缺首片/缺其他片/坏文件头拦截；不改模型文件 |
| CLI-04 | 投机/MTP 加载便利                  | 已有独立 sidecar 发现/选择；不下载或移植权重和算法           |
| CLI-05 | 内存开销低、实时速度               | 菜单启动后退出；Gufo 原生实时日志；实际 Windows 内存与速度未在 macOS 代验 |
| CLI-06 | 放弃 Python 控制台方向             | 新入口不依赖 Python；原目录保留，未删除用户代码              |
| CLI-07 | 路径、安全与回归                   | 字面路径、Windows 引用、Key 脱敏、不保存秘密、不覆盖旧包；测试另见下面 |
| CLI-08 | 每行一个，处理错行，让菜单更精细   | 每个设置独立显示；中文状态；长路径按显示列宽换行；清屏重绘及提示停留 |
| CLI-09 | 像旧 start.cmd 一样按 7 切换上下文 | 单键循环预设，X 保留自定义；不重置原有上下文设置             |
| CLI-10 | 自己局域网使用，API Key 可以留空   | 留空不传 api-key；填写时启用 Bearer；预览不伪造 Key，设置不保存 Key |

当前状态：启动器已实现，本机定向测试通过；Windows 交付验收未执行。

本轮在 macOS 的便携 PowerShell 7.6.9 上验证：

- `test-launcher.ps1`：69 组通过、0 失败，退出码 0。原有分片/参数/设置安全/取消返回/菜单回归，以及局域网空 Key、非空 Key、脱敏和空 SecureString 输入路径均通过。
- PowerShell AST 解析：全部脚本无语法错误。源码采用 5.1 可用语法，中文脚本为 UTF-8 BOM、CRLF；这不等于实际运行过 Windows PowerShell 5.1。
- 临时假 EXE 的流程检查：Last/MTP 命令、DryRun 不改配置且只运行版本/help、菜单选模型/预览/返回/退出、主菜单 Enter 重复上次设置、Last 缺片重验、当前 help 缺少 MTP 参数时拒绝，全部符合预期。假 EXE 不执行推理，不能替代 Windows PE/DLL/GPU 测试。
- 独立复核发现的取消后误退出已修正，并增加回归；脚本 BOM/换行已处理。原 Python 控制台、旧下载包脚本及当前 gufo.exe 以指纹复核保持不变。
- 本轮真实终端 PTY 检查：不发送回车，分别按两次 7，立即得到 32768、65536；按 Esc 返回。此项在 macOS PowerShell 7 上执行，Windows 单键与字体显示仍需真机验收。
- 局域网 Last/DryRun 假 EXE 流程：不询问 Key、不生成 api-key 参数、不改设置，退出码 0。Windows 实际空 Key 监听仍需更新脚本后重启服务验收。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\windows\tests\test-launcher.ps1
```

Windows 人工验收：双击菜单；选择中文/空格目录；四片模型与 MTP 启动；API 就绪；实时进度；Ctrl+C；Last 重启；端口被占用；缺 DLL；独立服务运行时菜单退出；任务管理器核对无启动器常驻。

## 来源与许可

交互布局和目录扫描思路参考本地旧发行包及 [pixmaate/gufo 2eb0778](https://github.com/pixmaate/gufo/tree/2eb0778ac15d9e1c18c5b2f9e5dbbecc19e20ec2)。新启动器面向官方 Gufo，沿用发行包根目录的 [MIT LICENSE](LICENSE)，保留 `Copyright (c) 2026 gufo contributors`。第三方运行时和模型仍适用各自许可。旧包及其脚本未改动。

独立窗口及参数传递使用系统自带的 [Start-Process](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/start-process?view=powershell-5.1)，按文档构造完整引用后的 ArgumentList。
