# 配置检查

双击 `tools/check-config.cmd`，或在配置根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-config.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-config.ps1 -Mpv
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-config.ps1 -Mpv -Verbose
..\python.exe tools/check_config.py --json
..\python.exe tools/test_check_config.py
```

需要 Python 3.10+ 标准库；启动器优先使用 mpv 同级便携 Python，再找系统 Python。双击入口包含 mpv 原生检查，命令行默认离线；`-MpvRoot` 指定播放器目录，`-ConfigRoot` 指定配置目录，`-Json` 输出 JSON。

## 检查范围

| 项目 | 能检查 | 边界 |
| --- | --- | --- |
| 配置引用 | 递归 include、循环/缺失文件、profile、literal `~~/` VS/GLSL/hook/ICC 路径 | 不推断表达式、外部模型或动态 Lua 路径 |
| 原生输入（`-Mpv`） | mpv 规范化键名、同 section 等价键冲突、命令与参数解析 | 不执行输入命令，不加载项目脚本或媒体 |
| 脚本接线 | 脚本标识/入口、名称碰撞、literal 消息与命名绑定、嵌套 cycle-commands | 动态/条件注册及强制绑定优先级仍需运行验证 |
| InputEvent | 启用状态、外部文件、prefix；按动作和完整条件分组 | 单击/长按/释放可并存；条件实际行为需运行验证 |

`local.conf` 即使存在也不读取；外部路径只报告待验证。离线模式只认可项目内 profile 与 `default`，内置 profile 需查询 mpv。等价键包括 `CTRL+SHIFT+a` / `CTRL+A`、`MOUSE_BTN0` / `MBTN_LEFT`；大小写和不同 section 分开处理。

输出含文件、行号、规则与 ERROR/WARNING；错误退出码 1，无错误 0，启动器缺 Python 2。WARNING/INFO 和源码声明匹配不等于功能通过；`-Verbose` 展开来源，JSON 保留全部条目。

## CI 与验收

Windows workflow `.github/workflows/config-check.yml` 在 `dev`/`master` push、PR 或手动触发时运行 Python 3.12：

```powershell
python tools/test_check_config.py ReferenceChecks WiringChecks
python tools/check_config.py
```

CI 仅跑离线回归与引用/接线检查，不下载 mpv、VS 或模型，不验证动态 handler、媒体与 GPU。需要原生输入检查时在本机加 `-Mpv`；GPU 产帧用 `tools/verify-gpu.ps1 -Run`。

历史基线 `627414a`、`050a2c7`、`ecd72dd`、`538243e`：31 项本机回归（22 离线、9 原生）通过；远端 workflow 尚未确认。本页不维护随工作区变化的文件数或检查统计。

实现依据：[mpv 输入绑定](https://mpv.io/manual/master/#property-list-input-bindings)、[脚本入口](https://mpv.io/manual/master/#script-location)、[命名绑定实现](https://github.com/mpv-player/mpv/blob/master/player/lua/defaults.lua)。

## 上游脚本与着色器维护

`M` 或菜单“工具与高级 → 维护 → 检查脚本与着色器更新”先获取 `manager.json` 指定的源并预览，选择“应用安全更新并备份”才修改目标。获取失败会中止整个预览，不使用旧下载结果。源仓库仅位于忽略的 `cache/manager/sources/`，不在脚本目录创建 Git 仓库或修改项目远端。

- 首次遇到与上游不同的现有文件，或文件与上次安装的上游基线不同，均标为“本地差异，保留”。已提交的本地定制同样受保护；不会以 Git 工作区干净为由覆盖。
- 与上游完全相同的文件会在应用时建立基线；以后仅自动更新仍与该基线一致的文件。没有基线的差异需人工比较合并，工具不提供强制覆盖。
- 应用前及逐文件写入前再次核对预览快照。先暂存全部内容并备份原文件，安装失败时尝试恢复本次已改文件；任何恢复失败会明确报错。
- 备份在 `cache/manager/backups/`，`manifest.json` 对应目标、状态及原始 `.old` 文件。手动恢复前先退出播放器；备份不自动清理、不随发布包分发。
- 更新后重启播放器。预览/取消入口分别为 `script-message-to manager manager-update-all`、`script-message-to manager manager-cancel`；应用入口为 `script-message-to manager manager-apply`，必须先在当前进程预览。

本地维护实现为 `scripts/manager.lua` 与 `script-modules/managed-update.lua`；更新其他脚本时保留这些修改。隔离本地 Git 源的回归：`python tools/test_manager.py`，不下载上游也不更新日常配置。
