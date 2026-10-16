# 在途工作与已知问题

更新：2026-10-16（Asia/Shanghai）。仅保存接手必需的信息；先核对 Git、diff 与证据，旧报告不代表当前验证。开发约束见 [AGENTS.md](AGENTS.md)。

## DRBA 暂停切换失败（原 VS-002，待定位）

- 基线：`dev / ec12168` 加 GPU 菜单未提交改动；RTX 4070 Laptop 8GB、驱动 616.92、mpv `v0.41.0-1017-g02a595ddc`、既有便携 VS/k7sfunc。
- 复现场景：640×360/30fps 源、1280×720 窗口，暂停状态反复切换 Bilateral/DFTTest/RIFE，等待 C4F32 首次编译，清空 shader 后开启 DRBA。
- 观察：`operator (): no valid optimization profile found`，控制脚本回滚，完整序列超时。证据：`cache/gpu-ux/20261014-230420-playback-paused/{report.json,player.log}`。
- 同尺寸 DRBA 在新进程独立输出三帧成功：`cache/gpu-ux/drba-640-isolated/`。1280×720 暂停序列也通过；原因未定位，不能认定为 640×360 尺寸限制。
- 下一步：运行 `..\python.exe tools/test_gpu_ux.py --case playback --paused --source-width 640`；复现后缩小为 RIFE → 清空 → DRBA，比较新进程与非暂停状态。先核对 VS/TRT 生命周期和参数，不直接删引擎、改个人调参或升级运行时。

## 接手方式

先读 `AGENTS.md`，核对 `git status --short`、HEAD 与目标 diff；仅触及自己拥有的范围。同文件存在并行所有者时先协调。相关状态变化才更新本页，不再创建常规任务文件；功能完成且提交后删除在途条目，长期限制留在对应功能说明。
