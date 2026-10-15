# GPU 使用与部署

本配置面向 Windows NVIDIA RTX，按需开启增强。核心滤镜在 GPU 运行，VS 格式转换与调度仍可能使用 CPU。预设、模型和键位的完整对应见 [vs/README.md](../vs/README.md)。

## 日常操作

将配置放在 `mpv.exe` 同级的 `portable_config/`，使用支持 `gpu-next` 的 64 位 mpv。uosc 主菜单 → **画质增强 → GPU 增强**，按轻量超分、补帧、降噪、超分与组合分组：

| 用途 | 入口 |
| --- | --- |
| SDR 动画轻量超分 | ArtCNN C4F16 `CTRL+ALT+1`；C4F32 `CTRL+ALT+2` |
| 补帧 | RIFE TRT `$`；DRBA TRT `%` |
| 降噪 | Bilateral CUDA `!`；DFTTest CUDA `+`；BM3D CUDA `'` |
| 超分与组合 | 菜单选择；具体模型和键位见 VS 表 |

- 一次管理一个增强，选另一项替换，重复选择关闭；超分加补帧使用既有 MIX 预设。
- shader 随配置提供，不需要 Python/VS；目标宽高均超过源尺寸 1.3 倍才触发，原尺寸显示可能没有变化。VS 则需要外部运行时、插件和模型。
- **关闭本菜单增强** 只撤销此入口的 VS 标签，并在 shader 列表未被外部改写时恢复开启前列表，保留其他滤镜；`ALT+~` 清空全部视频滤镜，`CTRL+0` 清空全部 shader。
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
```

播放测试只加载 uosc、GPU 脚本和输入绑定，日志/截图在 `cache/gpu-ux/`；默认 1280×720/30fps，不覆盖全部日常脚本。640×360 暂停长序列的已知失败和当前未提交验收见 [项目状态](../PROJECT_STATE.md)。

导出产物在 `cache/packages/`：基础配置 ZIP、`mpv-VS-RTX-addon.7z` 与 SHA256。需要 Git/7-Zip；配置排除私人文件/缓存，VS 包不含配置和引擎缓存。它是本机组件快照，使用前核对附带 SHA256 与上游许可；旧包不自动包含后续代码修改。

## 控制接口

脚本 `scripts/gpu-effects.lua` 的标识为 `gpu_effects`，消息为 `menu`、`toggle <预设ID>`、`reset`、`clear-vf`、`clear-shaders`、`help`；状态属性 `user-data/gpu-effects`，VS 标签 `gpu-effects` 不供其他脚本复用。

选项读取标识 `gpu-effects`，文件 `script-opts/gpu-effects.conf`；探针超时默认 20 秒、初始化 300 秒。机器路径在忽略的 `local.conf` 用 `script-opts-append=gpu-effects-runtime_path=...` 覆盖。只读 AST 探针不运行预设；动态依赖仍由初始化判断。

`vf add` 返回成功及 `video-reconfig` 都可能早于实际 VS 初始化；脚本等待明确完成日志后才确认应用，之后监听错误。不同 mpv 版本缺少完成信号会超时回滚。shader “已选择”仅表示列表设置成功，实际渲染以画面/自检为准。

## 历史验证边界

继承 2026-10-14 的记录，提交 `3bc9548`、`fb42716`：RTX 4070 Laptop 8188MiB、驱动 616.92、mpv `v0.41.0-1017-g02a595ddc`、Python 3.14.4、VS R73、k7sfunc 1.8.1。

- 12 个 RTX VS 各产出三张 PNG，两个 shader 经 640×360 → 1280×720 D3D11 渲染通过；报告分别在 `cache/gpu-check/20261014-124711-950574/`、`cache/gpu-check/20261014-125424-755735/`。
- 5 项自检故障回归通过。增强包完整性与独立目录 Bilateral/RIFE 迁移产帧通过；报告在 `cache/gpu-check/20261014-130129-942624/`、`cache/gpu-check/20261014-130133-369582/`。
- 无 VS 基础目录的 C4F16 渲染通过，临时副本已清理；该副本报告不再保留。三个 DML、其他硬件、HDR、长时播放、主观画质和真实片源实时帧率未验证。

本次文档精简没有重跑上述测试。证据缓存不随仓库分发，接手时核对文件或重跑；不能仅凭这份摘要宣布新环境通过。
