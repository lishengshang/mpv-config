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
- 通过「打开与文件 → 播放历史」继续播放本地文件或已挂载的视频。将鼠标停在进度条上可预览支持的视频。

随配置提供 [uosc](https://github.com/tomasklaen/uosc)、[thumbfast](https://github.com/po5/thumbfast) 和 [UndoRedo](https://github.com/Eisa01/mpv-scripts)。播放参数和键位的上游为 [本仓库的 Windows 配置](https://github.com/lishengshang/mpv-config/tree/dev) 和 [dyphire/mpv-config](https://github.com/dyphire/mpv-config)。

## OpenList 同目录选集

在 Firefox 的 OpenList 视频页点击 `mpv`，从选中的一集开始播。`F5` 或底栏列表图标会打开同目录播放列表，`o` 会打开该集所在目录。也可以在 GNOME Files 的 WebDAV 挂载目录直接打开任意一集。

挂载 OpenList WebDAV 后，在本机的 `script-opts/openlist.conf` 写入站点地址和挂载路径。站点地址填写浏览器使用的地址，包含实际端口和应用前缀。挂载中的相对路径需要与站点下载链接的文件路径一致。此文件由 Git 忽略。

```ini
base_url=http://127.0.0.1:5244
mount_path=~/Videos/OpenList
```

浏览器沿用现有的 `mpv://` 关联。配置会在挂载中查找与本站下载、代理或 WebDAV 路径对应的媒体文件；挂载里找不到对应文件时，mpv 继续播放原链接。

## 从 Windows 同步配置

`dev` 提供 Windows 配置，`linux` 独立发布。每次先核对新的 `dev` 提交，再按功能把通用改动移到 `linux`。同步范围是基础播放，包括键位、菜单、音轨、字幕、续播、截图和播放器脚本。图形和音频后端、路径分隔符、WebDAV 映射按 Linux 环境设置。

本轮已审查的 `dev` 基线为 `3da305a9bc0acf1a6fc3659d765bd6f690b7d028`。可先查看远端提交号，或者打开 GitHub 看最近的变化。[查看 dev 更新](https://github.com/lishengshang/mpv-config/compare/3da305a9bc0acf1a6fc3659d765bd6f690b7d028...dev)

```bash
git ls-remote --refs origin refs/heads/dev
```

有更新时，在 `linux` 工作区取 `dev` 的变更。`git fetch` 只读取远端。移除 `--stat` 可看各文件的具体差异。

```bash
dev_base=3da305a9bc0acf1a6fc3659d765bd6f690b7d028
git fetch --no-tags origin refs/heads/dev
git diff --stat "$dev_base" FETCH_HEAD -- input.conf mpv.conf profiles.conf \
    script-opts/uosc.conf script-opts/thumbfast.conf scripts/uosc scripts/thumbfast.lua scripts/undoredo.lua
```

对照新键位、`#menu:` 菜单项和脚本入口，确认命令在 Linux 可用。运行 `git diff --check` 和 `python3 tools/check-linux.py`。回归检查使用 mpv、FFmpeg 和 Python 3 生成临时片段，验证第 2 项起播、`F5` 选集和 `o` 定位目录。涉及 OpenList 时再用实际挂载打开一集。

审核完毕后，在同次 Linux 提交更新本节的 `dev` 基线和比较链接。机器地址与播放记录留在本机。发布时明确推送 `linux`。

```bash
git push origin refs/heads/linux:refs/heads/linux
```

## 临时使用默认配置

```bash
mpv --no-config -- video.mp4
```
