# 在途工作与已知问题

更新：2026-10-22（Asia/Shanghai）。先核对 Git、diff 与证据，开发约束见 [AGENTS.md](AGENTS.md)。

## 在途：组件发行与正式版跟随

- 目标：组件分包/一键补齐/离线整合；用户已选“跟随官方正式 tag 自建 Windows 全功能播放器，自动预发布，GPU/字幕验收后人工晋级”。
- 所有者：Codex 主 agent；后续范围为公开组件清单与候选整合，发行入口见 `docs/config-checks.md`。
- 待验收：干净机器部署、真实长片/课程字幕与其他硬件；r2 + 适配组件的本机 VS 产帧与合成语音推理已实测，范围见 `docs/config-checks.md` 的组件章节。
- 待处理：将本机组件快照核对许可/兼容范围后转为公开固定资产，并接入发行清单；`release/manifest.json` 的组件清单仍空，不能称公开离线完整版。本机工具及迁移证据见 `docs/config-checks.md` 的组件章节。
- 来源材料缺口：本机媒体快照仅含 FFmpeg/FFprobe，无随包许可/源码材料；VS/Whisper/Qwen 的二进制、模型和依赖仍缺完整上游来源记录。归档内容清点见忽略的 `cache/component-transport-20261021/contents-inventory.json`；分卷成功不代表许可审核或公开发行就绪。

## 下一步与验证边界

- 未解决的既有显示问题：统计快捷键页搜索→控制台补全→主菜单时部分左栏文字可能缺失；原始 `6cc7499` 菜单/uosc 与输入配置同样复现，证据 `cache/panel-manager/baseline-render/menu.png`。与本次面板互斥分开处理，下一步定位文字测量/绘制状态。
- GPU 真实片源基线仅覆盖单个 720p 数学课程的默认/Bilateral 短采样；电影、1080p/4K 和其他重型预设仍需单独测量，见 [配置检查](docs/config-checks.md)。
- AI 字幕默认保持整片识别；真实课程准确率、更长课程/电影、多语言、背景音乐、翻译长时限流和连续播放音画同步尚未验收；已测单个英语参考样例和少量真实翻译，范围见 [字幕说明](docs/ai-subtitles.md)。
- GPU 的 DML、HDR、其他硬件、长时稳定性和主观画质尚未验收；本机 RTX 与 shader 的已测范围见 [GPU 说明](docs/gpu-setup.md)。
- AI 字幕导出的原生保存对话框/覆盖确认尚未人工点选；明确目标路径的导出与拒绝静默覆盖已测，见 [字幕说明](docs/ai-subtitles.md)。
- `toggleHDR`/`auto_bluray` 已提交但未做本机功能验收：HDR 切换依赖 HDRTray `HDRCmd.exe` 与 HDR 显示器，未实测切换/恢复；`auto_bluray` 只认扩展名 `.iso`，未用真实蓝光 ISO 片源验证，非蓝光 ISO 会失败。二者无自动化回归，仅通过离线与原生接线检查；`manager.json` 对其本地改动判为“本地差异，保留”，不自动更新。
