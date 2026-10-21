## MPV config

### 项目介绍

本项目是由 [lishengshang](https://github.com/lishengshang) 独立维护的 Windows [mpv](https://github.com/mpv-player/mpv) 配置与脚本集，基于 [dyphire/mpv-config](https://github.com/dyphire/mpv-config) 持续修改，保留第三方脚本、着色器的来源与许可。

当前配置使用 `gpu-next` / D3D11，GPU 增强面向 NVIDIA RTX，按需开启。主要入口包括 uosc 菜单、GPU 增强、AI 字幕，以及配置检查、更新预览和播放诊断；具体依赖与验证边界见下方说明。

**配置下载**：[本仓库](https://github.com/lishengshang/mpv-config)。仓库提供配置、脚本和着色器，不包含 mpv 播放器、外部运行时及 AI 模型。

### 第一次使用

1. 备份已有播放器配置，准备支持 `gpu-next` / D3D11 的 Windows 64 位 mpv，保留播放器包内的 DLL 等文件。下载本仓库源码时，还需另备播放器；若使用本项目播放器发行包，按其 Release 说明解压，包内已有配置时跳过重复安装。
2. 将本仓库内容放入 `mpv.exe` 同级的 `portable_config/`，确认文件是 `portable_config/mpv.conf`，不要多套一层目录。也可放入 `%APPDATA%/mpv/`；存在便携配置时优先使用便携配置。VS 安装与迁移工具按便携目录布局设计，准备使用这些功能时采用前一种布局。
3. 启动 `mpv.exe`，拖入本地视频，右键打开菜单。先确认播放、声音和已有字幕正常，再按下面的用途添加可选功能。基础播放不要求安装 Python、VS 或 AI 模型。

需要填写本机路径或私人 API key 时，参照 [local.conf.example](local.conf.example) 创建自己的 `local.conf`，该文件已从 Git 排除。更新配置前备份本地修改、`local.conf` 及需要保留的字幕缓存，不用别人的私人配置覆盖自己的设置。

### 按需求选择

| 你的需求或环境 | 怎么用 | 继续阅读 |
| --- | --- | --- |
| 只想看视频、使用已有字幕 | 完成上面的三步，通过右键菜单选择音轨、字幕和播放设置；不必运行测试或安装 AI/VS | [菜单与快捷键](input.conf) |
| 核显、AMD 或暂不安装增强组件 | 从基础播放开始；随配置提供的 shader 可按需尝试，RTX VS 方案不作为通用硬件方案 | [GPU 依赖与兼容范围](docs/gpu-setup.md) |
| NVIDIA RTX，想超分、补帧或降噪 | 从菜单“画质增强 → 画面增强”按需选择；需要 VS 的方案先安装匹配运行时、插件与模型，再做 GPU 自检 | [GPU 快速上手](docs/gpu-setup.md) |
| 视频没有字幕，想本地生成 | 先部署 Whisper 后端和模型，再按 `Alt+f`；Qwen 是另需部署的可选后端。翻译额外需要自己的接口和 key | [AI 字幕](docs/ai-subtitles.md) |
| 换电脑、移动播放器或补装组件 | 使用便携目录布局和可信组件清单，通过 `tools/components.cmd` 检查、安装或修复路径 | [组件安装与迁移](docs/config-checks.md#组件安装与迁移) |
| 想调参、维护或参与开发 | 修改对应配置后运行 `tools/check-config.cmd`；测试在 `tools/tests/`，构建与发布在 `tools/release/` | [工具目录](docs/config-checks.md#工具目录)、[开发约束](AGENTS.md) |

`tools/` 顶层保留 Windows 操作入口，普通用户按需使用即可；子目录包含播放器会调用的辅助程序，请随配置一起保留。配置检查需要 Python 3.10+，优先使用 mpv 同级的便携 Python；检查通过不代表 GPU 或字幕已在你的电脑上验收。

播放器预发布、源码配置和可选组件是不同下载内容。公开组件清单尚未接入发行配置，不能把仓库源码或播放器候选包当作离线 AI/VS 完整版；使用预发布前核对对应说明中的依赖与已测范围。发行流程见 [发行说明](docs/config-checks.md#正式版跟随与预发布)。

PS：自行编辑文本时使用 UTF-8、LF；脚本选项的注释单独占行，避免改变参数值。

### mpv 客户端

- Windows 构建入口见 [mpv 官方安装页](https://mpv.io/installation/)，其中列有 [shinchiro Windows 构建](https://github.com/shinchiro/mpv-winbuild-cmake/releases)。
- 使用支持 `gpu-next` / D3D11 的 64 位 mpv，并保留所选发行包附带的 DLL 和其他运行文件；本仓库不能替代完整播放器发行包。
- 可选 VS 运行时、插件、模型及新电脑自检见 [GPU 快速上手](docs/gpu-setup.md)。其他前端及硬件组合需单独验证。

### 脚本着色器说明

- **菜单与键位**：右键打开 uosc 主菜单，与底部菜单按钮共用入口；完整键位与菜单项见 [input.conf](input.conf)。
- **GPU 增强**：菜单“画质增强 → 画面增强”（按需求分组，模型名在后一层）；安装、对比与恢复、限制见 [GPU 快速上手](docs/gpu-setup.md)，VS 预设及模型对应见 [vs/README.md](vs/README.md)。
- **AI 字幕**：`Alt+f` 或菜单“字幕 → 下载／生成”，默认 Whisper，可选 Qwen；管理、重新生成、缓存与导出见 [AI 字幕](docs/ai-subtitles.md)。
- **HDR 与蓝光 ISO**：`toggleHDR` 按视频类型自动切换 Windows HDR 显示模式并在播放结束后恢复，需 [HDRTray](https://github.com/res2k/HDRTray/releases) 的 `HDRCmd.exe`，路径写在 `local.conf`（模板见 [local.conf.example](local.conf.example)），未配置则不接管；`auto_bluray` 把拖入或命令行传入的 `.iso` 改走 `bd://` 播放，只认扩展名、不处理 BDMV 文件夹，非蓝光 ISO 会打开失败。
- **维护与诊断**：菜单“工具与高级 → 维护”，提供脚本与着色器更新预览、组件诊断和播放采样；操作与结果解释见 [配置检查](docs/config-checks.md)。
- **组件安装与迁移**：双击 `tools/components.cmd` 检查、从固定清单安装 VS/Whisper/Qwen，或修复搬家后的路径；[用法与限制](docs/config-checks.md#组件安装与迁移)。

全局选项见 [mpv.conf](mpv.conf)，配置组见 [profiles.conf](profiles.conf)，脚本参数位于 [script-opts/](script-opts/)，着色器位于 [shaders/](shaders/)。[archive/](archive/) 为历史归档，不是默认启用区。

本仓库独立维护，按需同步配置上游，不自动覆盖本地定制。本地 `upstream` 指向 `https://github.com/dyphire/mpv-config.git`；新克隆的副本需自行添加该远端。同步前先备份并确认工作区状态，使用 `git fetch upstream` 获取更新，在单独分支比较、合并并验证后再纳入日常配置。菜单内的脚本与着色器更新和仓库上游同步是两项独立操作。

开发约束见 [AGENTS.md](AGENTS.md)，接手在途工作时再核对 [PROJECT_STATE.md](PROJECT_STATE.md)。

### 预览

以下保留原配置上游的历史截图，展示原有界面；当前功能、键位与验收范围以本仓库说明为准。

 ![image-20231103224421000](https://cdn.jsdelivr.net/gh/dyphire/PicGo/img/2023/11/03/image-20231103224421000.png)

![image-20231103224540075](https://cdn.jsdelivr.net/gh/dyphire/PicGo/img/2023/11/03/image-20231103224540075.png)

![image-20231103224557019](https://cdn.jsdelivr.net/gh/dyphire/PicGo/img/2023/11/03/image-20231103224557019.png)

| 拼音搜索（支持首字母）                                                                                    | 字幕下载                                                                                           |
| ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| ![image](https://cdn.jsdelivr.net/gh/dyphire/PicGo/img/2023/11/03/image-20231103224614449.png) | ![image](https://cdn.jsdelivr.net/gh/dyphire/PicGo/img/2023/11/03/image-20231103224721066.png) |

### 参考

* [hooke007 配置手册](https://hooke007.github.io/mpv-lazy/mpv.html)
* [mpv 原版官方的开发版手册（英文）](https://mpv.io/manual/master/)
* [mpv 官方文档的汉化版-hooke007](https://github.com/hooke007/mpv_doc-CN)

### 致谢

* [dyphire/mpv-config](https://github.com/dyphire/mpv-config)：本项目的配置基础、脚本整合与原预览截图。
* [mpv](https://github.com/mpv-player/mpv)、[uosc](https://github.com/tomasklaen/uosc) 及随仓库提供的第三方脚本、着色器作者。
* [mpv_PlayKit / k7sfunc](https://github.com/hooke007/mpv_PlayKit)、[vs-mlrt](https://github.com/AmusementClub/vs-mlrt)、[ArtCNN](https://github.com/Artoriuz/ArtCNN)：可选 GPU 增强所用的预设基础、推理组件与模型/着色器。
* [faster-whisper-xxl](https://github.com/Purfview/whisper-standalone-win)、[Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR)：AI 字幕所用的外部识别后端。

第三方组件沿用各自许可，详见 [LICENSE.MD](LICENSE.MD)、组件目录内的许可证与源码声明；独立维护不改变这些组件的来源与署名。
