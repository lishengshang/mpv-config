# 在途工作与已知问题

更新：2026-11-22（Asia/Shanghai）。先核对 Git、diff 与证据，开发约束见 [AGENTS.md](AGENTS.md)。

## 待验收：Base 与可选扩展

- 转正式版前，使用公开候选在干净 Windows 机器复测安装和旧版迁移，补齐 Whisper CUDA 与其余 RTX 预设验收。验收入口见 [配置检查](docs/config-checks.md#正式版跟随与预发布)。

## 在途：组件发行与正式版跟随

- 目标：组件分包/一键补齐/离线整合；用户已选“跟随官方正式 tag 自建 Windows 全功能播放器，自动预发布，GPU/字幕验收后人工晋级”。
- 所有者：Codex 主 agent；后续范围为公开组件清单与候选整合，发行入口见 `docs/config-checks.md`。
- 待验收：干净机器部署、真实长片/课程字幕与其他硬件；r2 和后续发布基线见 `docs/config-checks.md` 的组件章节。
- 完整版待发行。当前使用的 Faster-Whisper-XXL 独立程序缺少已核实的公开再分发授权，VS 等组件也需补齐来源和许可清单。`release/manifest.json` 的公开组件清单仍为空。本机组包和迁移入口见 [配置检查](docs/config-checks.md#组件安装与迁移)。
- 来源材料缺口：本机媒体快照仅含 FFmpeg/FFprobe，无随包许可/源码材料；VS/Whisper/Qwen 的二进制、模型和依赖仍缺完整上游来源记录。归档内容清点见忽略的 `cache/component-transport-20261021/contents-inventory.json`；分卷成功不代表许可审核或公开发行就绪。

## 下一步与验证边界

- GPU 真实片源基线覆盖两份 720p 数学课程的默认/Bilateral 短采样；电影、真实 1080p/4K 和其他重型预设仍需单独测量，见 [配置检查](docs/config-checks.md)。
- Whisper 连贯提速档的中文识别文字需人工抽查，94 分钟课程、真实日语长片和电影尚未验收；详见 [字幕说明](docs/ai-subtitles.md)。
- AI 字幕默认整片普通推理；批量速度档在 94.59 分钟课程出现无效时间轴，保持可选并拒绝无效完成缓存。中文长课程输出／时间轴、英语合成样例与日语官方短样例已测；人工准确率、真实日语长片／电影、背景音乐、翻译长时限流和连续播放音画同步仍待验收，范围见 [字幕说明](docs/ai-subtitles.md)。
- GPU 的 DML、HDR、其他硬件、长时稳定性和主观画质尚未验收；本机 RTX 与 shader 的已测范围见 [GPU 说明](docs/gpu-setup.md)。
- AI 字幕导出的原生保存对话框/覆盖确认尚未人工点选；明确目标路径的导出与拒绝静默覆盖已测，见 [字幕说明](docs/ai-subtitles.md)。
- `toggleHDR`/`auto_bluray` 已提交但未做本机功能验收：HDR 切换依赖 HDRTray `HDRCmd.exe` 与 HDR 显示器，未实测切换/恢复；`auto_bluray` 只认扩展名 `.iso`，未用真实蓝光 ISO 片源验证，非蓝光 ISO 会失败。二者无自动化回归，仅通过离线与原生接线检查；`manager.json` 对其本地改动判为“本地差异，保留”，不自动更新。
