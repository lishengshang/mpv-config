# 在途工作与已知问题

更新：2026-10-15（Asia/Shanghai）。仅保存接手必需的信息；先核对 Git、diff 与证据，旧报告不代表当前验证。开发约束见 [AGENTS.md](AGENTS.md)。

## 未提交功能

- **AI 字幕缓存（原 ASR-002）**：字幕会话仍为单写入者，负责 `scripts/sub-fastwhisper.lua`、`script-opts/sub_fastwhisper.conf`、`script-modules/ai-subtitle-cache.lua` 与 `tools/test_ai_subtitles*`。当前代码已改为集中缓存、完成结果复用、卸载取消与旧回调隔离；这是静态核对，最终运行验收尚待该会话交接。说明统一更新 [AI 字幕](docs/ai-subtitles.md)，不要覆盖其在途实现。
- 字幕接口联动：`input.conf` 的一条“取消 AI 字幕任务”菜单入口保留为未提交改动，等待 `sub-fastwhisper-cancel` 接收方随字幕实现提交；本次菜单提交已排除此行，避免引用未入库接口。
- 字幕下一步：验收真实 turbo CUDA 生成、重复打开复用、不同目录同名媒体隔离、失败/半成品不复用、下一文件与字幕重置；确认媒体目录无新增字幕。旧调研发现的退出码判定、空 key 同步探测与路径回退问题，须对新实现重新复现，不能沿用旧行号或宣布已修复。

## DRBA 暂停切换失败（原 VS-002，待定位）

- 基线：`dev / ec12168` 加 GPU 菜单未提交改动；RTX 4070 Laptop 8GB、驱动 616.92、mpv `v0.41.0-1017-g02a595ddc`、既有便携 VS/k7sfunc。
- 复现场景：640×360/30fps 源、1280×720 窗口，暂停状态反复切换 Bilateral/DFTTest/RIFE，等待 C4F32 首次编译，清空 shader 后开启 DRBA。
- 观察：`operator (): no valid optimization profile found`，控制脚本回滚，完整序列超时。证据：`cache/gpu-ux/20261014-230420-playback-paused/{report.json,player.log}`。
- 同尺寸 DRBA 在新进程独立输出三帧成功：`cache/gpu-ux/drba-640-isolated/`。1280×720 暂停序列也通过；原因未定位，不能认定为 640×360 尺寸限制。
- 下一步：运行 `..\python.exe tools/test_gpu_ux.py --case playback --paused --source-width 640`；复现后缩小为 RIFE → 清空 → DRBA，比较新进程与非暂停状态。先核对 VS/TRT 生命周期和参数，不直接删引擎、改个人调参或升级运行时。

## 现有 GPU 菜单的验收摘要

以下继承精简前的同日记录，本次只改文档，没有重跑播放。环境与上方一致，源 1280×720/30fps。

- 32 项 Lua 控制断言、8 项探针测试；普通播放与暂停各 33 步，覆盖 12 个 RTX VS、两个 shader 路由、清空重开、保留用户滤镜及下一文件。
- 通过报告：`cache/gpu-ux/20261014-230050-playback/report.json`、`cache/gpu-ux/20261014-231916-playback-paused-1280/report.json`。
- 无 VS 和真实延迟初始化失败回滚通过：`cache/gpu-ux/20261014-230231-no-vs/report.json`、`cache/gpu-ux/20261014-230552-failure/report.json`。
- 扩展 640×360 场景的 shader 2× 截图存在，但完整序列失败；不算整体通过。DML、HDR、长时播放、全部日常脚本组合、其他机器、主观画质和实时帧率未验收。
- 已提交部署/滤镜的历史证据见 GPU 指南。远端 Windows CI 尚未确认运行结果；本机通过不能代替远端记录。缓存证据不随 Git 分发，接手时确认是否仍存在。

## 接手方式

先读 `AGENTS.md`，核对 `git status --short`、HEAD 与目标 diff；仅触及自己拥有的范围。同文件存在并行所有者时先协调。相关状态变化才更新本页，不再创建常规任务文件；功能完成且提交后删除在途条目，长期限制留在对应功能说明。
