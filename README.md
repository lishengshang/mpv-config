# Linux mpv 配置

使用 uosc 界面，键位和播放偏好以本仓库的 `dev` 分支为基准。自动硬解和加载同名外挂轨道。字幕优先简体中文、其次繁体中文，音轨优先日语、其次英语。续播会恢复进度、倍速、音量和已选轨道。

安装支持 `--autocreate-playlist` 和 `--save-watch-history` 的 mpv，以及 Noto CJK 字体。本配置用 mpv 0.42 验证。Arch Linux 可以用下面的命令。

```bash
sudo pacman -S mpv noto-fonts-cjk
```

如果已有 `~/.config/mpv`，先将它移到备份目录，再克隆 `linux`。

```bash
git clone --single-branch --branch linux https://github.com/lishengshang/mpv-config.git ~/.config/mpv
```

在工作区干净时更新已安装的配置。

```bash
git -C ~/.config/mpv pull --ff-only origin linux
```

## 操作

- 右键或 `F4` 打开分组菜单。按 `F5` 或点底栏列表图标选集。按 `o` 或 `Ctrl+O` 浏览当前文件所在目录。
- `F6` 选音频输出，`F7` 选章节，`F8` 查看所有轨道，`F9` 选视频轨，`F10` 选音轨，`F11` 选字幕。`Alt+F11` 选次字幕。
- 左右方向键跳 5 秒，按住 `Shift` 精确跳 1 秒。`Ctrl+Z` 撤销跳转，`Ctrl+X` 重做。用 `[` 和 `]` 调倍速，退格键恢复 1 倍。
- `z` / `x` 调字幕延迟，`Ctrl+,` / `Ctrl+.` 调音频延迟。`s` 截图，图片保存在 `~/Pictures/mpv`。
- `Ctrl+←` / `Ctrl+→` 跳到上一条／下一条字幕。先按 `g`，再按 `l` 或 `Shift+L` 打开主字幕／次字幕台词列表。右键「字幕」可以调整次字幕和切换字体。mpv 会为当前视频加载同目录 `Fonts` 或 `fonts` 中的字体。
- `A` 切宽高比，`w` / `Shift+W` 调裁切范围，`1`–`8` 调色。90° 旋转、色相和恢复默认在「画面」菜单。`Shift+O` 常显时间与帧号，`Shift+I` 常显播放统计。
- 在「音频 → 音量均衡」里选动态均衡或响度标准化，可随时关闭。切换保留播放时已有的其他音频滤镜。
- 通过「打开与文件 → 播放历史」继续播放本地文件或已挂载的视频。将鼠标停在进度条上可预览支持的视频。

