# 配置检查

双击 `tools/check-config.cmd`，或在 `portable_config` 下执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-config.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-config.ps1 -Mpv
..\python.exe tools/check_config.py --json
..\python.exe tools/test_check_config.py
```

仅需 Python 3.10+ 标准库，不需要 GPU、模型或网络。启动器优先使用 mpv 同级的便携 Python，没有时寻找系统 Python。`-ConfigRoot` / `--config-root` 可检查其它配置目录；`-Json` / `--json` 输出结构化结果到终端，不生成报告文件。

## 第一块：引用检查

- 检查 `mpv.conf`、`profiles.conf` 和项目内递归 include；忽略注释，识别循环 include、缺文件与 UTF-8 读取失败。
- 检查 `profile=`、profile 列表和 `input.conf` / `inputevent_key.conf` 的 literal `apply-profile` 引用。
- 检查上述配置中的 literal `~~/` VS、GLSL、hook、ICC 文件引用，包括既有嵌套 cycle-commands 字符串。
- `local.conf` 是可选私人文件，即使存在也不读取。配置外的路径不读取，报告为待运行验证的 warning。

输出格式为 `文件:行号: ERROR/WARNING [规则] 说明`，error 返回 1，无 error 返回 0；启动器缺 Python 返回 2。warnings 不能解释为对应功能已通过。

边界：路径扫描是保守的项目引用检查，不是完整 mpv 配置语法解析；当前支持无空白的上述 literal 资源路径，不推断表达式、外部模型、所有 Lua 动态路径或注释中的示例。离线检查只认可项目内 profile 与 `default`；使用内置 profile 时加 `-Mpv` 查询实际播放器。当前“0 error”不证明实际播放通过。

2026-10-14 第一块验收：9 项故障/边界回归通过，本仓库 4 个配置文件引用检查为 0 errors、0 warnings。GPU 产帧检查仍使用独立的 `tools/verify-gpu.ps1 -Run`。

## 第二块：mpv 原生输入解析

加 `-Mpv` / `--mpv` 时，将输入条目放进互不覆盖的临时 section，由 mpv 本身解析命令并返回 `input-bindings` 的规范化键名；临时文件自动清理。只运行检查脚本，不加载项目配置、用户脚本或媒体，不触发被检查的命令。

- 同一配置、同一 section 的等价键位算冲突，例如 `CTRL+SHIFT+a` 与 `CTRL+A`、`MOUSE_BTN0` 与 `MBTN_LEFT`；大小写不同和不同 section 分别处理。
- InputEvent 按动作和完整条件文本分组，单击/长按/释放及不同条件分支可并存；与常规键位重叠报告 INFO，不直接判错。
- 未知键名、未知命令、参数格式错误按原文件行号报告；播放器缺失、缺 Lua 支持或解析超时报告 error。
- InputEvent 当前按本项目的 `#event:` 注释约定读取；条件是否有效、脚本强制绑定的运行优先级仍需要运行验证。

启动器可用 `-MpvRoot` 指定播放器目录。18 项回归通过（9 项引用、9 项原生解析），本仓库 0 errors、0 warnings，另有 6 个 InputEvent 重叠 INFO。默认离线模式不运行播放器；原生模式也不进行 GPU 测试。

接口依据：[mpv input-bindings 与键名规范化](https://mpv.io/manual/master/#property-list-input-bindings)、[上游输入配置解析实现](https://github.com/mpv-player/mpv/blob/master/input/input.c)。
