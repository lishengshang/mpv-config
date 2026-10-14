# GPU 验证记录：2026-10-14

验证时为代码基线 `b506dbb` 上的 `dev` 工作区修改；任务 `VS-001`。对应实现现已分类提交到 `3bc9548`、`fb42716`，本页保存当时实际结果，未因提交操作重复 GPU 测试。验证环境：Windows x64、RTX 4070 Laptop 8188MiB、驱动 616.92、mpv v0.41.0-1017-g02a595ddc、Python 3.14.4、VS R73、k7sfunc 1.8.1。

## 运行结果

- `tools/verify_gpu.py --run --kind vs`：12 个 TRT/CUDA 预设全部通过，每项实际输出三张 PNG。包含新增 Bilateral/DFTTest；原有三个 DML 预设未重测。
- `--run --kind shader`：C4F16/C4F32 均通过 640×360 → 1280×720 的 gpu-next/D3D11 渲染截图，日志确认 NVIDIA 设备与 ArtCNN hook。首次/无持久 shader 缓存的检查耗时约 36s/258s，含编译与截图，不能解释为稳定播放帧率。
- 实际配置回归：`!`、`+` 开关、两种 shader 替换不叠加、`CTRL+0` 清空、下一文件 VS 重置、`ALT+~` 清空通过。回归仅禁用其他用户脚本，不覆盖与所有脚本强制绑定的组合。
- `tools/test_verify_gpu.py`：5 项通过，包括真实故障 `.vpy` 和真实超时终止；退出码为零但无日志/输出的情况不判通过。
- 上游导入工具：PowerShell 语法检查、`-WhatIf` 清单、同目录/嵌套目录拒绝通过；没有执行对原播放器的覆盖导入。新环境可直接使用已导出的增强包。
- 增强包：7-Zip 完整性检查通过，未包含 `.engine*`、`local.conf` 或 `portable_config`。约 3.23GiB，SHA256 `94245F1503D0B56FE5AF781BBE7A1316E17A2AF4A6251FA7AFC0DFC22518D388`。
- 迁移复现：将增强包解压到独立空目录，复制 mpv 二进制；使用该目录的 Python/VS/插件执行 Bilateral CUDA 与 RIFE TRT，均实际输出三帧。RIFE 在不迁移引擎缓存的情况下重新初始化通过。
- 基础包：ZIP 完整性与无私人配置/缓存检查通过；解压到仅有 mpv 二进制的目录，没有 Python/VS 运行时时，C4F16 shader 经实际 GPU 截图通过。检查程序由本机已有 Python 执行，但该测试 mpv 目录没有 VS；shader 播放不依赖 Python。

本轮未验证真实新电脑、其他 RTX 型号、长时播放、HDR、视觉质量排序或各分辨率稳定帧率；不能将合成测试源的通过当成这些保证。

## 可重复执行

在 `portable_config` 下：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify-gpu.ps1 -Run
..\python.exe tools/test_verify_gpu.py
..\mpv.com --config-dir=. --load-scripts=no --script=tools/test-gpu-bindings.lua --vo=null --ao=null --pause=yes --idle=yes --save-position-on-quit=no --resume-playback=no --log-file=cache/gpu-keybind-test.log "av://lavfi:testsrc2=size=1280x720:rate=30,format=yuv420p"
git diff --check
```

故障检查用于验证测试工具会拒绝失败，预期错误由测试断言处理。快捷键回归依赖已部署的 GPU 运行时；初始化很慢时固定等待可能不足，超时结果需看日志，不能直接认定绑定错误。

## 本机原始证据

- VS 12 项：`cache/gpu-check/20261014-124711-950574/report.json`。
- shader 2 项：`cache/gpu-check/20261014-125424-755735/report.json`。
- 迁移 Bilateral：`cache/gpu-check/20261014-130129-942624/report.json`。
- 迁移 RIFE：`cache/gpu-check/20261014-130133-369582/report.json`。
- 配置回归：`cache/gpu-keybind-test.log`。
- 临时运行时：原 `cache/vs-migration/`，此前自动审批拒绝清理；用户随后授权整理目录，`CLEAN-001` 已核对路径并成功清理。产帧报告与截图保留。
- 无 VS 基础目录：原 `cache/base-no-vs/`，`CLEAN-001` 已清理；该目录内的 shader 额外验证报告随副本移除，本页摘要与主 shader 验证证据保留。

cache 不随 Git/配置 ZIP 共享，其他工具应读取本页的摘要与上述命令重新验证，不假定本机证据文件仍存在。
