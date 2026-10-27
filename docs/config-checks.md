# 配置检查

双击 `tools/check-config.cmd`，或在配置根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-config.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-config.ps1 -Mpv
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-config.ps1 -Mpv -Verbose
..\python.exe tools/maintenance/check_config.py --json
..\python.exe tools/tests/test_check_config.py
```

需要 Python 3.10+ 标准库；启动器优先使用 mpv 同级便携 Python，再找系统 Python。双击入口包含 mpv 原生检查，命令行默认离线；`-MpvRoot` 指定播放器目录，`-ConfigRoot` 指定配置目录，`-Json` 输出 JSON。

## 工具目录

`tools/` 按用途分组；普通使用从顶层 Windows 入口进入，无需逐个运行 Python 或 Lua 文件。

| 位置 | 用途 |
| --- | --- |
| `tools/*.cmd`、`tools/*.ps1` | 双击、命令行操作入口；原有入口路径保持不变 |
| `tools/runtime/` | 播放时按需调用的 Qwen 字幕适配、路径兼容和 GPU 依赖探针 |
| `tools/maintenance/` | 配置检查、组件安装与迁移、GPU 验收和模型下载的内部实现 |
| `tools/tests/` | Python/Lua 回归、真实播放验收及性能采样 |
| `tools/release/` | 播放器发行编排与 MSYS2 构建脚本 |

常用入口：

| 操作 | 入口 |
| --- | --- |
| 检查配置 | 双击 `tools/check-config.cmd` |
| 检查、安装组件或修复迁移路径 | 双击 `tools/components.cmd` |
| 检查 GPU 实际输出 | 双击 `tools/verify-gpu.cmd`，可能触发耗时的首次编译 |
| 导入已有 VS 运行时 | 双击 `tools/install-vs-runtime.cmd` |
| 部署 Qwen 源环境 | `tools/setup-qwen-asr.ps1`，见 [字幕说明](ai-subtitles.md) |
| 统一 AI 后端／模型／字幕目录 | `tools/setup-ai-subtitles.ps1`，见 [字幕说明](ai-subtitles.md#统一安装与目录) |
| 导出配置或本机 VS 包 | `tools/export-config.ps1`、`tools/export-vs-addon.ps1` |
| 导出生成的字幕 | 播放器 AI 字幕管理菜单调用 `tools/export-ai-subtitle.ps1` |

整理后直接执行 Python、Lua 或构建脚本的命令使用新子目录，本文及各功能说明已同步。播放器脚本和离线组件安装包也使用相同布局；复制或更新配置时保留整个 `tools/`，避免只复制顶层入口导致缺依赖。测试不会在日常启动时自动遍历执行。兼容边界与各操作参数见本页及对应功能说明。

## 上游定期检查

GitHub Actions 的 `Weekly upstream pull request` 每周一北京时间 10:17 检查 `dyphire/mpv-config:master`，与本仓库 `dev` 比较；定时运行可能有延迟，也可在 Actions 页面手动运行。工作流合并到默认分支 `dev` 后才会启用定时检查。

- 无更新：仅 fetch 并写运行摘要，不创建提交、远端分支、PR 或 Issue。
- 有更新：将原始上游提交推到 `codex/upstream-sync`，建立或继续更新同一个 PR；不合并到 `dev`，冲突由维护者处理。
- 手工修改同步分支或上游改写历史时：停止更新并报错，保留人工处理。主动关闭且未合并的同一上游版本不会每周重建 PR。
- 审查配置、本地定制和播放行为后，使用 **Create a merge commit** 手动合并，保留上游祖先关系；Squash/Rebase 会导致后续检查重复识别旧提交。

仓库 Settings → Actions → General → Workflow permissions 需要允许 GitHub Actions 创建 PR；默认权限仍可保持只读，由本工作流单独申请 `contents: write` 和 `pull-requests: write`。使用默认 `GITHUB_TOKEN` 创建的 PR，检查可能需要在 PR 页面批准运行。若上游开始修改 `.github/workflows/`，默认 token 可能无权推送；此时运行会失败，需配置仅限本仓库、具有 Contents / Pull requests / Workflows 写权限的 `UPSTREAM_SYNC_TOKEN` secret 后重试。不把 token 写进配置或 Git。

本地预览只获取引用并显示结果，不推送、不创建 PR：

```powershell
..\python.exe tools/maintenance/upstream_sync.py
..\python.exe tools/tests/test_upstream_sync.py
```

`--publish` 才会推送同步分支并调用 GitHub API，需要 Git 推送权限与已认证的 `gh`。脚本不切换当前分支、不修改工作区或创建合并提交；网络、推送、API 或历史检查失败均以非零退出码报告。

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
python tools/tests/test_check_config.py ReferenceChecks WiringChecks
python tools/tests/test_qwen_asr.py
python tools/tests/test_components.py
python tools/tests/test_gpu_probe.py
python tools/tests/test_verify_gpu.py
python tools/maintenance/check_config.py
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

从 r2 起额外检查 `secondary-sub-scale`，并对组装后的播放器执行全菜单回归：`tools/tests/test_menu_ui.py --full --software-renderer --local-media`。CI 用本地 H.264/AAC 合成片段、D3D11 WARP 软件渲染和无增强 shader 的测试条件，提供菜单、次字幕字号、切片/重置及截图证据；不改变发行包默认画质。通过报告绑定播放器 SHA256，缺少或不匹配的 `menu-report.json` 不得发布。断言通过但进程退出异常仍失败；保留崩溃事件及 `unverified-player` 供诊断，不将其发布为候选。WARP 不替代 NVIDIA 实际渲染、VS 产帧和 AI 验收。r1 曾只通过 CPU 检查，缺少次字幕字号支持，已在该预发布说明中标为已知问题，不得晋级正式版。

2026-10-16 的 r2 发行基线：云端流水线（含 WARP 105 项、正常退出及 ZIP 迁移）通过；公开 ZIP 校验后，本机 RTX 4070 Laptop 的 105 项菜单/双字幕/切片回归通过，退出码 0、错误日志为空。证据为 Release 附件及本机 `cache/release-audit/r2-published-rtx.json`；不包含 VS、ASR 或真实片源性能验收。

本机只读检查上游（有未提交修改时生成不能构建/发布的审计计划）：

```powershell
python tools/release/release.py plan --allow-dirty --output cache/release-audit/plan.json
python tools/tests/test_release.py
```

干净且已提交的源码可去掉 `--allow-dirty`。`stage`、`check`、`archive`、`check-archive`、`publish` 的完整参数见各自 `--help`；编译脚本 `tools/release/build-release-msys2.sh` 只在 CI 的 UCRT64 环境执行，不在日常播放器目录安装编译器。`publish` 是实际远端写入命令，日常自检不调用。

公开候选仍是播放器及配置，`release/manifest.json` 的 `components` 清单尚未填入公开分包。下方工具已支持本机快照的固定清单、安装和迁移；候选与组件整合的本机实测见下方日期记录，干净机器尚未验收，当前不能称为公开离线完整版。

转正式版前，使用最终下载的候选包和选定组件完成启动/媒体/菜单/切片/重置、每个提供的 VS 预设产帧及 shader 渲染、Whisper/Qwen 真实字幕/缓存/取消、路径迁移和干净机器验收。把硬件、版本、组件和未覆盖项记入 Release 说明，保留原始证据；之后在 GitHub 编辑该预发布，取消 Pre-release 并设置 Latest。流程不自动做此晋级。

2026-10-16 来源核对：官方 `v0.41.0` Windows MinGW 包可以通过本项目原生命令解析，但 `--vf=help` 没有 `vapoursynth`，不能作为当前全功能版的直接替换；外层 ZIP 还含一个内层 ZIP。构建结果以对应 Actions 运行及 Release 附件为准；本地脚本或离线回归通过不等于正式源码构建已通过。

依据：[mpv 正式发布](https://github.com/mpv-player/mpv/releases)、[官方 MSYS2 CI](https://github.com/mpv-player/mpv/blob/v0.41.0/ci/build-msys2.sh)、[GitHub 定时事件](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)。

## 组件安装与迁移

双击 `tools/components.cmd`，选择检查、安装或修复迁移路径。安装时选择可信离线包中的 `catalog.json`；也支持 HTTPS 清单。播放器目录必须已有 `mpv.exe` 与当前版本的 `portable_config`，工具不替换播放器或公共配置。命令行示例：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/components.ps1 -Action Status
powershell -NoProfile -ExecutionPolicy Bypass -File tools/components.ps1 -Action Install -Catalog X:/offline/catalog.json
powershell -NoProfile -ExecutionPolicy Bypass -File tools/components.ps1 -Action Configure -MpvRoot X:/moved-player
python tools/maintenance/components.py status --mpv-root X:/moved-player --hashes
# 从已安装且可运行的环境导出；输出目录须不存在，运行时与模型源保持原位
python tools/maintenance/components.py export --output X:/offline-components
# 把本机离线快照整理成适合 Release 的分卷；输出目录须不存在
python tools/maintenance/components.py prepare --catalog X:/offline-components/catalog.json --output X:/transport-components
# 以选定候选播放器适配已核对的 VS 共享依赖，并在暂存区执行原生探针
python tools/maintenance/components.py prepare --catalog X:/offline-components/catalog.json --output X:/candidate-components --vs-player X:/candidate/MPV
```

导出读取本机 `local.conf` 的后端/模型路径，以及配置的或 PATH 中的 FFmpeg/FFprobe，生成包含安装器、引导 Python 和四个分包的清单；私人配置、token、用户字幕缓存和 TRT 引擎缓存不在导出范围。Qwen 从原 venv 或已迁移环境取依赖，另配完整 Python、相对 `._pth` 和本地 VC++ 库；迁移包不保留原 venv 的绝对 Python 路径。导出可能占用数十 GB，须遵守各组件原许可；此入口不会自动发布资产。

`prepare` 验证原清单及整包哈希，将大包按默认 1900 MiB 分卷，保留单卷 Python 引导包，并附带当前安装器、`catalog.json` 和全部文件的 `SHA256SUMS`。可用 `--part-bytes` 调整卷大小，每卷必须小于 2 GiB，符合 [GitHub Release 单附件限制](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)。此命令只准备传输文件，不上传、不更新公开发行清单，也不代表来源许可或候选兼容性已验收；准备分卷不需要重新压缩模型。分发仅取校验表列出的文件及 `SHA256SUMS`，不打包安装测试生成的 `__pycache__` 或日志。

分卷安装须使用新包附带的安装器。保持目录结构，选择其中的 `catalog.json` 即可；HTTPS 清单也使用相同卷索引。工具先核对每卷大小与 SHA256，按清单顺序合并，再验证整包哈希，最后进入原有逐文件安装和原生探针；缺卷、坏卷、乱序、空间不足均失败。网络中断保留已校验的下载卷，重试可复用；未完成的合并文件保留作诊断，不会登记为已安装。除展开空间外，本地分卷需额外的整包缓存空间，HTTPS 安装还需存储下载卷；原始单包清单继续可用。

`--vs-player` 目前仅适配已核对的 `libffi-8.dll` 同名冲突：在独立暂存区验证原始 VS 包，改用指定候选自带的 DLL，通过 Python/ctypes/VS 基础帧探针后重新生成版本、整包与分卷哈希；元数据绑定候选 `mpv.exe` 及新旧 DLL 的 SHA256。其他共享文件发生内容冲突时中止，不猜测 ABI 兼容性。源快照与候选播放器均不改写；这一步额外需要 VS 展开与重打包空间，仍须对最终安装目录执行 GPU 预设与字幕实际验收。

安装按整包和逐文件 SHA256 验证，并在暂存区与最终目录执行原生探针。VS 只允许运行时目录和明确的根目录文件；Whisper/Qwen/媒体工具放在播放器的 `components/<组件>/<固定版本>/`。目标无需已有 Python：引导器从同一可信清单取固定哈希的小型 Python，此时检查也需提供清单。安装 Whisper/Qwen 自动补齐 FFmpeg/FFprobe；没有清单不安装组件，不猜测最新版或自动下载大模型。

安装 VS 或执行迁移修复时，会在播放器根目录生成 `mpv-components.cmd`。r2 候选需从该入口启动，以便在任何工作目录都按播放器位置设置 `VSSCRIPT_PATH` 并动态启用 VS；环境只传给本次播放器进程及其子进程，不写系统设置。启动器使用相对自身的路径，整体移动后仍可定位 DLL；已有不同内容的同名启动器会中止安装并保留用户文件，缺失时可运行迁移修复重新生成。

在选定的独立播放器配置目录中，可从安装后的启动器验证实际 GPU 入口；完整序列会初始化重型预设，冷缓存可能长时间编译：

```powershell
python tools/tests/test_gpu_ux.py --case playback --paused --source-width 640 --cold-shader-cache --timeout 1800 --launcher ../mpv-components.cmd
```

同内容文件复用，不同内容文件拒绝覆盖；这也可能阻止与发行播放器自带 DLL 冲突的 VS 快照安装，需先选择匹配运行时。单个组件提交失败只回滚该组件本轮新建文件，已成功安装的其他组件保留，失败暂存留作诊断。安装记录位于 `state/components/`，路径只写忽略的 `local.conf`，原配置先备份，私人接口设置保留。整体移动播放器目录后运行“修复迁移路径”，按记录重新定位并探测组件。不要在安装期间启动播放器；中断遗留的锁应先核查对应进程和暂存，再处理。

检查项确认 VS 实际基础帧、Qwen 本地导入/CUDA、Whisper CLI/本地模型和媒体工具；Whisper 探针不执行推理，模型/原生探针通过也不代替 GPU 预设与字幕实际验收。Qwen 的 DyNet 依赖不支持中文导入目录，工具与识别适配器会使用 Windows 的 ASCII 短路径；若目标卷禁用短文件名且路径含非 ASCII 字符，须选择英文运行时目录，工具会明确报错。当前本机快照面向 Windows x64 / NVIDIA，其他系统、GPU、驱动、干净机器和公开候选的兼容性需另验。原始证据保存在忽略的 `cache/component-audit/`。

2026-10-19 本机组件验收：RTX 4070 Laptop 8GB / 驱动 616.92，独立播放器先在没有 Python 的目录中通过引导器安装 VS，再安装媒体工具、Whisper 和 Qwen；离线分包约 19.3 GiB，展开约 24.4 GiB。整套播放器移到含中文和空格的新路径后，修复路径并逐文件复核 45,954 个负载文件的哈希通过，Qwen 确认使用包内独立 Python 3.12.12 / Torch 2.8.0+cu128。最终 PowerShell 检查入口四组件均 READY。

迁移目录中 Bilateral / RIFE TRT 各输出 3 张有效 PNG；Whisper 分段识别、取消、下一文件、缓存复用与 Qwen 菜单切换识别均通过，另补测显式离线模型目录。三组字幕回归均正常退出、无遗留后端进程，截图已目视检查；两种 VS 的采样输入为 640×360/30fps 合成图，字幕使用已知英文合成语音，不作为真实课程准确率或稳定性能结论。摘要为 `cache/component-audit/migration.json`、`whisper-model-dir.json`、`moved-status.json`，原始报告/日志/截图已复制到其 `evidence/` 子目录。15 项组件离线回归、11 项 Qwen 适配回归通过；CI 接入尚待远端执行。

2026-10-21 候选整合实测：同机 RTX 4070 Laptop 8GB / 驱动 616.92，以缓存公开 r2 ZIP 的原生文件和配置基线 `b3f13be` 建立含中文、空格路径的独立目录。VS 仅将 `libffi-8.dll` 适配为候选版本，原快照保留；14 个负载附件最大 1900 MiB，最终交付校验表的 21 个文件全部通过。无初始 Python 的引导安装、四组件探针、45,954 个负载文件 SHA256 通过；候选的 316 个原生文件仍与公开 ZIP 一致。

该目录完成 Bilateral/RIFE 各 3 张有效帧、105 项菜单断言、Whisper 分段识别与 Qwen 菜单切换识别；两个后端各完成两次识别与两次缓存复用，覆盖取消、切片和正常退出。完整 RTX GPU 冷 shader 缓存序列通过 38 步及 18 张有效画面，覆盖全部 RTX 菜单预设、暂停跳转、对比、重置与下一文件；清除父进程的 `VSSCRIPT_PATH` 后，经 `mpv-components.cmd` 从配置工作目录复跑同序列也通过。两次 GPU 退出码均为 0，无错误/致命日志，重型预设与字幕截图已目视检查。启动器另测相对媒体路径、中文/空格/与号参数、GUI 默认、失败退出，以及缺失后的路径修复和私人配置保留。

上述 GPU 输入为 640×360/30fps 合成图，字幕为已知英文合成语音；结果不代表真实课程准确率、4K 性能、DML/HDR、其他硬件或干净机器通过。31 项组件回归、20 项发行回归通过，另 1 项发行回归跳过；Actions 尚未远端执行。证据位于忽略的 `cache/component-transport-20261021/`，整合摘要为 `compatible-report.json`，GPU 与真实启动器报告为 `gpu-sequence.json`、`launcher-gpu-sequence.json`。

公开分发仍有来源材料缺口：媒体快照仅含 FFmpeg/FFprobe，未附许可/源码材料；VS、Whisper、Qwen 的二进制、模型和依赖尚缺完整上游来源记录。清点见同目录 `contents-inventory.json`。兼容适配和分卷校验不构成再分发许可确认，补齐材料及干净机器验收后再接入公开清单。

## 菜单与设置保留回归

`python tools/tests/test_menu_ui.py --full` 加载日常脚本，经真实导航/回车检查菜单、状态、切片与恢复；隔离历史及 IPC，禁用测试网络弹幕。进程失败、错误级日志、缺少报告或截图均判失败。

“工具与高级 → 所有快捷键…”由本地 `keybinds-menu.lua` 通过 uosc 的公开覆盖接口显示中文说明与实际键位；复用 `input.conf` 的菜单/普通注释及 InputEvent 配置的 `#desc:`，按原生优先级过滤被覆盖绑定并保留字母大小写。支持中文或键位搜索，普通条目可点击执行；单击、长按、双击、松开等 InputEvent 条目仅说明按键用法，不单独执行手势命令。`python tools/tests/test_keybinds_menu.py` 加载完整配置，使用自生成的本地 Y4M 视频检查描述覆盖、搜索截图、菜单入口、命令执行、空格与右方向键的长按/恢复及切换文件；无需外部 FFmpeg。2026-10-22 完整配置 / D3D11 下 251 条描述、38 项检查通过，进程正常退出且无错误级日志，证据 `cache/keybinds-menu/20261022-120925/report.json`。此测试和主菜单回归仅在测试进程禁用物理鼠标移动输入，避免鼠标导航干扰程序选项定位；日常配置不变。

`panel-manager.lua` 协调文件浏览器（Tab 单击）、历史（反引号）、书签（N）、uosc 菜单和命令控制台（~）：快捷键切换先等待旧面板关闭、释放按键及结束菜单淡出，再打开新面板。鼠标或其他脚本直接打开受支持面板时，通过打开状态通知关闭其他面板；这条兜底路径可能有短暂过渡，不能保证同一渲染帧内完成。Tab 长按仍只临时切换播放控件。

`i` 显示临时统计（默认 4 秒），打开面板即取消；`I` 开关常驻统计，面板打开时暂停、全部关闭后恢复。统计通过内置 toggle 接口运行，由协调脚本管理临时计时，避免仅清掉文字后统计又刷新出来；计时可用 `panel-manager-stats_duration` 脚本选项调整。统计第 4 页自带的搜索框仍与统计一起显示，控制台和历史搜索中的输入不会被全局快捷键抢走。当前播放器的命令入口使用 [`commands/open`](https://github.com/mpv-player/mpv/blob/02a595ddc/player/lua/commands.lua)，不再依赖旧的 `console/enable`。

历史与书签增加 `close-list` 消息，关闭搜索时先清搜索状态再解除绑定，避免 Esc、Ctrl+F、Alt+Enter 等残留；文件浏览器增加 `close-browser` 消息，完整退出多选而非只取消选择。uosc 另发布菜单实际打开时间，与历史/书签/浏览器的打开时间一起解决状态通知合并时旧面板误关新面板的竞态。以上四个上游组件含本地集成改动，更新时应保留或重新适配。新增其他面板需要登记其打开状态和真实关闭接口，不能仅靠调整显示层级。

`python tools/tests/test_panel_manager.py --full` 使用隔离的历史/书签和两个合成视频，检查真实按键、面板互斥、搜索与多选释放、统计恢复、快速切换、控制台补全、下一文件和干净退出，并保存四类面板截图；另外检查统计页搜索、控制台补全后主菜单左栏文字像素是否仍存在。2026-10-22 本机完整配置 / D3D11 回归：`cache/panel-manager/20261022-120854-full/report.json`，50 项检查通过、退出码 0、错误级日志为空；未加载协调脚本的对照在“历史和文件浏览器互斥”检查失败，复现两者同时打开。合成视频只用于界面验收，不代表真实片源画质或性能结论。同一版本的主菜单回归为 `cache/menu-rework/20261022-120804-full/report.json`，106 项断言通过。

默认连续切换文件时沿用音量与倍速，色彩、画面、音轨、字幕和滤镜相关项目继续按常用列表重置；此规则适用于同一播放器内的连续切片，不按合集区分。下一文件有自己的 watch-later 历史时，仍优先恢复该文件保存的音量与倍速。

`CTRL+R` 或菜单“工具与高级 → 播放设置 → 下一文件的设置保留策略”中的“保留全部更改”使用空重置列表。`no` 不是可重置选项名，会在切片时报错，不能作为关闭值。快捷键轮换与菜单的“常用项目（配置默认）”使用同一重置列表，立即恢复操作独立于保留策略。[mpv 选项说明](https://mpv.io/manual/master/#options-reset-on-next-file)。

本机原生回归确认：切换策略不会修改当前速度；当前文件加载时已登记的重置项可能在第一次切片恢复一次，之后加载的文件按空列表保留更改。此策略也不覆盖自动 profile、专用脚本重置或 watch-later 恢复。菜单与快捷键遵循同一原生行为。2026-10-16 本机完整回归：`cache/menu-rework/20261016-154313-full/report.json`，52 步/105 项断言通过，错误级与致命日志均为空。

## 上游脚本与着色器维护

`M` 或菜单“工具与高级 → 维护 → 检查脚本与着色器更新”先获取 `manager.json` 指定的源并预览，选择“应用安全更新并备份”才修改目标。获取失败会中止整个预览，不使用旧下载结果。源仓库仅位于忽略的 `cache/manager/sources/`，不在脚本目录创建 Git 仓库或修改项目远端。

- 首次遇到与上游不同的现有文件，或文件与上次安装的上游基线不同，均标为“本地差异，保留”。已提交的本地定制同样受保护；不会以 Git 工作区干净为由覆盖。
- 与上游完全相同的文件会在应用时建立基线；以后仅自动更新仍与该基线一致的文件。没有基线的差异需人工比较合并，工具不提供强制覆盖。
- 应用前及逐文件写入前再次核对预览快照。先暂存全部内容并备份原文件，安装失败时尝试恢复本次已改文件；任何恢复失败会明确报错。
- 备份在 `cache/manager/backups/`，`manifest.json` 对应目标、状态及原始 `.old` 文件。手动恢复前先退出播放器；备份不自动清理、不随发布包分发。
- 更新后重启播放器。预览/取消入口分别为 `script-message-to manager manager-update-all`、`script-message-to manager manager-cancel`；应用入口为 `script-message-to manager manager-apply`，必须先在当前进程预览。

本地维护实现为 `scripts/manager.lua` 与 `script-modules/managed-update.lua`；更新其他脚本时保留这些修改。隔离本地 Git 源的回归：`python tools/tests/test_manager.py`，不下载上游也不更新日常配置。

## 统一诊断与播放采样

菜单“工具与高级 → 维护 → 诊断与播放性能…”可检查当前配置与可选组件，或采样当前播放。结果仅写入忽略的 `cache/player-health/`；菜单提供打开报告目录。不会自动安装、更新依赖或修改播放参数。

诊断分别记录配置原生接线、VS Bilateral 依赖、Qwen Python/CUDA 导入、FFmpeg、NVIDIA 驱动，以及运行时/字幕模型配置文件是否存在。任务“已完成”表示报告已生成，每个检查项的 `ok` 决定是否通过；文件存在、导入成功不等于实际产帧或识别成功。路径采用当前进程的本机配置，不导出全部选项或私人 token。诊断不会加载 Qwen 模型，也不运行 Whisper 推理。

播放采样默认预热 2 秒后测量 30 秒，可在 `script-opts/player-health.conf` 调整。报告记录媒体规格、增强/滤镜、解码后端、窗口、媒体时间推进比、掉帧增量、VO pass 滚动平均耗时的 P50/P95/最大值和可用的 NVIDIA 整卡显存/利用率。VO 耗时不覆盖完整 VS/解码流水线，不能换算成滤镜 FPS；整卡显存包含其他程序。暂停、切片、跳转、更改滤镜/窗口/播放参数或取消都会使本次报告无效；缺少有效 VO 耗时也不能作为基线。预热不计首次编译时间。

同条件的独立采样工具：

```powershell
# 合成片源冒烟回归；不是实际影片性能结论
python tools/tests/benchmark_playback.py --height 720 --seconds 5
python tools/tests/benchmark_playback.py --height 1080 --seconds 5
python tools/tests/benchmark_playback.py --height 2160 --seconds 5
# 用户指定真实片源后，同一片段分别测默认配置与明确指定的增强
python tools/tests/benchmark_playback.py --media 'X:/media/sample.mkv' --start 60 --seconds 30
python tools/tests/benchmark_playback.py --media 'X:/media/sample.mkv' --start 60 --seconds 30 --preset NR_BILATERAL_CUDA
python tools/tests/test_player_health.py
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
