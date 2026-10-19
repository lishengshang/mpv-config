# AI 字幕

生成入口为 `Alt+f` 或菜单 **字幕 → 下载／生成 → 生成 AI 字幕**；`Alt+F` 是另一功能。默认仍用 [faster-whisper-xxl](https://github.com/Purfview/whisper-standalone-win)、`large-v3-turbo`、CUDA、float16，语种留空自动检测。备选为 [Qwen3-ASR 1.7B](https://github.com/QwenLM/Qwen3-ASR)，两者独立运行；本机路径写在忽略的 `local.conf`。

## 使用与缓存

- `j` / `k` 选择主/次字幕，`v` / `Alt+V` 控制显示；`Ctrl+r` 重载字幕，`Shift+Backspace` 恢复字幕位置/缩放/时延，不删除缓存。
- 配置文件为 `script-opts/sub_fastwhisper.conf`，脚本标识 `sub_fastwhisper`。输出统一到 `~~/cache/ai-subtitles/`，不在媒体同级写入；旧 `output_path=source` 也回退到缓存。
- AI 字幕默认缩为原来的 80%（`font_scale=0.8`）：原文按当前纯文本字号换算，双语 ASS 的 70/50 改为 56/40，不修改普通字幕的全局字号/缩放。播放使用缓存中的独立 ASS，识别与翻译原始 SRT、导出内容保留。
- 长句按 UTF-8 字符宽度和标点分屏，双语每种语言一行、总计最多两行；`layout_line_width=56` 按半角计宽，中文约占两格，`layout_max_seconds=6` 控制长段显示时长。拆分时间按文本长度近似分配，不等于逐词对齐；数学公式和快速讲话仍需人工抽查。改排版参数后重新加载即可，无需重新识别或请求翻译。
- 菜单 **字幕 → 下载／生成 → AI 字幕识别方案…** 选择 Whisper 或 Qwen；勾选项为当前方案，`Alt+f` 生成所选方案的字幕。切换会取消旧任务、移除缓存字幕轨并尝试读取新方案的缓存，保留其他字幕轨；不会立即开始识别。
- 菜单选择跨文件保持，重启播放器恢复配置中的 `backend=whisper`；要长期默认 Qwen，可自行将配置改成 `backend=qwen`。字幕位置/时延重置不改变识别方案。
- 缓存按后端、媒体、音轨和识别/翻译设置区分，完成且有效的 SRT 才能复用；按生成键可复用，重新打开媒体会尝试加载。Whisper 原有缓存键保留，Qwen 使用独立命名空间。中途结果与完成缓存分开，卸载取消旧任务并隔离旧回调。
- 分段模式（`use_segment=yes`，默认关闭）在首段完成后显示原文，首段目标为 `min(segment_duration, 15)` 秒，之后目标为 `max(segment_duration, 40)` 秒，最后一段截到媒体结尾。使用异步提取/识别，可通过管理菜单取消；切换文件会取消旧任务并移除未完成字幕轨。音频按任务开始时选定的内置音轨解码为 16kHz 单声道 PCM，暂不支持外挂音轨。
- `segment_silence=yes`（分段时默认启用）在目标边界前后 3 秒范围内，用 FFmpeg 查找低于 -35dB、至少 0.25 秒的静音，选择距目标最近的静音中点；首段仍不超过 15 秒，也不短于原目标的一半。只扫描边界附近的音频，增加提取耗时；没有附近静音时回退固定时长，不保证连续讲话或背景音乐中不截断句子。设 `segment_silence=no` 可对照固定切片。
- 分段与整片使用相同的完成缓存机制，但按 `use_segment` 等设置分别缓存，不互相复用；静音切片使用独立缓存标识，原有整片/固定切片缓存保留，切回对应设置可复用。中间结果不会标为完成，失败/取消不覆盖旧完成缓存。分段期间先显示原文，整片识别成功后再翻译；真实翻译 API 的短样本验证见下文。
- 缓存不随 Git 或配置 ZIP 分发，清理会失去生成结果；需要长期保存时备份对应完成字幕。媒体移动/修改或更换模型设置可能生成新的缓存，不只按片名匹配。
- **字幕 → 下载／生成 → AI 字幕管理…** 查看当前后端、任务与完成缓存状态，生成/复用、强制重新生成、导出完成 SRT 或打开缓存目录。重新生成跳过缓存复用，但失败/取消保留旧结果；成功后替换当前缓存并移除旧译文，其他媒体与后端的结果不变。
- 导出弹出 Windows 保存对话框，由用户选择位置；只有明确选择导出才可在媒体旁保存。对话框覆盖已有文件需确认；带目标路径的控制台导出消息拒绝覆盖。位置/字号/时延重置不重新识别，也不删除缓存。
- 翻译需兼容 API 与 key，私人 key 写在 `local.conf`，示例见 `local.conf.example`；没有 key 时保留原语言识别。选择本地外部 SRT 后可用翻译消息，内封字幕先导出，ASS 不能直接走 SRT 解析。HTTP/响应格式失败时不把原文标为已完成译文，可显式重试；有效译文按源时间轴写入，完成缓存可直接复用。curl 需支持 `--fail-with-body`。

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

历史 turbo “约 12 倍实时”没有本次同条件复测，不能当作速度承诺；直播、拖动、翻译长时限流与全部日常脚本组合需分别验证。

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
python tools/test_ai_subtitles.py --full-config --segment --render
python tools/test_ai_subtitles.py --full-config --segment --fixed-segments --render
python tools/test_ai_subtitles.py --full-config --long-speech --render
python tools/test_ai_subtitles.py --full-config --segment --render --media "<本机视频路径>" --language zh --timeout 2400
```

测试使用 320×180/24fps H.264 + AAC 英语合成语音，检查有效 SRT、完成标记、目录同名媒体隔离、重复打开与按键复用、下一文件、字幕状态重置及媒体目录无新增字幕；Qwen 菜单测试加载真实 uosc，经导航键/回车切换，结束恢复 Whisper。`--management` 还通过真实菜单触发第三次生成，并导出至明确指定的测试目录。Lua 模拟断言另覆盖失败/空输出、缓存损坏、取消与旧回调、重新生成失败保留旧缓存/成功移除旧译文、后端隔离、外部字幕保留，以及分段 PCM 提取、音轨映射、小数秒偏移、边界截断、纯数字字幕和静音段；9 项 Python 检查覆盖语言映射、切片、标点、断句和时间格式。

`--segment` 使用连续不同语句的较长样例，额外检查运行状态、手动取消、首批字幕后切片、未完成轨清理，并记录首批/完成耗时；`--fixed-segments` 关闭静音边界作对照。`--render` 用 D3D11 渲染并保存首批与完成字幕截图。`--long-speech` 用相同语句测试整片模式。报告检查时间轴、错误级日志和本次遗留后端进程，同时保留参考文本与识别差异；功能通过不等于文字准确率通过。两种模式均进行两次独立生成，不控制操作系统文件缓存，不能称为严格冷/热启动基准。

`--media` 将本地视频的第一路视频/音频无重编码封装到缓存中的两个同名测试副本，完整识别两次，保留原文件及同级目录；结束时检查原文件大小、修改时间、SHA256 和目录列表。真实媒体默认自动识别语言，可用 `--language zh` 明确指定；`--timeout` 是包含取消、两次生成及复用在内的总时限。报告记录实际时长、测试副本哈希和字幕时间轴；没有人工参考文本时不计算文字准确率。截图会跳转到首条字幕的时间范围，等待字幕出现后保存。

2026-10-15 本机 RTX 4070 Laptop 8GB 验收：

- Whisper：`cache/asr-playback-20261015-093426/report.json`，两次生成、两次复用，媒体目录不变。
- Qwen：`cache/asr-playback-20261015-093303/report.json`，两次 CUDA 生成、两次复用、真实菜单切换与恢复 Whisper，媒体目录不变。
- Qwen 中文：`cache/qwen-chinese/report.json`，25.96 秒单声道合成语音，自动检测中文、两切片识别/对齐、六条有序字幕；PyTorch 模型分配显存峰值 4481MiB（不含播放器与其他程序占用）。
- Qwen 取消：`cache/qwen-cancel-20261015-093642/report.json`，真实任务进行中切回 Whisper、下一文件后手动取消均通过；没有完成缓存、错误字幕轨或遗留后端进程。原始复现脚本位于 `cache/test_qwen_cancel.lua` 和 `cache/run_qwen_cancel.py`。
- 部署脚本复核通过：`cache/qwen-setup-verify.log`；模型和 CUDA 环境可用，本机路径已写入忽略的 `local.conf`。

上述使用实际根配置和指定测试脚本，未加载全部日常脚本；短样例不等同多语言准确率或长视频速度评测。其他语种、网络/直播、真实翻译 API、与重型 GPU 增强同时运行仍需分别验收。

2026-10-16 管理菜单回归：Whisper `cache/asr-playback-20261016-153111/`、Qwen `cache/asr-playback-20261016-153433/` 均通过三次真实生成（含菜单强制重新生成）、缓存复用、下一文件/重置和指定路径导出；媒体目录不变。完成缓存不因失败/取消丢失、旧译文失效由 58 项 Lua 断言覆盖；已有目标文件的非交互导出拒绝覆盖。保存对话框本身及其覆盖确认尚未人工点选验收。

2026-10-17 本机分段验收：RTX 4070 Laptop 8GB、驱动 616.92、日常播放器 `v0.41.0-1017-g02a595ddc`（不是 r2 发行包）、Whisper `large-v3-turbo` / CUDA / float16；同一份 56.259 秒不同语句英语合成语音，320×180/24fps H.264 + AAC，根配置、指定测试脚本、D3D11 渲染、暂停及禁用音频输出。三组 `speech.wav` SHA256 相同，各做两次独立生成：

| 模式 | 首批原文 | 整片完成 | 参考文本对比 |
| --- | --- | --- | --- |
| 整片 | 8.9–13.0 秒 | 8.9–13.0 秒 | 只有 `cache` → `cash` 同音替换 |
| 固定分段 | 10.1–11.2 秒 | 31.4–33.4 秒 | 另漏掉边界词 `to sing`，并多出 `fine` |
| 静音附近分段 | 10.2–12.2 秒 | 30.9–33.9 秒 | 恢复上述边界词，只有同一处同音替换 |

证据依次为 `cache/asr-playback-20261017-220531/report.json`、`cache/asr-playback-20261017-220354/report.json`、`cache/asr-playback-20261017-220859/report.json`。静音切片实际边界约 10.981 / 52.074 秒；取消状态响应 0.114 秒，首批字幕后切片、两次生成、自动/按键复用与重置通过，媒体目录不变，退出码 0、无错误级日志和本次遗留后端进程；首批/完成截图已检查。固定分段回归发生在加入静音功能前，同内容的复跑入口为 `--segment --fixed-segments`。本轮 111 项 Lua 模拟断言与 9 项 Qwen 适配检查通过；Qwen 短语音真实菜单切换/两次生成/复用/恢复 Whisper 通过，证据 `cache/asr-playback-20261017-220619/report.json`。

该短样例中整片更快，默认保持 `use_segment=no`。上述不是多语言准确率、长影片体验或严格冷启动基准；静音检测在持续讲话、低音量或背景音乐下的质量、真实翻译 API、外挂音轨及全部日常脚本组合仍未验收。最初重复相同句子的样例使整片识别也发生大段遗漏，因此不作为边界质量或速度结论。

2026-10-19 真实中文课程验收：同机 RTX 4070 Laptop 8GB / 驱动 616.92 / mpv `v0.41.0-1017-g02a595ddc`，Whisper `large-v3-turbo` / CUDA / float16 / `language=zh`；完整 1993.454 秒数学课程，1280×720/22fps H.264 + 双声道 AAC，经无重编码封装后测试。使用根配置与指定测试脚本，D3D11 渲染、暂停并关闭音频输出，首段目标 10 秒、后续目标 40 秒，在静音附近切片：

- 两次独立生成的首批字幕为 5.66 / 7.69 秒，整片完成为 513.07 / 526.29 秒，分别得到 163 / 165 条有效字幕；两份时间轴均有序且未越界，末条结束于 1991.16 秒。两遍识别文本存在差异，无人工参考稿，不能据此声称准确率。
- 手动取消响应 0.158 秒，首批字幕后切换文件取消、未完成轨清理、独立缓存、字幕重置和自动/按键复用均通过；自动复用约 0.306 秒。原文件大小、修改时间、SHA256 与同级目录列表不变，退出码 0，无错误级日志或本次遗留后端进程。报告为 `cache/asr-playback-20261019-115747/report.json`。
- 本轮修正验收截图在第 0 秒可能没有字幕的问题：截图改为定位到首条字幕并等待文本出现。上述长片流程运行时使用修正前的截图入口，其原截图不能证明字幕已渲染；保留生成中的字幕快照，用修正后的函数单独验证真实中文渲染，截图已目视检查，证据为同目录 `render-review/`。修正后的完整合成语音分段回归通过，两次生成、取消/切片/复用及首批/完成字幕截图均通过，退出码 0、无遗留后端，报告为 `cache/asr-playback-20261019-121550/report.json`。

本轮覆盖单个约 33 分钟课程，不覆盖另两段更长课程、电影/背景音乐、多语言、真实翻译 API、全部日常脚本组合或连续播放音画同步；没有同片整片识别对照，不能据此比较两种模式速度。默认仍保持 `use_segment=no`。

## 参考文本与真实翻译接口验证

2026-10-19，RTX 4070 Laptop 8GB；两后端分别对同一份 Microsoft Zira 合成英语语音识别两次，56.259 秒，原文 145 个词/700 个字母。语音 WAV SHA256 相同；转为小写，忽略标点，词级按英语词比较，字符级另去空格；错误率为 `(替换 + 删除 + 插入) / 参考单位数`，不是通用准确率。

| 后端 | 两次词错误率 | 两次字符错误率 | 差异 |
| --- | --- | --- | --- |
| Whisper large-v3-turbo / CUDA float16 | 均 0.69%（1/145） | 均 0.29%（2/700） | `cache` → `cash` |
| Qwen3-ASR 1.7B / CUDA bfloat16 | 均 0% | 均 0% | 本样例未发现文字差异 |

两组真实推理、时间轴、缓存复用、退出与截图检查通过。报告为 `cache/asr-playback-20261019-210242/`、`cache/asr-playback-20261019-210329/`，量化汇总为 `cache/asr-accuracy-20261019.json`。该单个清晰合成语音不代表中文课程、多语言或噪声环境效果；课程暂无人工逐字稿，真实课程准确率仍未验证。

真实接口为 SiliconFlow Chat Completions、`deepseek-ai/DeepSeek-V4-Flash`：三条固定英文字幕翻成中文，以及用户提供数学课程的 60 秒目标切片（无重编码，关键帧使实际时长为 63.524 秒）的 5 条 Whisper 字幕翻成英文，均通过真实请求、源时间戳保持、完成校验、双语显示及重复操作检查。课程原文件 SHA256/大小/修改时间和同级目录不变；该切片两次识别的生命周期验收通过，不作为全文识别或准确率验收。

固定样例最终回归为 `cache/translation-20261019-211842/`，课程识别为 `cache/asr-playback-20261019-211243/`，课程翻译与重开播放器零请求复用为 `cache/translation-20261019-211343/`。最初长句遮挡较多板书；后续排版修订通过 48 项断言及同目录重开测试，截图已检查为两行且字号为原来的 80%。原文生成回归为 `cache/asr-playback-20261019-212659/`。只抽查了少量翻译，不是系统翻译质量评测，也未覆盖长时请求、真实限流/额度耗尽、其他服务和重型 GPU 增强同时运行。

本轮修复请求失败把原文标记为译文、哈希/并行回调使译文乱序，以及 `sub-reload` 分配新轨道 ID 后仍选旧 ID 导致字幕关闭。130 项离线断言覆盖 API 错误、异常响应/时间戳、显式重试、跨会话缓存、取消后的旧回调及并行批次倒序完成；本地 HTTP 检查与真实服务检查分别记录，不混为一次验收。

复现入口（会产生少量真实 API 调用，默认仅发送三条固定测试字幕；密钥仅从忽略的 `local.conf` 读取）：

```powershell
python tools/test_subtitle_translation.py --media '<本地测试视频>'
# 发送明确指定的 SRT，可用 --target English 测中译英；不自动上传视频转录内容
python tools/test_subtitle_translation.py --media '<缓存课程切片>' --subtitles '<待翻译 SRT>' --target English
# 同样参数加 --reuse '<上一轮 cache/translation-* 目录>'，要求重开播放器后零请求复用
# --offline 使用本地 HTTP 固定响应，只检查显示与请求链路，不证明真实 API 可用
```

工具不启用 mpv 的详细文件日志，控制台输出在保存前替换密钥；原始详细日志可能包含选项或 subprocess 参数，不用于真实密钥测试。

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