随配置提供 [uosc](https://github.com/tomasklaen/uosc)、[thumbfast](https://github.com/po5/thumbfast)、[UndoRedo](https://github.com/Eisa01/mpv-scripts) 和来自 `dev` 的外挂字体脚本。常用键位参考 [mpv 默认键位](https://github.com/mpv-player/mpv/blob/v0.42.0/etc/input.conf)。播放配置参考 [Windows dev](https://github.com/lishengshang/mpv-config/tree/dev) 和 [dyphire/mpv-config](https://github.com/dyphire/mpv-config)。

## 画质预设

右键或按 `F4`，进入「画质增强」。基础预设包含高质量缩放、三档去色带、抖动、自动色彩目标、HDR 转 SDR 和显示同步。显示同步使用 mpv 内置的帧混合。

- `Alt+1` 到 `Alt+8` 沿用 Windows 的 Shader 组合键位。菜单还提供 AniSD 和 SSIM。`Ctrl+1` 到 `Ctrl+9` 选择单项 Shader，`Ctrl+Alt+1` / `Ctrl+Alt+2` 选择两档 ArtCNN。
- 预设在当前播放器实例里生效。同一类一次只选一项，再选一次即可关闭。`Ctrl+0` 关闭所选 Shader，「恢复原画质」恢复菜单选择前的选项。直接启动时可以用 `mpv --profile=NNEDI3 -- video.mp4`。
- Shader 由 mpv 的 GPU 渲染器运行，随仓库提供。放大和缩小 Shader 按实际渲染尺寸生效，负载随片源和窗口大小变化。AnimeJaNai 等预设首次启用时可能需要等待驱动编译。自动 ICC 和 HDR 直通取决于系统提供的显示色彩配置。

Shader 文件保留 `dev` 的内容和许可声明。FSRCNNX、SSIM、KrigBilateral、NNEDI3 和 RAVU 的 GPL/LGPL 文本在 `licenses/`。AnimeJaNai 使用 CC BY-NC-SA 4.0，Sirosky 的 Ani4K 和 AniSD 模型使用 CC BY-NC 4.0。[FSRCNNX](https://github.com/igv/FSRCNN-TensorFlow) · [NNEDI3 与 RAVU](https://github.com/bjin/mpv-prescalers) · [AnimeJaNai](https://github.com/the-database/mpv-AnimeJaNai) · [Ani4K 与 AniSD](https://github.com/lishengshang/mpv-config/tree/3da305a9bc0acf1a6fc3659d765bd6f690b7d028/shaders/Ani4k) · [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) · [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/)

## OpenList 同目录选集

在 Firefox 的 OpenList 视频页点击 `mpv`，从选中的一集开始播。`F5` 或底栏列表图标会打开同目录播放列表，`o` 会打开该集所在目录。也可以在 GNOME Files 的 WebDAV 挂载目录直接打开任意一集。

挂载 OpenList WebDAV 后，在本机的 `script-opts/openlist.conf` 写入站点地址和挂载路径。站点地址填写浏览器使用的地址，包含实际端口和应用前缀。挂载中的相对路径需要与站点下载链接的文件路径一致。此文件由 Git 忽略。

```ini
base_url=http://127.0.0.1:5244
mount_path=~/Videos/OpenList
```

浏览器沿用现有的 `mpv://` 关联。配置会在挂载中查找与本站下载、代理或 WebDAV 路径对应的媒体文件；挂载里找不到对应文件时，mpv 继续播放原链接。

## 从 Windows 同步配置

`dev` 提供 Windows 配置，`linux` 独立发布。每次先核对新的 `dev` 提交，再按功能把通用改动移到 `linux`。同步范围包含基础播放和可在 mpv 内运行的 GLSL 画质预设。图形和音频后端、路径分隔符、WebDAV 映射按 Linux 环境设置。

本轮已审查的 `dev` 基线为 `3da305a9bc0acf1a6fc3659d765bd6f690b7d028`。可先查看远端提交号，或者打开 GitHub 看最近的变化。[查看 dev 更新](https://github.com/lishengshang/mpv-config/compare/3da305a9bc0acf1a6fc3659d765bd6f690b7d028...dev)

```bash
git ls-remote --refs origin refs/heads/dev
```

有更新时，在 `linux` 工作区取 `dev` 的变更。`git fetch` 只读取远端。移除 `--stat` 可看各文件的具体差异。

```bash
dev_base=3da305a9bc0acf1a6fc3659d765bd6f690b7d028
git fetch --no-tags origin refs/heads/dev
git diff --stat "$dev_base" FETCH_HEAD -- input.conf mpv.conf profiles.conf \
    script-opts/uosc.conf script-opts/thumbfast.conf scripts/uosc scripts/thumbfast.lua scripts/undoredo.lua \
    scripts/sub-fonts-dir-auto.lua shaders/
```

对照新键位、`#menu:` 菜单项和脚本入口，确认命令在 Linux 可用。运行 `git diff --check` 和 `python3 tools/check-linux.py`。回归检查通过临时片段验证第 2 项起播、`F5` 选集、`o` 定位目录、画质恢复和音量均衡。涉及 OpenList 时再用实际挂载打开一集。涉及 Shader 时，用 GPU 渲染确认实际出帧。

审核完毕后，在同次 Linux 提交更新本节的 `dev` 基线和比较链接。机器地址与播放记录留在本机。发布时明确推送 `linux`。

```bash
git push origin refs/heads/linux:refs/heads/linux
```

## 临时使用默认配置

```bash
mpv --no-config -- video.mp4
```
