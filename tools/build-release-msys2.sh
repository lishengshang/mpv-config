#!/usr/bin/env bash
# Run only inside the CI UCRT64 environment; no system setup on the owner's PC.
set -euo pipefail
plan=$(cygpath -u "$1")
work=$(cygpath -u "$2")
mkdir -p "$work"
work=$(cd "$work" && pwd)
test "$MSYSTEM" = UCRT64
python - "$plan" <<'PY'
import sys
sys.path.insert(0, 'tools')
from release import load_plan
load_plan(sys.argv[1])
PY

read_field() { python -c 'import json,sys; x=json.load(open(sys.argv[1])); print(x[sys.argv[2]])' "$plan" "$1"; }
read_build_field() { python -c 'import json,sys; x=json.load(open(sys.argv[1])); print(x["build"][sys.argv[2]])' "$plan" "$1"; }
checkout_source() {
    local repository=$1 commit=$2 directory=$3
    [[ $commit =~ ^[0-9a-f]{40}$ ]]
    test ! -e "$directory"
    git init "$directory"
    git -C "$directory" remote add origin "https://github.com/$repository.git"
    git -C "$directory" fetch --depth=1 origin "$commit"
    git -C "$directory" checkout --detach FETCH_HEAD
    test "$(git -C "$directory" rev-parse HEAD)" = "$commit"
}
checkout_source mpv-player/mpv "$(read_field mpv_commit)" "$work/mpv-source"
checkout_source vapoursynth/vapoursynth "$(read_build_field vapoursynth_headers_commit)" "$work/vs-headers"
checkout_source lunarmodules/luasocket "$(read_build_field luasocket_commit)" "$work/luasocket"

# Stable 0.41 links VSScript directly. Backport the pinned upstream dynamic-loader
# fixes only to the explicitly listed release; newer tags use their own source.
while IFS= read -r backport; do
    [[ $backport =~ ^[0-9a-f]{40}$ ]]
    git -C "$work/mpv-source" fetch --depth=2 origin "$backport"
    git -C "$work/mpv-source" diff "$backport^" "$backport" > "$work/$backport.patch"
    git -C "$work/mpv-source" apply --check "$work/$backport.patch"
    git -C "$work/mpv-source" apply "$work/$backport.patch"
done < <(python - "$plan" <<'PY'
import sys
sys.path.insert(0, 'tools')
from release import load_plan, selected_backports
sys.stdout.write(''.join(commit + '\n' for commit in selected_backports(load_plan(sys.argv[1]))))
PY
)

# The patched Windows interface loads VSScript.dll only when the filter starts.
mkdir -p "$work/pkgconfig"
headers_include=$(cygpath -m "$work/vs-headers/include")
for module in vapoursynth vapoursynth-script; do
    cat > "$work/pkgconfig/$module.pc" <<EOF
Name: $module
Description: VapourSynth headers for mpv's dynamic Windows loader
Version: 72
Cflags: -I$headers_include
EOF
done
export PKG_CONFIG_PATH="$work/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
meson setup "$work/mpv-build" "$work/mpv-source" --buildtype=release \
    -Dlua=enabled -Djavascript=enabled -Dvapoursynth=enabled -Dd3d11=enabled \
    -Dlibarchive=enabled -Dlibbluray=enabled -Ddvdnav=enabled \
    -Dlcms2=enabled -Drubberband=enabled -Duchardet=enabled \
    -Dshaderc=enabled -Dspirv-cross=enabled -Dvulkan=enabled \
    -Dlibmpv=false -Dpdf-build=disabled -Dmanpage-build=disabled
meson compile -C "$work/mpv-build"
meson test -C "$work/mpv-build" --print-errorlogs

mkdir -p "$work/runtime/lua/socket" "$work/runtime/socket" "$work/runtime/mime" "$work/runtime/licenses"
cp "$work/mpv-build/mpv.exe" "$work/mpv-build/mpv.com" "$work/runtime/"
cp "$work/mpv-source/etc/mpv-register.bat" "$work/mpv-source/etc/mpv-unregister.bat" "$work/runtime/"
cp "$MINGW_PREFIX/bin/ffmpeg.exe" "$MINGW_PREFIX/bin/ffprobe.exe" "$work/runtime/"
make -C "$work/luasocket/src" mingw LUAV=5.1 \
    LUAINC_mingw="$MINGW_PREFIX/include/lua5.1" LUALIB_mingw="$MINGW_PREFIX/bin/lua51.dll"
cp "$work/luasocket/src/socket-3.0.0.dll" "$work/runtime/socket/core.dll"
cp "$work/luasocket/src/mime-1.0.3.dll" "$work/runtime/mime/core.dll"
cp "$work/luasocket/src/"{ltn12,mime,socket}.lua "$work/runtime/lua/"
for module in http url tp ftp headers smtp; do
    cp "$work/luasocket/src/$module.lua" "$work/runtime/lua/socket/"
done
cp "$work/luasocket/LICENSE" "$work/runtime/licenses/LuaSocket-LICENSE"
cp "$work/mpv-source/LICENSE.GPL" "$work/mpv-source/LICENSE.LGPL" "$work/runtime/licenses/"
git -C "$work/mpv-source" diff --binary > "$work/runtime/mpv-source.patch"
cp -r "$MINGW_PREFIX/share/licenses" "$work/runtime/licenses/msys2"
pacman -Q > "$work/runtime/msys2-packages.txt"

# Copy the recursive PE import closure, including LuaSocket and FFmpeg. Reject
# unresolved non-system imports instead of relying on the runner's global PATH.
python - "$work/runtime" "$MINGW_PREFIX/bin" "$plan" <<'PY'
import json, os, pathlib, re, shutil, subprocess, sys
runtime, prefix, plan_path = map(pathlib.Path, sys.argv[1:])
plan = json.loads(plan_path.read_text())
system = pathlib.Path(os.environ['SystemRoot']) / 'System32'
available = {p.name.lower(): p for p in prefix.glob('*.dll')}
queue = list(runtime.rglob('*.dll')) + list(runtime.glob('*.exe')) + list(runtime.glob('*.com'))
# Vulkan is loaded dynamically and may not appear in the PE import table.
shutil.copy2(prefix / 'vulkan-1.dll', runtime / 'vulkan-1.dll')
queue.append(runtime / 'vulkan-1.dll')
seen = set()
while queue:
    binary = queue.pop()
    if binary in seen:
        continue
    seen.add(binary)
    imports = subprocess.check_output(['objdump', '-p', str(binary)], text=True, errors='replace')
    for name in re.findall(r'DLL Name:\s*(\S+)', imports):
        # Windows API sets are supplied by the OS, not redistributable DLLs.
        if name.lower().startswith(('api-ms-', 'ext-ms-')) or (system / name).is_file():
            continue
        target = runtime / name
        if target.is_file():
            continue
        source = available.get(name.lower())
        if source is None:
            raise SystemExit('Unresolved runtime import: ' + name)
        shutil.copy2(source, target)
        queue.append(target)
info = {key: plan[key] for key in ('mpv_tag', 'mpv_commit', 'config_commit')}
info['dependencies'] = plan['build']
info['dependency_policy'] = 'MSYS2 packages resolved at build time; exact versions in msys2-packages.txt'
(runtime / 'build-info.json').write_text(json.dumps(info, indent=2) + '\n', encoding='utf-8')
PY
