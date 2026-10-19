# GPU 使用与部署

本配置面向 Windows NVIDIA RTX，按需开启增强。核心滤镜在 GPU 运行，VS 格式转换与调度仍可能使用 CPU。预设、模型和键位的完整对应见 [vs/README.md](../vs/README.md)。

## 日常操作

将配置放在 `mpv.exe` 同级的 `portable_config/`，使用支持 `gpu-next` 的 64 位 mpv。uosc 主菜单 → **画质增强 → 画面增强**：先按需求选（放大后更清楚 / 动作更流畅 / 减少噪点 / 修复动画画面 / 去色带 / 超分＋补帧），再按片源类型给少量方案；模型名、后端与单项 shader 在“高级”里。

| 用途 | 入口 |
| --- | --- |
| 动画轻量超分 | 画面增强 > 放大后更清楚 > 动画 > 省资源/增强（`CTRL+ALT+1` / `2`） |
| 动画/真人 2× 超分 | 画面增强 > 放大后更清楚 > 更多模型与风格 / 真人：AnimeJaNai、ArtCNN、HFA2k（`*`、`ALT+^`、`&`、`ALT+&`、`(`） |
| 补帧 | 画面增强 > 动作更流畅：RIFE `$`、DRBA `%`、DML 对照 `@`、`SHARP` |
| 降噪 | 画面增强 > 减少噪点：轻度 `!`、中等 `+`、强 `'` |
| 动画修复（不放大） | 画面增强 > 修复动画画面（`)`） |
| 超分＋补帧 | 画面增强 > 超分＋补帧（`ALT+_`） |

- 一次管理一个增强，选另一项替换，重复选择关闭；超分加补帧使用既有 MIX 预设。
- 每个方案在选择前先进入详情页：**适合 / 条件 / 负担 / 启用此方案**，技术详情（模型 · 后端 · 是否需要 VS · 键位）再进一层；启用后 OSD 重复同样四件事，方便随时判断要不要继续。
- **暂时关闭，对比效果**：保留当前选择，只在本次播放里切回开启前的画面，可再切回（对比中切换方案会先结束旧对比，再按新方案生效）；**恢复开启前效果**：撤销本次增强并恢复开启前的滤镜与 shader（不清空其他调参）。
- **去色带**是 mpv 内置的独立开关，菜单里显示当前开/关状态；它不受“暂时关闭，对比效果”“恢复开启前效果”和跨文件重置影响，恢复范围只针对本菜单管理的增强。
- 状态会提前说明：缺组件、正在准备（尚未生效，可再次点击取消）、估算倍率未达触发范围、流畅度尚未评估、HDR 片源尚未验证都由菜单提示，不需要用户自己猜。
- 倍率是**估算值**：取“滤镜输出尺寸 → 渲染目标尺寸”里较小的一侧，着色器要求宽高同时超过阈值（ArtCNN 为 1.3 倍）；黑边、滤镜阶段与实际触发条件仍可能有偏差，界面不会据此断言已触发或未触发。
- shader 随配置提供，不需要 Python/VS；VS 则需要外部运行时、插件和模型。VS 首次初始化完成前禁止对比，避免把正在准备的滤镜当成对比对象。
- **恢复开启前效果** 只撤销此入口的 VS 标签，并在 shader 列表未被外部改写时恢复开启前列表，保留其他滤镜；`ALT+~` 清空全部视频滤镜，`CTRL+0` 清空全部 shader。
- 下一文件撤销临时增强，独立于全局 `CTRL+R` 重置模式；watch-later 不保存滤镜/shader 链。
- shader 开启前的列表在关闭时恢复；若其他入口已改列表，放弃旧列表恢复权，避免覆盖新选择。
- 缺依赖项仍可点击查看原因。VS 初始化失败、超时或换文件会取消/回滚；后续帧失败关闭该增强。首次 TRT 引擎构建或 shader 编译可能较慢。

既有 VS 超分常用 `H_Pre=720`、`H_Max=1440`，可能先降采样再处理；模型 2× 不等于原片最终尺寸 2×。保留个人调参，比较同片段原始输出与单项增强；菜单分组不代表画质或实时速度排名。

## 安装可选 VS

