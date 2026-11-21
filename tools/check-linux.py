"""Exercise the Linux configuration with temporary media and an OpenList URL."""

import json
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import quote


def wait_for(probe, ready, description):
    deadline = time.monotonic() + 5
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
        command("script-message-to", "uosc", "show-submenu", "音频 > 音量均衡")
        wait_for(menu_open, bool, "Audio normalization menu did not open")
        for key in keys:
            command("keypress", key)
        command("keypress", "ENTER")
        wait_for(menu_open, lambda visible: not visible, "Audio normalization menu did not close")
        filters = read("af")
        if name is None:
            assert filters == existing
        else:
            assert filters[:-1] == existing
            assert filters[-1]["label"] == "audio-normalization"
            assert name in json.dumps(filters[-1])

    command("set_property", "af", original)


def check_player(config, root, opened, selected, episode_count):
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
        f"openlist-mount_path={root / 'mount'}", "--", opened,
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
                            if reply["error"] == "property unavailable":
                                return None
                            if reply["error"] != "success":
                                raise RuntimeError(f"{args}: {reply['error']}")
                            return reply.get("data")
                        if args != ("quit",):
                            raise RuntimeError(f"mpv exited during {args}")

                    def read(name):
                        return command("get_property", name)

                    def menu_open():
                        return any(
                            binding.get("owner") == "uosc" and binding["key"] == "ESC"
                            for binding in read("input-bindings")
                        )

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
                    check_audio_controls(command, read, menu_open)
                    command("keypress", "F5")
                    wait_for(menu_open, bool, "F5 did not open the uosc playlist")
                    command("keypress", "END")
                    command("keypress", "ENTER")
                    last_name = f"第 {episode_count:02} 集.mp4"
                    wait_for(lambda: read("filename"), lambda name: name == last_name,
                             "Selecting the last episode from uosc failed")
                    wait_for(menu_open, lambda visible: not visible, "Playlist menu did not close")
                    command("keypress", "o")
                    wait_for(menu_open, bool, "o did not open the current directory")
                    command("keypress", "HOME")
                    command("keypress", "DOWN")
                    command("keypress", "ENTER")
                    wait_for(lambda: read("filename"), lambda name: name == "第 01 集.mp4",
                             "The uosc file browser did not open the episode directory")
                    command("quit")
            if player.wait(timeout=5) != 0:
                raise RuntimeError("mpv did not exit cleanly")
            for line in log_path.read_text().splitlines():
                if "][e]" in line or "][f]" in line:
                    raise RuntimeError(line)
        finally:
            if player.poll() is None:
                player.kill()


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
    print("OK: OpenList playlist, quality preset restore, and audio normalization")


if __name__ == "__main__":
    main()
