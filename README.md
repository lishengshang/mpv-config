## MPV config

### 项目介绍

本项目是由 [lishengshang](https://github.com/lishengshang) 独立维护的 Windows [mpv](https://github.com/mpv-player/mpv) 配置与脚本集，基于 [dyphire/mpv-config](https://github.com/dyphire/mpv-config) 持续修改，保留第三方脚本、着色器的来源与许可。

当前配置使用 `gpu-next` / D3D11，GPU 增强面向 NVIDIA RTX，按需开启。主要入口包括 uosc 菜单、GPU 增强、AI 字幕，以及配置检查、更新预览和播放诊断；具体依赖与验证边界见下方说明。

**配置下载**：[本仓库](https://github.com/lishengshang/mpv-config)。仓库提供配置、脚本和着色器，不包含 mpv 播放器、外部运行时及 AI 模型。

将配置放入 `mpv.exe` 同级的 `portable_config/` 文件夹，目录应为 `portable_config/mpv.conf`，不要再嵌套一层仓库目录。也可使用 Windows 默认用户配置目录 `%APPDATA%/mpv/`；存在 `portable_config/` 时，mpv 优先使用便携配置目录。

首次使用前备份已有配置；需要机器路径或私人 API key 时，参照 [local.conf.example](local.conf.example) 创建 `local.conf`，该文件已从 Git 排除。轻量 ArtCNN shader 随配置提供；VS 增强和 AI 字幕需另行部署相应依赖。

修改配置后双击 `tools/check-config.cmd`，检查配置引用、等价键位与脚本接线。此工具需要 Python 3.10+，优先使用 mpv 同级的便携 Python；静态检查与原生命令解析通过不等于媒体、GPU 或字幕功能验收通过，详见 [配置检查](docs/config-checks.md)。

PS：自行编辑文本时使用 UTF-8、LF；脚本选项的注释单独占行，避免改变参数值。

### mpv 客户端

- Windows 构建入口见 [mpv 官方安装页](https://mpv.io/installation/)，其中列有 [shinchiro Windows 构建](https://github.com/shinchiro/mpv-winbuild-cmake/releases)。
- 使用支持 `gpu-next` / D3D11 的 64 位 mpv，并保留所选发行包附带的 DLL 和其他运行文件；本仓库不能替代完整播放器发行包。
- 可选 VS 运行时、插件、模型及新电脑自检见 [GPU 快速上手](docs/gpu-setup.md)。其他前端及硬件组合需单独验证。

### 脚本着色器说明

- **菜单与键位**：右键打开 uosc 主菜单，与底部菜单按钮共用入口；完整键位与菜单项见 [input.conf](input.conf)。
- **GPU 增强**：菜单“画质增强 → GPU 增强”；安装、恢复与限制见 [GPU 快速上手](docs/gpu-setup.md)，VS 预设及模型对应见 [vs/README.md](vs/README.md)。
- **AI 字幕**：`Alt+f` 或菜单“字幕 → 下载／生成”，默认 Whisper，可选 Qwen；管理、重新生成、缓存与导出见 [AI 字幕](docs/ai-subtitles.md)。
- **维护与诊断**：菜单“工具与高级 → 维护”，提供脚本与着色器更新预览、组件诊断和播放采样；操作与结果解释见 [配置检查](docs/config-checks.md)。

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
