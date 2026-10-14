# 配置检查

双击 `tools/check-config.cmd`，或在 `portable_config` 下执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-config.ps1
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

边界：路径扫描是保守的项目引用检查，不是完整 mpv 配置语法解析；当前支持无空白的上述 literal 资源路径，不推断表达式、外部模型、所有 Lua 动态路径或注释中的示例。内置 profile 目前仅认可 `default`，本仓库其它 profile 在项目内定义。输入命令解析、等价键位和脚本接线将在后续块接入，当前“0 error”不证明实际播放通过。

2026-10-14 第一块验收：9 项故障/边界回归通过，本仓库 4 个配置文件引用检查为 0 errors、0 warnings。GPU 产帧检查仍使用独立的 `tools/verify-gpu.ps1 -Run`。
