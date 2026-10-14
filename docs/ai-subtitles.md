# AI 字幕

生成入口为 `Alt+f` 或菜单 **字幕 → 生成 AI 字幕**；`Alt+F` 是另一功能。当前配置用 [faster-whisper-xxl](https://github.com/Purfview/whisper-standalone-win)、`large-v3-turbo`、CUDA、float16，语种留空自动检测；后端路径写在忽略的 `local.conf`。

## 使用与缓存

- `j` / `k` 选择主/次字幕，`v` / `Alt+V` 控制显示；`Ctrl+r` 重载字幕，`Shift+Backspace` 恢复字幕位置/缩放/时延，不删除缓存。
- 配置文件为 `script-opts/sub_fastwhisper.conf`，脚本标识 `sub_fastwhisper`。当前未提交实现将输出统一到 `~~/cache/ai-subtitles/`，不在媒体同级写入；旧 `output_path=source` 也回退到缓存。
- 缓存按媒体、音轨和识别/翻译设置区分，完成且有效的 SRT 才能复用；按生成键可复用，重新打开媒体会尝试加载。中途结果与完成缓存分开，卸载取消旧任务并隔离旧回调。
- 缓存不随 Git 或配置 ZIP 分发，清理会失去生成结果；需要长期保存时备份对应完成字幕。媒体移动/修改或更换模型设置可能生成新的缓存，不只按片名匹配。
- 当前没有专用强制重新生成或导出菜单；需要在视频旁保存时手动复制完成的 SRT。不要把字幕重置当重新识别或清缓存。
- 翻译需兼容 API 与 key，私人 key 写在 `local.conf`；没有 key 时保留原语言识别。选择本地外部 SRT 后可用翻译消息，内封字幕先导出，ASS 不能直接走 SRT 解析。

控制台消息：

```text
script-message-to sub_fastwhisper sub-fastwhisper
script-message-to sub_fastwhisper sub-fastwhisper-cancel
script-message-to sub_fastwhisper sub-translate
```

以上缓存/取消行为来自当前代码静态核对，尚待字幕会话完成运行验收，状态与下一步见 [PROJECT_STATE.md](../PROJECT_STATE.md)。历史 turbo “约 12 倍实时”没有本次同条件复测，不能当作速度承诺；直播、拖动、翻译与全部脚本组合需分别验证。

## 本地修改与验收

`scripts/sub-fastwhisper.lua` 基于上游脚本，集中缓存模块为 `script-modules/ai-subtitle-cache.lua`。更新上游前比较本地缓存路径、任务取消、回调隔离和完成判定，不直接覆盖。

验收至少包含启动/加载/生成、重复打开复用、同名不同目录媒体、音轨与模型变更、失败/半成品、下一文件与恢复字幕状态；检查有效非空 SRT 和后端退出码，确认媒体目录无新增字幕。当前字幕会话负责对应 `tools/test_ai_subtitles*` 测试，最终命令与结果完成后再补充，不能把测试文件存在当作通过。

## 候选方案备忘

保留自 2026-10-14 调研的选择理由与官方入口；下列候选均未在本机验收。模型格式、语言与对齐支持依具体版本核对，不直接替换 Whisper 的 model 字段。

| 方案 | 用途与接入边界 |
| --- | --- |
| [Whisper large-v3](https://huggingface.co/openai/whisper-large-v3) | 与现有 turbo 比较识别文字；同后端切模型成本低，仍需下载与同片段验收 |
| [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) | 0.6B/1.7B 多语言识别候选；字幕时间轴需 ForcedAligner，识别与对齐的语种覆盖不同；独立后端 |
| [Subtitle Edit](https://github.com/SubtitleEdit/subtitleedit) | Windows 外部字幕制作/校时入口，可先比较模型和人工抽查，再把 SRT 加载到 mpv |
| [WhisperX](https://github.com/m-bain/whisperX) | Whisper + VAD/强制对齐，重点改善时间轴，可选说话人；不等于新识别模型或翻译器 |
| [VideoLingo](https://github.com/Huanshere/VideoLingo) | 识别、翻译、断句和排版的完整流程；依赖较多，翻译服务另配，不必再重复串联多个识别管线 |
| [IndexTTS](https://github.com/index-tts/index-tts) | 文本+参考声音生成配音，不能代替 ASR；字幕翻译完成后才考虑，逐句时长/拼接/混音另验收 |

本机调研环境为 RTX 4070 Laptop 8GB；先保证当前缓存调度稳定，再用相同多语言片段比较模型。识别、对齐、翻译、配音分别评价，显存不足时串行运行。记录模型/后端/量化、媒体规格、冷/热耗时与显存峰值，同时抽查文字和时间轴；其他项目的基准不作为本机结果。
