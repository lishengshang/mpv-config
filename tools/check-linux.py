"""Exercise the Linux configuration with temporary media and an OpenList URL."""

import json
import shutil
import socket
import subprocess
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import quote


def wait_for(probe, ready, description, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = probe()
        if ready(result):
            return result
        time.sleep(0.05)
    raise RuntimeError(description)


def check_quality_controls(command, read):
    def expect(property_name, value):
        wait_for(lambda: read(property_name), lambda actual: actual == value,
                 f"{property_name} did not reach {value!r}")

    original_shaders = read("glsl-shaders")
    original_scale = read("scale")
    original_deband = read("deband")
    custom_shaders = ["~~/shaders/igv/adaptive-sharpen.glsl"]
    command("set_property", "glsl-shaders", custom_shaders)
    command("keypress", "Alt+1")
    expect("glsl-shaders", [
        "~~/shaders/igv/FSRCNNX_x2_8-0-4-1.glsl", "~~/shaders/igv/SSimDownscaler.glsl",
    ])
    command("keypress", "Alt+7")
    expect("glsl-shaders", [
        "~~/shaders/nnedi3/nnedi3-nns32-win8x4.glsl", "~~/shaders/igv/SSimDownscaler.glsl",
    ])
    command("keypress", "Ctrl+0")
    expect("glsl-shaders", custom_shaders)
    command("set_property", "glsl-shaders", original_shaders)

    command("script-message-to", "quality", "select", "deband", "DeBand-medium")
    expect("deband-iterations", 2)
    command("keypress", "D")
    expect("deband", original_deband)
    command("script-message-to", "quality", "select", "scale", "HQ")
    expect("scale", "ewa_lanczossharp")
    command("script-message-to", "quality", "restore-all")
    expect("scale", original_scale)


def check_audio_controls(command, read, menu_open):
    original = read("af")
    command("af", "add", "@test-volume:volume=0.8")
    existing = read("af")

    for keys, name in ((("HOME",), "dynaudnorm"), (("HOME", "DOWN"), "loudnorm"), (("END",), None)):
        command("script-message-to", "menu_ui", "open", "音频 > 音量均衡")
        wait_for(menu_open, bool, "Audio normalization menu did not open")
        for key in keys:
            command("keypress", key)
        command("keypress", "ENTER")
        label = {"dynaudnorm": "动态均衡", "loudnorm": "响度标准化", None: "关闭"}[name]
        wait_for(lambda: menu_entry(read, "音频 > 音量均衡 > " + label).get("active"), bool,
                 "Audio normalization selection was not updated")
        assert menu_open()
        filters = read("af")
        if name is None:
            assert filters == existing
        else:
            assert filters[:-1] == existing
            assert filters[-1]["label"] == "audio-normalization"
            assert name in json.dumps(filters[-1])
        command("script-message-to", "uosc", "close-menu", "menu-ui")
        wait_for(menu_open, lambda visible: not visible, "Audio normalization menu did not close")

    command("set_property", "af", original)


@contextmanager
def player_session(config, root, opened):
    ipc_path = root / "mpv.sock"
    log_path = root / "mpv.log"
    ipc_path.unlink(missing_ok=True)
    args = [
        "mpv", f"--config-dir={config}", "--vo=null", "--ao=null",
        "--pause", "--idle", "--no-terminal", "--network-timeout=1",
        f"--input-ipc-server={ipc_path}",
        f"--log-file={log_path}", f"--watch-later-dir={root / 'watch_later'}",
        f"--watch-history-path={root / 'history.jsonl'}",
        "--script-opts=openlist-base_url=http://127.0.0.1:9,"
        f"openlist-mount_path={root / 'mount'},local-files-state_dir={root / 'state'},"
        f"local-files-export_dir={root / 'exports'}", "--", opened,
    ]
    with subprocess.Popen(args) as player:
        try:
            wait_for(ipc_path.exists, bool, "mpv IPC socket did not start")
            with socket.socket(socket.AF_UNIX) as ipc:
                ipc.settimeout(5)
                ipc.connect(str(ipc_path))
                with ipc.makefile("rwb") as stream:
                    def command(*args):
                        request = {"command": args, "request_id": 1}
                        stream.write(json.dumps(request).encode() + b"\n")
                        stream.flush()
                        for line in stream:
                            reply = json.loads(line)
                            if reply.get("request_id") != 1:
                                continue
                            if reply["error"] in {"property unavailable", "property not found"} and args[0] == "get_property":
                                return None
                            if reply["error"] != "success":
                                raise RuntimeError(f"{args}: {reply['error']}")
                            return reply.get("data")
                        if args != ("quit",):
                            raise RuntimeError(f"mpv exited during {args}")

                    def read(name):
                        return command("get_property", name)

                    yield command, read
                    command("quit")
                    if player.wait(timeout=5) != 0:
                        raise RuntimeError("mpv did not exit cleanly")
            for line in log_path.read_text().splitlines():
                if "][e]" in line or "][f]" in line:
                    raise RuntimeError(line)
        finally:
            if player.poll() is None:
                player.kill()


def check_player(config, root, opened, selected, episode_count):
    with player_session(config, root, opened) as (command, read):
        wait_for(lambda: read("time-pos"), lambda value: value is not None,
                 "Selected episode did not start")
        assert read("path") == str(selected)
        assert read("playlist-count") == episode_count
        assert read("playlist-pos") == 1
        assert all(
            Path(entry["filename"]).parent == selected.parent
            and entry["filename"].endswith(".mp4")
            for entry in read("playlist")
        )
        check_quality_controls(command, read)
        check_audio_controls(command, read, lambda: menu_open(read))
        command("keypress", "F5")
        wait_for(lambda: menu_open(read), bool, "F5 did not open the uosc playlist")
        command("keypress", "END")
        command("keypress", "ENTER")
        last_name = f"第 {episode_count:02} 集.mp4"
        wait_for(lambda: read("filename"), lambda name: name == last_name,
                 "Selecting the last episode from uosc failed")
        wait_for(lambda: menu_open(read), lambda visible: not visible, "Playlist menu did not close")
        command("keypress", "o")
        wait_for(lambda: menu_open(read), bool, "o did not open the current directory")
        command("keypress", "HOME")
        command("keypress", "DOWN")
        command("keypress", "ENTER")
        wait_for(lambda: read("filename"), lambda name: name == "第 01 集.mp4",
                 "The uosc file browser did not open the episode directory")


def menu_open(read):
    return any(binding.get("owner") == "uosc" and binding["key"] == "ESC"
               for binding in read("input-bindings"))


def menu_entry(read, item_id):
    menu = read("user-data/menu-ui/menu") or {}
    items = list(menu.get("items", []))
    while items:
        item = items.pop()
        if item.get("id") == item_id:
            return item
        items.extend(item.get("items", []))
    return {}


def check_menu_controls(command, read):
    command("keypress", "F4")
    wait_for(lambda: read("user-data/uosc/menu/type"), lambda mode: mode == "menu-ui",
             "F4 did not show the dynamic menu")
    command("set_property", "mute", True)
    wait_for(lambda: menu_entry(read, "音频 > 静音").get("active"), bool,
             "The mute indicator did not update")
    command("set_property", "mute", False)
    wait_for(lambda: menu_entry(read, "音频 > 静音").get("active"), lambda value: value is False,
             "The mute indicator did not clear")
    command("script-message-to", "uosc", "close-menu", "menu-ui")
    wait_for(lambda: menu_open(read), lambda visible: not visible, "The main menu did not close")

    command("script-message-to", "menu_ui", "open", "画面 > 宽高比")
    wait_for(lambda: menu_open(read), bool, "Aspect ratio choices did not open")
    command("keypress", "HOME")
    command("keypress", "DOWN")
    command("keypress", "ENTER")
    wait_for(lambda: menu_entry(read, "画面 > 宽高比").get("items", [{}, {}])[1].get("active"), bool,
             "The selected aspect ratio was not highlighted")
    assert abs(read("video-aspect-override") - (4 / 3)) < 0.001
    command("set", "video-aspect-override", "no")
    command("script-message-to", "uosc", "close-menu", "menu-ui")
    wait_for(lambda: menu_open(read), lambda visible: not visible, "Aspect ratio panel did not close")

    command("keypress", "F8")
    menu = wait_for(lambda: read("user-data/menu-ui/menu"), lambda value: value and value["title"] == "选择轨道",
                    "F8 did not display the track panel")
    assert [item["title"] for item in menu["items"]] == ["视频", "音频", "主字幕", "次字幕"]
    command("script-message-to", "uosc", "close-menu", "menu-ui")
    wait_for(lambda: menu_open(read), lambda visible: not visible, "The track panel did not close")

    command("script-message-to", "menu_ui", "open", "打开与文件")
    wait_for(lambda: menu_open(read), bool, "The file menu did not open")
    files = menu_entry(read, "打开与文件")["items"]
    index = next(i for i, item in enumerate(files, 1) if item["id"] == "打开与文件 > 播放历史…")
    command("script-message-to", "uosc", "select-menu-item", "menu-ui", str(index), "打开与文件")
    command("keypress", "ENTER")
    wait_for(lambda: read("user-data/mpv/console/open"), bool, "The native watch history did not open")
    command("keypress", "ESC")
    wait_for(lambda: read("user-data/mpv/console/open"), lambda opened: not opened, "The native history did not close")


def seek(command, read, target):
    wait_for(lambda: read("time-pos"), lambda pos: pos is not None, "Playback did not start")
    command("seek", target, "absolute+exact")
    return wait_for(lambda: read("time-pos"), lambda pos: pos is not None and abs(pos - target) < 0.08,
                    f"Did not seek to {target}")


def invoke(command, action, *args):
    command("script-message-to", "local_tools", action, *args)


def latest_export(root, category, pattern):
    return wait_for(lambda: sorted((root / "exports" / category).glob(pattern)), bool,
                    f"No {category} exported", timeout=20)[-1]


def check_library(config, root, selected, episode_count):
    other = root / "Outside OpenList.mp4"
    other.hardlink_to(selected)
    with player_session(config, root, str(selected)) as (command, read):
        wait_for(lambda: read("playlist-count"), lambda count: count == episode_count,
                 "OpenList did not expand the directory")
        position = seek(command, read, 0.8)
        assert read("save-watch-history")
        check_menu_controls(command, read)
        original_id = read("playlist")[read("playlist-playing-pos")]["id"]

        command("script-message-to", "menu_ui", "open", "播放 > 播放列表整理")
        wait_for(lambda: menu_open(read), bool, "Sort menu absent")
        command("keypress", "HOME")
        command("keypress", "DOWN")
        command("keypress", "ENTER")
        wait_for(lambda: read("playlist")[0]["filename"], lambda path: Path(path).name == "第 33 集.mp4",
                 "Sorting from the menu failed")
        assert read("playlist")[-1]["filename"].endswith("第 01 集.mp4")
        assert read("playlist")[read("playlist-playing-pos")]["id"] == original_id
        assert read("time-pos") == position

        ordered = read("playlist")
        command("playlist-shuffle")
        shuffled = read("playlist")
        assert shuffled != ordered
        assert {entry["id"] for entry in shuffled} == {entry["id"] for entry in ordered}
        assert read("playlist")[read("playlist-playing-pos")]["id"] == original_id
        assert read("time-pos") == position

        invoke(command, "save-playlist")
        playlist = latest_export(root, "playlists", "*.m3u8")
        assert playlist.read_text().splitlines() == ["#EXTM3U", *(item["filename"] for item in shuffled)]
        invoke(command, "save-bookmark", "position")
        wait_for(lambda: list((root / "state" / "bookmarks").glob("*.json")), bool,
                 "Progress bookmark was not written locally")
        command("loadfile", str(other), "replace")
        wait_for(lambda: read("path"), lambda path: path == str(other), "Outside file did not load")
        invoke(command, "bookmarks")
        wait_for(lambda: menu_open(read) and read("user-data/uosc/menu/type") == "bookmarks", bool,
                 "Bookmarks did not open in uosc")
        command("keypress", "ENTER")
        wait_for(lambda: read("path"), lambda path: path == str(selected), "Bookmark did not open the episode")
        wait_for(lambda: read("time-pos"), lambda pos: pos is not None and abs(pos - position) < 0.08,
                 "Bookmark did not restore the saved point")
        assert read("playlist-count") == episode_count
        command("loadlist", str(playlist), "replace")
        wait_for(lambda: [item["filename"] for item in read("playlist")],
                 lambda paths: paths == [item["filename"] for item in shuffled],
                 "The saved playlist did not reopen with its order and paths intact")


def make_media_fixture(root):
    info = root / "chapters.txt"
    info.write_text(";FFMETADATA1\n"
                    "[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1600\ntitle=OP\n"
                    "[CHAPTER]\nTIMEBASE=1/1000\nSTART=1600\nEND=13000\ntitle=Main\n"
                    "[CHAPTER]\nTIMEBASE=1/1000\nSTART=13000\nEND=16000\ntitle=ED\n")
    subtitle = root / "offset.srt"
    tones = [(0.6, 2.4), (3.4, 4.5), (7.2, 8.8), (10.3, 11.2)]

    def tone(delay):
        speaking = "+".join(f"between(t\\,{start + delay}\\,{end + delay})" for start, end in tones)
        return f"aevalsrc=0.4*sin(2*PI*380*t)*({speaking}):s=16000:d=16"

    def srt_time(second):
        seconds, ms = divmod(round(second * 1000), 1000)
        return f"00:00:{seconds:02d},{ms:03d}"

    subtitle.write_text("\n".join(
        f"{index}\n{srt_time(start + 1)} --> {srt_time(end + 1)}\n字幕 {index}\n"
        for index, (start, end) in enumerate(tones, 1)))
    video = root / "video.mp4"
    audio = [root / "other.wav", root / "reference.wav"]
    ffmpeg = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error"]
    subprocess.run([*ffmpeg, "-f", "lavfi", "-i", "testsrc2=s=160x90:r=20:d=16",
                    "-c:v", "mpeg4", "-g", "20", str(video)], check=True, timeout=10)
    for delay, track in zip((2, 0), audio):
        subprocess.run([*ffmpeg, "-f", "lavfi", "-i", tone(delay), str(track)], check=True, timeout=10)
    source = root / "片段 [% # ?], '双音轨.mkv"
    subprocess.run([
        *ffmpeg, "-i", str(video), "-i", str(audio[0]), "-i", str(audio[1]), "-i", str(subtitle), "-i", str(info),
        "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-map_chapters", "4",
        "-metadata:s:a:1", "title=Reference", "-c", "copy", "-c:a", "aac", str(source),
    ], check=True, timeout=15)
    return source


def check_media_tools(config, root, source):
    with player_session(config, root, str(source)) as (command, read):
        seek(command, read, 0.7)
        time.sleep(0.2)
        assert abs(read("time-pos") - 0.7) < 0.08, "Intro must wait for manual skip"
        invoke(command, "skip-segment")
        wait_for(lambda: read("time-pos"), lambda pos: abs(pos - 1.6) < 0.08,
                 "Manual chapter skip did not reach the next chapter")
        seek(command, read, 2.0)
        invoke(command, "chapter-edit", "title")
        wait_for(lambda: read("user-data/mpv/console/open"), bool, "Chapter title editor did not open")
        command("keypress", "END")
        command("keypress", "Ctrl+u")
        command("keypress", "e")
        command("keypress", "d")
        command("keypress", "i")
        command("keypress", "t")
        command("keypress", "ENTER")
        wait_for(lambda: read("chapter-list")[1]["title"], lambda title: title == "edit",
                 "Chapter title was not updated")
        seek(command, read, 4.3)
        invoke(command, "chapter-edit", "add")
        wait_for(lambda: read("user-data/mpv/console/open"), bool, "Add chapter console did not open")
        command("keypress", "ENTER")
        added = wait_for(lambda: read("chapter-list"), lambda items: len(items) == 4,
                         "Chapter was not added")
        assert added[2]["time"] == 4.3
        seek(command, read, 5.0)
        invoke(command, "chapter-edit", "time")
        wait_for(lambda: read("user-data/mpv/console/open"), bool, "Chapter time editor did not open")
        for key in ("END", "Ctrl+u", "1", "4", "ENTER"):
            command("keypress", key)
        wait_for(lambda: [item["time"] for item in read("chapter-list")],
                 lambda times: times == [0, 1.6, 13, 14], "Edited chapter did not move to its new position")
        invoke(command, "chapter-save", "chp")
        saved = wait_for(lambda: list((root / "state" / "chapters").glob("*.chp")), bool,
                         "Chapter edit was not saved locally")[0]
        invoke(command, "chapter-save", "ogm")
        assert "CHAPTER02NAME=" in latest_export(root, "chapters", "*.ogm").read_text()
        assert "edit" in saved.read_text()

        command("set_property", "aid", 2)
        command("set_property", "sid", 1)
        invoke(command, "subtitle-export")
        extracted = latest_export(root, "subtitles", "*.srt")
        assert "字幕 4" in extracted.read_text()
        if shutil.which("alass"):
            invoke(command, "subtitle-align")
            aligned = latest_export(root, "subtitles", "*对轴*.srt")
            assert "00:00:00," in aligned.read_text().splitlines()[1], aligned.read_text()
            wait_for(lambda: read("current-tracks/sub/external-filename"), lambda path: path == str(aligned),
                     "Aligned subtitle did not load on the current episode")

    with player_session(config, root, str(source)) as (command, read):
        wait_for(lambda: read("chapter-list"), lambda chapters: chapters and "edit" in chapters[1]["title"],
                 "Saved chapters did not override the embedded chapters when reopened")


def main():
    config = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="mpv-linux-") as scratch:
        root = Path(scratch)
        mount = root / "mount"
        season = mount / "剧集 100% #"
        season.mkdir(parents=True)
        episode_count = 33
        first = season / "第 01 集.mp4"
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
            "color=blue:size=80x46:rate=15:duration=2", "-f", "lavfi", "-i",
            "sine=frequency=440:duration=2", "-c:v", "mpeg4", "-c:a", "aac", str(first),
        ], check=True, timeout=10)
        selected = season / "第 02 集 + % # ?.mp4"
        selected.hardlink_to(first)
        for number in range(3, episode_count + 1):
            (season / f"第 {number:02} 集.mp4").hardlink_to(first)
        (season / "第 02 集说明.txt").touch()
        path = quote(selected.relative_to(mount).as_posix(), safe="/")
        url = f"http://localhost:9/d/{path}?sign=test"
        check_player(config, root, f"mpv://{quote(url, safe='')}", selected, episode_count)
        check_player(config, root, f"mpv://{url}", selected, episode_count)
        check_player(config, root, selected.as_uri(), selected, episode_count)
        check_library(config, root, selected, episode_count)
        source = make_media_fixture(root)
        check_media_tools(config, root, source)
    print("OK: OpenList, dynamic menus, quality, audio, bookmarks, playlists, chapters and subtitle exports")


if __name__ == "__main__":
    main()
