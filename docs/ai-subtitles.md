# AI 字幕

生成入口为 `Alt+f` 或菜单 **字幕 → 下载／生成 → 生成 AI 字幕**；`Alt+F` 是另一功能。默认仍用 [faster-whisper-xxl](https://github.com/Purfview/whisper-standalone-win)、`large-v3-turbo`、CUDA、float16，语种留空自动检测。备选为 [Qwen3-ASR 1.7B](https://github.com/QwenLM/Qwen3-ASR)，两者独立运行；本机路径写在忽略的 `local.conf`。

## 使用与缓存

- `j` / `k` 选择主/次字幕，`v` / `Alt+V` 控制显示；`Ctrl+r` 重载字幕，`Shift+Backspace` 恢复字幕位置/缩放/时延，不删除缓存。
- 配置文件为 `script-opts/sub_fastwhisper.conf`，脚本标识 `sub_fastwhisper`。输出统一到 `~~/cache/ai-subtitles/`，不在媒体同级写入；旧 `output_path=source` 也回退到缓存。
- 菜单 **字幕 → 下载／生成 → AI 字幕识别方案…** 选择 Whisper 或 Qwen；勾选项为当前方案，`Alt+f` 生成所选方案的字幕。切换会取消旧任务、移除缓存字幕轨并尝试读取新方案的缓存，保留其他字幕轨；不会立即开始识别。
- 菜单选择跨文件保持，重启播放器恢复配置中的 `backend=whisper`；要长期默认 Qwen，可自行将配置改成 `backend=qwen`。字幕位置/时延重置不改变识别方案。
- 缓存按后端、媒体、音轨和识别/翻译设置区分，完成且有效的 SRT 才能复用；按生成键可复用，重新打开媒体会尝试加载。Whisper 原有缓存键保留，Qwen 使用独立命名空间。中途结果与完成缓存分开，卸载取消旧任务并隔离旧回调。
- 缓存不随 Git 或配置 ZIP 分发，清理会失去生成结果；需要长期保存时备份对应完成字幕。媒体移动/修改或更换模型设置可能生成新的缓存，不只按片名匹配。
- **字幕 → 下载／生成 → AI 字幕管理…** 查看当前后端、任务与完成缓存状态，生成/复用、强制重新生成、导出完成 SRT 或打开缓存目录。重新生成跳过缓存复用，但失败/取消保留旧结果；成功后替换当前缓存并移除旧译文，其他媒体与后端的结果不变。
- 导出弹出 Windows 保存对话框，由用户选择位置；只有明确选择导出才可在媒体旁保存。对话框覆盖已有文件需确认；带目标路径的控制台导出消息拒绝覆盖。位置/字号/时延重置不重新识别，也不删除缓存。
- 翻译需兼容 API 与 key，私人 key 写在 `local.conf`；没有 key 时保留原语言识别。选择本地外部 SRT 后可用翻译消息，内封字幕先导出，ASS 不能直接走 SRT 解析。

控制台消息：

```text
script-message-to sub_fastwhisper sub-fastwhisper
script-message-to sub_fastwhisper sub-fastwhisper-cancel
script-message-to sub_fastwhisper sub-fastwhisper-backend-menu
script-message-to sub_fastwhisper sub-fastwhisper-backend whisper
script-message-to sub_fastwhisper sub-fastwhisper-backend qwen
script-message-to sub_fastwhisper sub-fastwhisper-manager
script-message-to sub_fastwhisper sub-fastwhisper-regenerate
script-message-to sub_fastwhisper sub-fastwhisper-export
script-message-to sub_fastwhisper sub-fastwhisper-open-cache
script-message-to sub_fastwhisper sub-translate
```

历史 turbo “约 12 倍实时”没有本次同条件复测，不能当作速度承诺；直播、拖动、真实翻译 API 与全部日常脚本组合需分别验证。

## Qwen 部署与边界

适配器为 `tools/qwen_subtitles.py`，使用 Python 3.12.12、PyTorch 2.8.0+cu128、官方 `qwen-asr==0.0.6` 的 Transformers 后端，CUDA / bfloat16 / SDPA / batch=1。默认每段不超过 20 秒，优先在静音处切分；`qwen_chunk_seconds` 可设为 2–30。先完成识别并释放模型，再加载官方 ForcedAligner 0.6B 校时，避免两模型同时占显存。按对齐时间和标点断句，保留识别标点；它生成原语言字幕，翻译仍沿用现有可选 API。

目前 Qwen 接入只支持本地媒体的内置音轨，按 mpv 当前音轨抽取音频；网络媒体和外挂音轨请切回 Whisper。Qwen 自行分片，不使用 Whisper 的 `use_segment` / `segment_duration` / `compute_type` / `model` 选项。生成期间播放其他 GPU 增强会争用显存；显存不足时本次任务失败，不自动换模型或后端。

Qwen 识别支持 30 种语言；官方对齐器支持中、英、粤、法、德、意、日、韩、葡、俄、西 11 种语言。其他语种及混合语种结果保留每段实际起止时间，不伪造逐词时间；播放器会提示检查时间轴。较长连续语音可能在切片边界断句，不能保证每个视频都优于 Whisper。

部署脚本只建立独立环境、下载固定版本模型，并可写入忽略的本机路径。需要 FFmpeg 在 PATH 中；无需 vLLM、FlashAttention、系统 CUDA Toolkit 或修改 VS Python。默认放在用户目录的 `.cache/mpv-ai/qwen-asr/`，请准备足够空间容纳运行环境、模型及下载暂存，建议至少 20GB。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/setup-qwen-asr.ps1 -ConfigureLocal
```

可用 `-Root 'C:/your/path/qwen-asr'` 指定位置。Hugging Face 大文件下载不畅时加 `-ModelSource modelscope`：从 Qwen 官方 ModelScope 镜像分段下载权重，并逐文件核对 Hugging Face 固定修订的 SHA-256；配置与 tokenizer 仍取自固定的 Hugging Face 修订。不会自动更新模型。

固定修订：ASR 1.7B `7278e1e70fe206f11671096ffdd38061171dd6e5`，ForcedAligner 0.6B `c7cbfc2048c462b0d63a45797104fc9db3ad62b7`。路径键为 `sub_fastwhisper-qwen_python`、`sub_fastwhisper-qwen_model`、`sub_fastwhisper-qwen_aligner`，示例见 `local.conf.example`。部署后推理只读本地模型，不在播放时联网下载依赖。

## 本地修改与验收

`scripts/sub-fastwhisper.lua` 基于上游脚本，集中缓存模块为 `script-modules/ai-subtitle-cache.lua`。更新上游前比较本地后端分派、缓存路径、任务取消、回调隔离和完成判定，不直接覆盖。

验收命令：

```powershell
python tools/test_qwen_asr.py
python tools/test_ai_subtitles_mock.py
python tools/test_ai_subtitles.py --full-config
python tools/test_ai_subtitles.py --full-config --engine qwen --menu-switch
python tools/test_ai_subtitles.py --full-config --management
```

测试使用 320×180/24fps H.264 + AAC 英语合成语音，检查有效 SRT、完成标记、目录同名媒体隔离、重复打开与按键复用、下一文件、字幕状态重置及媒体目录无新增字幕；Qwen 菜单测试加载真实 uosc，经导航键/回车切换，结束恢复 Whisper。`--management` 还通过真实菜单触发第三次生成，并导出至明确指定的测试目录。58 项 Lua 模拟断言另覆盖失败/空输出、缓存损坏、取消与旧回调、重新生成失败保留旧缓存/成功移除旧译文，以及后端隔离与外部字幕保留；9 项 Python 检查覆盖语言映射、切片、标点、断句和时间格式。

2026-10-15 本机 RTX 4070 Laptop 8GB 验收：

- Whisper：`cache/asr-playback-20261015-093426/report.json`，两次生成、两次复用，媒体目录不变。
- Qwen：`cache/asr-playback-20261015-093303/report.json`，两次 CUDA 生成、两次复用、真实菜单切换与恢复 Whisper，媒体目录不变。
- Qwen 中文：`cache/qwen-chinese/report.json`，25.96 秒单声道合成语音，自动检测中文、两切片识别/对齐、六条有序字幕；PyTorch 模型分配显存峰值 4481MiB（不含播放器与其他程序占用）。
- Qwen 取消：`cache/qwen-cancel-20261015-093642/report.json`，真实任务进行中切回 Whisper、下一文件后手动取消均通过；没有完成缓存、错误字幕轨或遗留后端进程。原始复现脚本位于 `cache/test_qwen_cancel.lua` 和 `cache/run_qwen_cancel.py`。
- 部署脚本复核通过：`cache/qwen-setup-verify.log`；模型和 CUDA 环境可用，本机路径已写入忽略的 `local.conf`。

上述使用实际根配置和指定测试脚本，未加载全部日常脚本；短样例不等同多语言准确率或长视频速度评测。其他语种、网络/直播、真实翻译 API、与重型 GPU 增强同时运行仍需分别验收。

2026-10-16 管理菜单回归：Whisper `cache/asr-playback-20261016-153111/`、Qwen `cache/asr-playback-20261016-153433/` 均通过三次真实生成（含菜单强制重新生成）、缓存复用、下一文件/重置和指定路径导出；媒体目录不变。完成缓存不因失败/取消丢失、旧译文失效由 58 项 Lua 断言覆盖；已有目标文件的非交互导出拒绝覆盖。保存对话框本身及其覆盖确认尚未人工点选验收。

## 候选方案备忘

保留自 2026-10-14 调研的选择理由与官方入口；除上方已接入的 Qwen 外，下列候选均未在本机验收。模型格式、语言与对齐支持依具体版本核对，不直接替换 Whisper 的 model 字段。

| 方案 | 用途与接入边界 |
| --- | --- |
| [Whisper large-v3](https://huggingface.co/openai/whisper-large-v3) | 与现有 turbo 比较识别文字；同后端切模型成本低，仍需下载与同片段验收 |
| [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) | 已加入可选入口，当前部署 1.7B + ForcedAligner 0.6B；使用与限制见上方 |
| [Subtitle Edit](https://github.com/SubtitleEdit/subtitleedit) | Windows 外部字幕制作/校时入口，可先比较模型和人工抽查，再把 SRT 加载到 mpv |
| [WhisperX](https://github.com/m-bain/whisperX) | Whisper + VAD/强制对齐，重点改善时间轴，可选说话人；不等于新识别模型或翻译器 |
| [VideoLingo](https://github.com/Huanshere/VideoLingo) | 识别、翻译、断句和排版的完整流程；依赖较多，翻译服务另配，不必再重复串联多个识别管线 |
| [IndexTTS](https://github.com/index-tts/index-tts) | 文本+参考声音生成配音，不能代替 ASR；字幕翻译完成后才考虑，逐句时长/拼接/混音另验收 |

本机环境为 RTX 4070 Laptop 8GB；后续比较识别效果应使用相同多语言片段。识别、对齐、翻译、配音分别评价，显存不足时串行运行。记录模型/后端/量化、媒体规格、冷/热耗时与显存峰值，同时抽查文字和时间轴；其他项目的基准不作为本机结果。
