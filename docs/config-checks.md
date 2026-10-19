# 配置检查

双击 `tools/check-config.cmd`，或在配置根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-config.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-config.ps1 -Mpv
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-config.ps1 -Mpv -Verbose
..\python.exe tools/check_config.py --json
..\python.exe tools/test_check_config.py
```

需要 Python 3.10+ 标准库；启动器优先使用 mpv 同级便携 Python，再找系统 Python。双击入口包含 mpv 原生检查，命令行默认离线；`-MpvRoot` 指定播放器目录，`-ConfigRoot` 指定配置目录，`-Json` 输出 JSON。

## 检查范围

| 项目 | 能检查 | 边界 |
| --- | --- | --- |
| 配置引用 | 递归 include、循环/缺失文件、profile、literal `~~/` VS/GLSL/hook/ICC 路径 | 不推断表达式、外部模型或动态 Lua 路径 |
| 原生输入（`-Mpv`） | mpv 规范化键名、同 section 等价键冲突、命令与参数解析 | 不执行输入命令，不加载项目脚本或媒体 |
| 脚本接线 | 脚本标识/入口、名称碰撞、literal 消息与命名绑定、嵌套 cycle-commands | 动态/条件注册及强制绑定优先级仍需运行验证 |
| InputEvent | 启用状态、外部文件、prefix；按动作和完整条件分组 | 单击/长按/释放可并存；条件实际行为需运行验证 |

`local.conf` 即使存在也不读取；外部路径只报告待验证。离线模式只认可项目内 profile 与 `default`，内置 profile 需查询 mpv。等价键包括 `CTRL+SHIFT+a` / `CTRL+A`、`MOUSE_BTN0` / `MBTN_LEFT`；大小写和不同 section 分开处理。

输出含文件、行号、规则与 ERROR/WARNING；错误退出码 1，无错误 0，启动器缺 Python 2。WARNING/INFO 和源码声明匹配不等于功能通过；`-Verbose` 展开来源，JSON 保留全部条目。

## CI 与验收

Windows workflow `.github/workflows/config-check.yml` 在 `dev`/`master` push、PR 或手动触发时运行 Python 3.12：

```powershell
python tools/test_check_config.py ReferenceChecks WiringChecks
python tools/test_qwen_asr.py
python tools/test_gpu_probe.py
python tools/test_verify_gpu.py
python tools/check_config.py
```

CI 运行配置接线、字幕适配、GPU 依赖探针和验收工具失败判定的离线回归；`test_verify_gpu.py` 的两项原生集成在缺少本机 mpv 时跳过。CI 不下载 mpv、VS 或模型，不验证动态 handler、媒体与 GPU。需要原生输入检查时在本机加 `-Mpv`；GPU 产帧用 `tools/verify-gpu.ps1 -Run`。

历史基线 `627414a`、`050a2c7`、`ecd72dd`、`538243e`：31 项本机回归（22 离线、9 原生）通过；远端 workflow 尚未确认。本页不维护随工作区变化的文件数或检查统计。

实现依据：[mpv 输入绑定](https://mpv.io/manual/master/#property-list-input-bindings)、[脚本入口](https://mpv.io/manual/master/#script-location)、[命名绑定实现](https://github.com/mpv-player/mpv/blob/master/player/lua/defaults.lua)。

## 正式版跟随与预发布

发布策略为“官方正式 tag → 本项目 Windows 构建 → 自动预发布 → GPU/字幕验收 → 人工转正式版”。不跟随 `git-release`、RC 或每日构建，不自动替换用户正在使用的播放器。

`.github/workflows/player-release.yml` 在默认分支每天 UTC 03:23（北京时间 11:23）检查上游，也可手动指定 `mpv_tag`。定时与手动入口需要 workflow 已进入远端默认分支；当前仓库为 `dev`。使用 GitHub 自带的 `GITHUB_TOKEN`；仅发布 job 获得 `contents: write`，构建 job 不持有发布权限。

`release/manifest.json` 管理配置修订、构建依赖提交和必需能力。版本名为 `player-v0.41.0-r1`：mpv 官方 tag 与本项目配置修订独立；同一个 mpv 版本下发布配置修复时增加 `revision`。已公开的资产拒绝覆盖，上传失败只留下草稿，同源重跑可补齐草稿。预发布始终 `latest=false`，正式用户继续使用已验收版本。

Windows 构建参考 mpv 自身 MSYS2 CI，采用仍提供 mujs/rubberband 的 UCRT64 环境，固定 mpv tag 解析后的源码提交，显式启用 LuaJIT、JavaScript、D3D11、VapourSynth 等；VS 只安装固定提交的头文件，实际 Python/VS 运行时另行分发。文件浏览器排序需要 `ffi`，弹幕解压需要位运算，因此使用 LuaJIT，不能只检查 Lua 5.1 ABI。LuaSocket 从固定提交构建并与播放器共用 LuaJIT 的头文件和 `lua51.dll`；WebUI 从播放器目录解析模块，不依赖进程当前目录。依赖的 MSYS2 二进制包在构建时解析，版本记录于包内 `msys2-packages.txt`；这不是所有依赖完全锁定的逐字节可复现构建。

`v0.41.0` 原源码直接链接 VSScript；为让 VS 保持可选组件，回移上游动态加载修复 `75b2ccf` 和兼容旧 VS 的 `44a9b03`；现有菜单需要次字幕独立字号，再回移 `8ab3f8b`。后者只将补丁的 sub-delay 未改动上下文适配到 0.41 的 float 类型，不引入不相关的精度改动。完整提交固定在清单的 `mpv_backports`，只对明确列出的 tag 应用；补丁检查失败即停止，不自动猜测适用版本。包内附 `mpv-source.patch`，Release 说明列出补丁来源；这是基于正式源码的本项目构建。其他正式 tag 默认使用自身实现。

同一 tag 还应用清单 `mpv_local_patches` 中的本项目退出顺序补丁：先释放音频设备通知，再销毁视频窗口；命令状态仍保留至视频事件通知结束。原因是云端完整菜单测试访问设备列表后，窗口线程结束时音频模块已卸载，随后 `wasapi_change_uninit` 注销通知触发访问冲突；基础 CPU 检查未覆盖这个生命周期。本补丁单独列出，不冒充上游提交。手动运行 `Diagnose unverified player`，指定失败发行运行 ID，可对保留的播放器取得 GDB/COM 清理调用栈；诊断任务不发布资产。

流水线先跑离线回归，再构建与收集原生 DLL 依赖，随后执行配置原生解析和全脚本 CPU 播放检查：实际加载两个本地媒体、切换下一文件、恢复速度。使用精简 PATH、移除 Lua/Python/mpv 环境覆盖，从无关工作目录启动；缺能力、进程非零、日志缺失、错误级日志或缺成功标记均失败。检查后的文件摘要必须与归档前一致；最终 ZIP 再解压到含中文和空格的新位置复测，校验匹配才可发布。它不覆盖 D3D11 渲染、GPU 产帧、AI 推理或真实片源性能。

从 r2 起额外检查 `secondary-sub-scale`，并对组装后的播放器执行全菜单回归：`tools/test_menu_ui.py --full --software-renderer --local-media`。CI 用本地 H.264/AAC 合成片段、D3D11 WARP 软件渲染和无增强 shader 的测试条件，提供菜单、次字幕字号、切片/重置及截图证据；不改变发行包默认画质。通过报告绑定播放器 SHA256，缺少或不匹配的 `menu-report.json` 不得发布。断言通过但进程退出异常仍失败；保留崩溃事件及 `unverified-player` 供诊断，不将其发布为候选。WARP 不替代 NVIDIA 实际渲染、VS 产帧和 AI 验收。r1 曾只通过 CPU 检查，缺少次字幕字号支持，已在该预发布说明中标为已知问题，不得晋级正式版。

2026-10-16 的 r2 发行基线：云端流水线（含 WARP 105 项、正常退出及 ZIP 迁移）通过；公开 ZIP 校验后，本机 RTX 4070 Laptop 的 105 项菜单/双字幕/切片回归通过，退出码 0、错误日志为空。证据为 Release 附件及本机 `cache/release-audit/r2-published-rtx.json`；不包含 VS、ASR 或真实片源性能验收。

本机只读检查上游（有未提交修改时生成不能构建/发布的审计计划）：

```powershell
python tools/release.py plan --allow-dirty --output cache/release-audit/plan.json
python tools/test_release.py
```

干净且已提交的源码可去掉 `--allow-dirty`。`stage`、`check`、`archive`、`check-archive`、`publish` 的完整参数见各自 `--help`；编译脚本 `tools/build-release-msys2.sh` 只在 CI 的 UCRT64 环境执行，不在日常播放器目录安装编译器。`publish` 是实际远端写入命令，日常自检不调用。

首个候选仍是播放器及配置，`components` 目录清单尚未填入已验收的分包；`pending_components` 明确列出 VS、Whisper、Qwen 的待办。不能称为离线完整版，也不能把本机 `.venv` 直接塞入包。后续组件用独立固定版本/哈希/兼容范围，不随每次 mpv 更新重复上传模型；完整离线包须在组件全部通过后组装。

转正式版前，使用最终下载的候选包和选定组件完成启动/媒体/菜单/切片/重置、每个提供的 VS 预设产帧及 shader 渲染、Whisper/Qwen 真实字幕/缓存/取消、路径迁移和干净机器验收。把硬件、版本、组件和未覆盖项记入 Release 说明，保留原始证据；之后在 GitHub 编辑该预发布，取消 Pre-release 并设置 Latest。流程不自动做此晋级。

2026-10-16 来源核对：官方 `v0.41.0` Windows MinGW 包可以通过本项目原生命令解析，但 `--vf=help` 没有 `vapoursynth`，不能作为当前全功能版的直接替换；外层 ZIP 还含一个内层 ZIP。构建结果以对应 Actions 运行及 Release 附件为准；本地脚本或离线回归通过不等于正式源码构建已通过。

依据：[mpv 正式发布](https://github.com/mpv-player/mpv/releases)、[官方 MSYS2 CI](https://github.com/mpv-player/mpv/blob/v0.41.0/ci/build-msys2.sh)、[GitHub 定时事件](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)。

## 菜单与设置保留回归

`python tools/test_menu_ui.py --full` 加载日常脚本，经真实导航/回车检查菜单、状态、切片与恢复；隔离历史及 IPC，禁用测试网络弹幕。进程失败、错误级日志、缺少报告或截图均判失败。

`CTRL+R` 或菜单“工具与高级 → 播放设置 → 下一文件的设置保留策略”中的“保留全部更改”使用空重置列表。`no` 不是可重置选项名，会在切片时报错，不能作为关闭值。配置默认仍使用原有常用列表，立即恢复操作独立于保留策略。[mpv 选项说明](https://mpv.io/manual/master/#options-reset-on-next-file)。

本机原生回归确认：切换策略不会修改当前速度；当前文件加载时已登记的重置项可能在第一次切片恢复一次，之后加载的文件按空列表保留更改。此策略也不覆盖自动 profile、专用脚本重置或 watch-later 恢复。菜单与快捷键遵循同一原生行为。2026-10-16 本机完整回归：`cache/menu-rework/20261016-154313-full/report.json`，52 步/105 项断言通过，错误级与致命日志均为空。

## 上游脚本与着色器维护

`M` 或菜单“工具与高级 → 维护 → 检查脚本与着色器更新”先获取 `manager.json` 指定的源并预览，选择“应用安全更新并备份”才修改目标。获取失败会中止整个预览，不使用旧下载结果。源仓库仅位于忽略的 `cache/manager/sources/`，不在脚本目录创建 Git 仓库或修改项目远端。

- 首次遇到与上游不同的现有文件，或文件与上次安装的上游基线不同，均标为“本地差异，保留”。已提交的本地定制同样受保护；不会以 Git 工作区干净为由覆盖。
- 与上游完全相同的文件会在应用时建立基线；以后仅自动更新仍与该基线一致的文件。没有基线的差异需人工比较合并，工具不提供强制覆盖。
- 应用前及逐文件写入前再次核对预览快照。先暂存全部内容并备份原文件，安装失败时尝试恢复本次已改文件；任何恢复失败会明确报错。
- 备份在 `cache/manager/backups/`，`manifest.json` 对应目标、状态及原始 `.old` 文件。手动恢复前先退出播放器；备份不自动清理、不随发布包分发。
- 更新后重启播放器。预览/取消入口分别为 `script-message-to manager manager-update-all`、`script-message-to manager manager-cancel`；应用入口为 `script-message-to manager manager-apply`，必须先在当前进程预览。

本地维护实现为 `scripts/manager.lua` 与 `script-modules/managed-update.lua`；更新其他脚本时保留这些修改。隔离本地 Git 源的回归：`python tools/test_manager.py`，不下载上游也不更新日常配置。

## 统一诊断与播放采样

菜单“工具与高级 → 维护 → 诊断与播放性能…”可检查当前配置与可选组件，或采样当前播放。结果仅写入忽略的 `cache/player-health/`；菜单提供打开报告目录。不会自动安装、更新依赖或修改播放参数。

诊断分别记录配置原生接线、VS Bilateral 依赖、Qwen Python/CUDA 导入、FFmpeg、NVIDIA 驱动，以及运行时/字幕模型配置文件是否存在。任务“已完成”表示报告已生成，每个检查项的 `ok` 决定是否通过；文件存在、导入成功不等于实际产帧或识别成功。路径采用当前进程的本机配置，不导出全部选项或私人 token。诊断不会加载 Qwen 模型，也不运行 Whisper 推理。

播放采样默认预热 2 秒后测量 30 秒，可在 `script-opts/player-health.conf` 调整。报告记录媒体规格、增强/滤镜、解码后端、窗口、媒体时间推进比、掉帧增量、VO pass 滚动平均耗时的 P50/P95/最大值和可用的 NVIDIA 整卡显存/利用率。VO 耗时不覆盖完整 VS/解码流水线，不能换算成滤镜 FPS；整卡显存包含其他程序。暂停、切片、跳转、更改滤镜/窗口/播放参数或取消都会使本次报告无效；缺少有效 VO 耗时也不能作为基线。预热不计首次编译时间。

同条件的独立采样工具：

```powershell
# 合成片源冒烟回归；不是实际影片性能结论
python tools/benchmark_playback.py --height 720 --seconds 5
python tools/benchmark_playback.py --height 1080 --seconds 5
python tools/benchmark_playback.py --height 2160 --seconds 5
# 用户指定真实片源后，同一片段分别测默认配置与明确指定的增强
python tools/benchmark_playback.py --media 'X:/media/sample.mkv' --start 60 --seconds 30
python tools/benchmark_playback.py --media 'X:/media/sample.mkv' --start 60 --seconds 30 --preset NR_BILATERAL_CUDA
python tools/test_player_health.py
```

工具保留根配置选项，只加载 GPU 控制器与采样脚本，关闭音频并固定 1280×720 窗口；不代表所有日常脚本/音频同步开启时的结果。`--minimal` 跳过根配置，报告仍记录实际滤镜与后端。真实文件会在增强初始化后重新定位到 `--start`，再按相同预热采样；无有效输出、进程失败、无日志或采样中断均失败。每次输出 JSON、播放器日志和视频截图；逐项比较相同片源/起点/窗口/根配置与驱动条件的报告，不用合成源排名代替真实基线。重型预设可能编译引擎，工具仅在明确传入 `--preset` 时启用。

菜单对应 `player_health` 消息：`health-menu`、`health-diagnose`、`health-sample [2..120 秒]`、`health-cancel`、`health-open-reports`。本地实现为 `scripts/player-health.lua`，无默认采样快捷键。真实课程采样见下方记录，其他片源需另行采样。

2026-10-16 本机 RTX 4070 Laptop 8GB / mpv `v0.41.0-1017-g02a595ddc`：`cache/player-health/test-20261016-153821-867973/report.json` 通过 10 项真实播放/诊断断言，覆盖有效采样与暂停、切片、跳转、滤镜变化、手动取消失效；本机五个诊断任务和九个文件检查均通过。720p/1080p/2160p 合成源各 3 秒采样通过（`benchmark-20261016-153641-069724/`、`153654-426284/`、`153704-669119/`）；同一合成 MKV 的默认/Bilateral 指定起点流程通过（`153842-983232/`、`153750-284759/`）。这些是工具回归，不作为性能排名或真实影片基线。

2026-10-19 真实课程基线：同机 RTX 4070 Laptop 8GB / 驱动 616.92 / 上述日常播放器；单个 1280×720/22fps H.264 中文数学课程，从 60 秒处分别定位，预热 2 秒后各采样 30 秒。根配置、固定 1280×720 窗口、D3D11、`d3d11va-copy`，只加载 GPU 控制器与采样脚本、关闭音频。两组都保留根配置的 `FSRCNNX_x1_16-0-4-1_distort.glsl` 与 `SSimDownscaler.glsl`，默认组没有菜单增强，Bilateral 组增加 `NR_BILATERAL_CUDA`：

| 方案 | VO P50 / P95（ms） | 时间推进比 | VO / 解码丢帧 / VO 延迟增量 |
| --- | --- | --- | --- |
| 默认（无菜单增强） | 4.169 / 4.221 | 1.001390 | 0 / 0 / 0 |
| Bilateral | 4.278 / 4.766 | 1.001284 | 0 / 0 / 0 |

两组采样有效、退出码 0、无错误级日志，截图已目视检查；原文件大小/修改时间/SHA256 和同级目录列表不变。汇总为 `cache/player-health/course-baseline-20261019/summary.json`，原报告分别为 `benchmark-20261019-140635-044113/report.json` 与 `benchmark-20261019-140710-689551/report.json`。VO 数据不包含完整 VS/解码流水线；该静态板书课程的单次短采样不代表电影、1080p/4K、其他重型预设、音画同步或主观画质结论。
