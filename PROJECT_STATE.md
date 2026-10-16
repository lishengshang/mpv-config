# 在途工作与已知问题

更新：2026-10-16（Asia/Shanghai）。先核对 Git、diff 与证据，开发约束见 [AGENTS.md](AGENTS.md)。

## 在途：组件发行与正式版跟随

- 目标：组件分包/一键补齐/离线整合；用户已选“跟随官方正式 tag 自建 Windows 全功能播放器，自动预发布，GPU/字幕验收后人工晋级”。
- 所有者：Codex 主 agent；后续范围为组件清单、分包与部署工具，发行入口见 `docs/config-checks.md`。
- 待验收：候选包的 GPU/字幕和干净机器验证；自动 CPU 回归不能替代这些功能的实际验收。
- 待实现：固定 VS/Whisper 分包，解决 Qwen venv 可迁移部署，补组件下载与离线组装入口。`release/manifest.json` 的组件清单仍空，不能称离线完整版。

## 下一步与验证边界

- 真实片源性能基线由用户稍后指定本机文件/目录；当前只完成工具与合成片源回归。入口与同条件采样命令见 [配置检查](docs/config-checks.md)。
- GPU 原完整长序列停在 shader 首次编译；小尺寸 VS 产帧与针对性切换回归已通过，尚未重新验收 shader 冷编译完整序列。证据与边界见 [GPU 说明](docs/gpu-setup.md)。
- AI 字幕导出的原生保存对话框/覆盖确认尚未人工点选；明确目标路径的导出与拒绝静默覆盖已测，见 [字幕说明](docs/ai-subtitles.md)。
