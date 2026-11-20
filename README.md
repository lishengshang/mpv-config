# Linux mpv 配置

适用于 Linux 的精简配置，使用 mpv 自带的界面、快捷键和渲染设置。配置启用自动硬件解码，并在退出时记录播放位置。

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

临时用 mpv 的默认配置播放：

```bash
mpv --no-config -- video.mp4
```