仅复制配置不能获得 VS。优先复用匹配的整套便携运行时；上游入口：[mpv_PlayKit Releases](https://github.com/hooke007/mpv_PlayKit/releases) 的 NVIDIA `vsNV` 组件、[便携 Python/VS](https://github.com/hooke007/dotfiles/releases/tag/mpv_addones)、[部署说明](https://github.com/hooke007/mpv_PlayKit/wiki/3_K7sfunc)。发行资产以该页为准。

已有本机增强包：解压到 `mpv.exe` 同级，不多套一层目录。上游包：先完整解压到独立临时目录，再双击 `tools/install-vs-runtime.cmd` 导入；工具只复制运行时，不覆盖上游/本项目配置，已有 VS 的目标目录会拒绝混装。预览：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/install-vs-runtime.ps1 -Source 'C:\Downloads\vsNV-extracted' -WhatIf
```

关键布局（部署包其余 DLL、pyd、zip、配置也必须保留）：

```text
mpv/
  mpv.exe, python.exe, VSScript.dll, portable.vs
  Lib/site-packages/k7sfunc/
  vs-coreplugins/
  vs-plugins/
    vstrt.dll, akarin.dll, vsmlrt-cuda/
    bilateralgpu_rtc.dll, dfttest2_nvrtc.dll, bm3dcuda_rtc.dll
    models/ArtCNN/, models/rife/, models/drba/
    models/<自定义 UAI 模型>.onnx
  portable_config/
```

基础 Python/VS 包不等于 GPU 全依赖；按需部署还需 k7sfunc、[vs-mlrt](https://github.com/AmusementClub/vs-mlrt)、插件与模型。本机历史验证 k7sfunc 1.8.1，完整包已有匹配依赖时不要直接全量升级。ArtCNN 放 `models/ArtCNN/`，自定义 UAI 放 `models/` 根部。导入成功只证明可导入，不证明能产帧。

双显卡机器确认 mpv 使用高性能 GPU；驱动须满足所选 CUDA/TRT 包要求。换机器迁移 ONNX，不迁移 `.engine` 缓存；新环境首次构建后再评估性能。

## 自检与导出

在配置根目录执行：

```powershell
# 导入检查与预设清单
powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify-gpu.ps1
# RTX VS 与 shader 实际输出
powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify-gpu.ps1 -Run
# 首次构建慢时提高单项超时
powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify-gpu.ps1 -Run -Kind vs -Preset MEMC_RIFE_TRT -Timeout 600
# 导出基础配置 / 本机可选 VS 包
powershell -NoProfile -ExecutionPolicy Bypass -File tools/export-config.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools/export-vs-addon.ps1
```

双击 `tools/verify-gpu.cmd` 做运行自检；`-MpvRoot` 可指定另一播放器目录。工具需要 Python，但 shader 播放本身不需要。VS 要求进程成功、日志有效、无已知错误并至少输出三张有效 PNG；shader 使用 gpu-next 2× 窗口截图和 ArtCNN hook 日志。失败、缺输出、超时均返回非零，报告在 `cache/gpu-check/`。耗时含初始化/编译/截图，不能当稳定帧率。

检查隔离播放器配置，功能验收还需菜单/键位、下一文件和恢复默认。控制状态回归用 `tools/test_gpu_effects.lua`，探针用 `tools/test_gpu_probe.py`；播放测试：

```powershell
..\mpv.com --no-config --load-scripts=no --script=tools/test_gpu_effects.lua --idle=yes --vo=null --ao=null --osc=no
..\python.exe tools/test_gpu_probe.py
..\python.exe tools/test_gpu_ux.py --case playback
..\python.exe tools/test_gpu_ux.py --case playback --paused
..\python.exe tools/test_gpu_ux.py --case no-vs
..\python.exe tools/test_gpu_ux.py --case failure
# 使用独立空缓存验证首次 shader 编译；保留日常缓存
python tools/test_gpu_ux.py --case playback --paused --source-width 640 --cold-shader-cache --timeout 1800
# 复用上一轮报告中的缓存验证普通播放（替换为实际报告目录）
python tools/test_gpu_ux.py --case playback --source-width 640 --shader-cache-dir 'cache/gpu-ux/<上一轮报告目录>/shader-cache'
```

播放测试只加载 uosc、GPU 脚本和输入绑定，日志/截图在 `cache/gpu-ux/`；默认 1280×720/30fps，不覆盖全部日常脚本。小尺寸暂停切换回归：`python tools/test_gpu_ux.py --case playback --paused --source-width 640 --focused`；覆盖 RIFE、DRBA、两种 ArtCNN、MIX、用户滤镜保留与下一文件，不等待 shader 编译。去掉 `--paused` 比较普通播放。全序列中的暂停测试还覆盖 MIX 激活后的 seek，并核对每次截图时仍处于暂停状态。

测试不以 PNG 文件存在代替有效画面：解码 RGB/RGBA 8/16 位 PNG 的前 32 行，检查合成测试图应有的彩色像素，拒绝 VS 初始化占位黑帧；该规则只用于此处无黑边的 `testsrc2`，不用于判断真实影片的黑场。首次 shader 编译可能远超普通切换耗时，可用 `--timeout` 增加原生进程的总时限；VS 单项初始化时限仍由 GPU 脚本独立管理。`--cold-shader-cache` 仅让 mpv shader 缓存为空，不清除驱动或 TRT 引擎缓存；`--shader-cache-dir` 用于显式复用缓存，二者互斥。

导出产物在 `cache/packages/`：基础配置 ZIP、`mpv-VS-RTX-addon.7z` 与 SHA256。需要 Git/7-Zip；配置排除私人文件/缓存，VS 包不含配置和引擎缓存。它是本机组件快照，使用前核对附带 SHA256 与上游许可；旧包不自动包含后续代码修改。

## 控制接口

脚本 `scripts/gpu-effects.lua` 的标识为 `gpu_effects`，消息为 `menu`、`toggle <预设ID>`、`compare`、`reset`、`clear-vf`、`clear-shaders`、`help`；状态属性 `user-data/gpu-effects`（`active` / `pending` / `compare` / `message`），VS 标签 `gpu-effects` 不供其他脚本复用。

选项读取标识 `gpu-effects`，文件 `script-opts/gpu-effects.conf`；探针超时默认 20 秒、初始化 300 秒。机器路径在忽略的 `local.conf` 用 `script-opts-append=gpu-effects-runtime_path=...` 覆盖。只读 AST 探针不运行预设；动态依赖仍由初始化判断。

`vf add` 返回成功及 `video-reconfig` 都可能早于实际 VS 初始化；脚本等待明确完成日志后才确认应用，之后监听错误。不同 mpv 版本缺少完成信号会超时回滚。shader 提示“已启用”仅表示列表设置成功，实际渲染以画面/自检为准。

暂停时，mpv 的 VS 接口可能在初始化期间显示零时长黑色占位帧。GPU 脚本在检测到该占位帧并确认初始化结束后补取一帧，保持暂停；也处理已启用 VS 的暂停 seek。取消、重置、换文件或换方案会使旧刷新失效，执行前还会核对仍处于暂停状态。此处读取暂停期间的 VS 初始化日志，普通播放不持续订阅 debug 消息。

## 历史验证边界

2026-10-19 本机 RTX 4070 Laptop 8GB / 驱动 616.92 / mpv `v0.41.0-1017-g02a595ddc`：640×360/30fps 合成测试图、1280×720 窗口、D3D11、只加载 uosc/GPU 控制器/测试脚本，完成 12 个 RTX VS 与两个 ArtCNN shader 的完整序列：

- 首轮旧工具仅检查 PNG 格式和大小，误将 MIX 暂停黑帧判为通过，原报告 `cache/gpu-ux/20261019-132029-playback-paused-640/` 不计验收。日志显示 VS 初始化返回零时长占位黑帧；单纯等待和同位置 seek 仍黑，补取一帧恢复，原始对照在 `cache/gpu-mix-paused-probe/`。本轮控制器修复和 PNG 内容检查见上方机制说明。
- 最终版本使用独立空 mpv shader 缓存，暂停全序列通过 38 步，18 张预期截图均有彩色测试图，覆盖启用/替换/对比恢复/重置、用户滤镜保留、暂停 seek 及 VS/shader 下一文件；所有截图核对暂停状态，退出码 0、无错误级日志。目录 `cache/gpu-ux/20261019-134845-playback-paused-640/`，MIX seek 后截图已目视检查。
- 同缓存普通播放全序列通过 37 步、17 张有效截图，退出码 0、无错误级日志，目录 `cache/gpu-ux/20261019-140509-playback-640/`。暂停故障注入通过 10 步、7 张有效截图，覆盖初始化失败和缺模型时保留原 shader/VS；目录 `cache/gpu-ux/20261019-140600-failure-paused-640/`，其中故意触发的 VS 异常为预期日志。
- 冷缓存暂停流程至通过日志约 967.6 秒；C4F16 / C4F32 的截图及重置步骤分别等待 119.3 / 801.8 秒。普通播放复用缓存流程约 47.5 秒，步骤与暂停测试不同；这些耗时含编译、初始化、截图及固定等待，不是稳定帧率。未清空驱动/TRT 缓存。
- 新增占位帧回归在旧控制器上失败，修复后 66 项 Lua 断言、8 项探针检查及 8 项验证器测试通过；PNG 回归覆盖彩色图、16 位 RGBA 黑帧、损坏和截断。未覆盖 DML、HDR、其他硬件、长时稳定性、主观画质及候选发行包。

2026-10-17 UAI 类预设小尺寸修复：k7sfunc 动态 UAI 引擎的 `min_shapes=[384,384]` 在 640×360 源上会报 `no valid optimization profile found`（`k7sfunc/mod_mix.py` 的 `UAI_NV_TRT`）；`SR_AnimeJaNaiV2_TRT`、`SR_AnimeJaNaiV3_TRT`、`SR_HFA2k_TRT`、`SR_Anime1080Fixer_TRT` 改为任一边小于 384 像素时改用静态 TRT 引擎后，四个预设在 640 源、V2 另在 1280 源各实际输出三张 PNG（报告 `cache/gpu-check/20261017-081119-513318` 至 `20261017-081500-991172`，新引擎落在 `vs-plugins/models/`）。本次未重跑完整长序列、主观画质与实时性能。

2026-10-16 小尺寸修复验收：RTX 4070 Laptop 8GB、既有运行时；普通 ArtCNN、Chroma、MIX 在 640×360 与 1280×720 各实际输出三张 PNG（`cache/gpu-check/20261016-152239-933577/` 至 `20261016-152247-552142/` 的六份报告）。RIFE → DRBA → ArtCNN → Chroma → MIX 的重置/用户滤镜保留/下一文件回归通过：640×360 暂停 `cache/gpu-ux/20261016-151908-playback-paused-focused-640/`、普通播放 `20261016-152249-playback-focused-640/`、1280×720 暂停 `20261016-152308-playback-paused-focused-1280/`。这些不等同长时稳定性或实时速度测试。

原 2026-10-14 长序列被误记为 DRBA 失败；原日志显示 DRBA 已初始化并截图，真正形状错误在后续普通 ArtCNN。小于动态引擎最小形状时现使用静态引擎，见 VS 说明。

继承 2026-10-14 的记录，提交 `3bc9548`、`fb42716`：RTX 4070 Laptop 8188MiB、驱动 616.92、mpv `v0.41.0-1017-g02a595ddc`、Python 3.14.4、VS R73、k7sfunc 1.8.1。

- 12 个 RTX VS 各产出三张 PNG，两个 shader 经 640×360 → 1280×720 D3D11 渲染通过；报告分别在 `cache/gpu-check/20261014-124711-950574/`、`cache/gpu-check/20261014-125424-755735/`。
- 5 项自检故障回归通过。增强包完整性与独立目录 Bilateral/RIFE 迁移产帧通过；报告在 `cache/gpu-check/20261014-130129-942624/`、`cache/gpu-check/20261014-130133-369582/`。
- 无 VS 基础目录的 C4F16 渲染通过，临时副本已清理；该副本报告不再保留。三个 DML、其他硬件、HDR、长时播放、主观画质和真实片源实时帧率未验证。

历史记录不代替新环境实测。证据缓存不随仓库分发，接手时核对文件或重跑；不能仅凭这份摘要宣布新环境通过。
