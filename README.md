# Linux mpv 配置

适用于 Linux 的日用配置，使用 uosc 界面。自动硬解，退出时保存播放位置和所选轨道。自动加载同名外挂音轨和字幕，字幕优先简体中文、其次繁体中文。

安装发行版提供的 mpv。Arch Linux 上可以使用：

```bash
sudo pacman -S mpv
```

如果已有 `~/.config/mpv`，先把它移到备份目录。然后克隆此分支：

```bash
git clone --single-branch --branch linux https://github.com/lishengshang/mpv-config.git ~/.config/mpv
```

更新配置：

```bash
git -C ~/.config/mpv pull --ff-only
```

## 操作

- 单击视频或按空格播放和暂停，右键打开菜单，回车切换全屏。
- `F5` 打开播放列表，`F7` 选择章节，`F10` 选音轨，`F11` 选字幕。
- `Ctrl+Z` 撤销跳转，`Ctrl+X` 重做。用 `[` 和 `]` 调整倍速，退格键恢复 1 倍。
- 在支持的本地视频上把鼠标放到进度条可预览缩略图。文件管理器的「mpv（目录播放）」入口可以从选中的视频开始播放同目录的文件。

播放参数和快捷键参考 [dyphire/mpv-config](https://github.com/dyphire/mpv-config) 和本仓库的 `dev` 分支。随配置提供 [uosc](https://github.com/tomasklaen/uosc)、[thumbfast](https://github.com/po5/thumbfast) 和 [UndoRedo](https://github.com/Eisa01/mpv-scripts)。

临时用 mpv 的默认配置播放：

```bash
mpv --no-config -- video.mp4
```
