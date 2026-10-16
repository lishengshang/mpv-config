# 在途工作与已知问题

更新：2026-10-16（Asia/Shanghai）。先核对 Git、diff 与证据，开发约束见 [AGENTS.md](AGENTS.md)。

## 下一步与验证边界

- 真实片源性能基线由用户稍后指定本机文件/目录；当前只完成工具与合成片源回归。入口与同条件采样命令见 [配置检查](docs/config-checks.md)。
- GPU 原完整长序列停在 shader 首次编译；小尺寸 VS 产帧与针对性切换回归已通过，尚未重新验收 shader 冷编译完整序列。证据与边界见 [GPU 说明](docs/gpu-setup.md)。
- AI 字幕导出的原生保存对话框/覆盖确认尚未人工点选；明确目标路径的导出与拒绝静默覆盖已测，见 [字幕说明](docs/ai-subtitles.md)。
