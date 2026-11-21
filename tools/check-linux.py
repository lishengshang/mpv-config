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
            "color=blue:size=80x46:rate=15:duration=2", "-c:v", "mpeg4", str(first),
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
    print("OK: OpenList URLs, WebDAV path, 33 items, F5 selection and current-directory browser")


if __name__ == "__main__":
    main()
