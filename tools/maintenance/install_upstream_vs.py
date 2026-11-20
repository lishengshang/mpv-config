"""Install VapourSynth from the hash-verified upstream extraction."""
import argparse
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import component_store as store
from components import runtime_files


def install(root, source, package_hash):
    cache = store.inside(root, 'portable_config/cache/first-setup')
    if not source.is_relative_to(cache) or source == cache:
        raise ValueError('Extract the verified VS package inside the first-run staging directory')
    if not (root / 'mpv.exe').is_file() or not (source / 'portable.vs').is_file():
        raise ValueError('Player or upstream portable VS runtime is incomplete')

    with store.install_lock(root):
        store.component_launcher(root)
        files = []
        for name, path in runtime_files(source):
            digest = store.digest(path)
            if name == 'libffi-8.dll':
                candidate = store.inside(root, name)
                if candidate.is_file() and store.digest(candidate) != digest:
                    # Keep the reviewed shared dependency from the candidate.
                    # Both isolated and final VS probes must still pass.
                    shutil.copyfile(candidate, path)
                    digest = store.digest(path)
            files.append(dict(path=name, bytes=path.stat().st_size, sha256=digest))
        item = dict(id='vs', version='mpv-playkit-20260510', sha256=package_hash)
        receipt = store.install_payload(root, item, {'files': files}, source)
        store.configure(root, [receipt])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('player', type=Path)
    parser.add_argument('source', type=Path)
    parser.add_argument('package_hash')
    args = parser.parse_args()
    install(args.player.resolve(), args.source.resolve(), args.package_hash)


if __name__ == '__main__':
    main()
