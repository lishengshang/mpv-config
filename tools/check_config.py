"""Read-only project configuration checks. Python stdlib only.

Literal references are scanned conservatively; this is not an mpv grammar parser.
Private local.conf and runtime/cache outputs are never inspected.
"""
import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

CONFIG = Path(__file__).resolve().parents[1]
ASSET = re.compile(r'~~/[^\s;"\x27`\\]+\.(?:vpy|glsl|hook|icc)\b')
PROFILE_COMMAND = re.compile(r'(?:^|[;"\x27`])\s*(?:no-osd\s+)?apply-profile\s+([^\s;"\x27`]+)')


@dataclass
class Finding:
    severity: str
    rule: str
    file: str
    line: int
    message: str


def uncomment(text):
    """Strip # outside quotes; preserve literal quotes, escapes and values."""
    quote = None
    escaped = False
    for index, char in enumerate(text):
        if escaped:
            escaped = False
            continue
        if char == '\\':
            escaped = True
        elif quote:
            if char == quote:
                quote = None
        elif char in ('"', "'", '`'):
            quote = char
        elif char == '#':
            return text[:index].strip()
    return text.strip()


def unquote(text):
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ('"', "'", '`'):
        return text[1:-1]
    return text


class Checker:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.findings = []
        self.sources = {}
        self.profiles = {'default'}
        self.references = []

    def add(self, severity, rule, file, line, message):
        self.findings.append(Finding(severity, rule, str(file), line, message))

    def read(self, path):
        path = Path(path)
        if path in self.sources:
            return self.sources[path]
        label = path.relative_to(self.root).as_posix()
        try:
            lines = path.read_text(encoding='utf-8').splitlines()
        except (OSError, UnicodeError):
            self.add('error', 'source-read', label, 1, 'Cannot read UTF-8 configuration file')
            lines = []
        self.sources[path] = lines
        return lines

    def local_path(self, value, file, line):
        value = unquote(value)
        if any(marker in value for marker in ('${', '://', '*', '?')):
            self.add('warning', 'dynamic-path', file, line, 'Dynamic reference needs runtime verification')
            return None
        if value.startswith('~~/'):
            path = self.root / value[3:]
        elif re.match(r'^[A-Za-z]:[\\/]', value) or value.startswith(('~', '/', '\\')):
            self.add('warning', 'external-path', file, line, 'Machine/external reference is outside project verification')
            return None
        else:
            path = self.root / value
        path = path.resolve()
        if not path.is_relative_to(self.root):
            self.add('warning', 'external-path', file, line, 'Reference leaves project directory')
            return None
        return path

    def config(self, path, stack=()):
        path = Path(path).resolve()
        label = path.relative_to(self.root).as_posix()
        if path in stack:
            self.add('error', 'include-cycle', label, 1, 'Recursive include chain')
            return
        if path in self.sources:
            return
        for number, raw in enumerate(self.read(path), 1):
            text = uncomment(raw)
            if not text:
                continue
            if text.startswith('[') and text.endswith(']'):
                self.profiles.add(text[1:-1])
                continue
            match = re.match(r'^([\w-]+)\s*=\s*(.*)$', text)
            if not match:
                continue
            key, value = match.groups()
            if key == 'include':
                include = self.local_path(value, label, number)
                if include == self.root / 'local.conf':
                    # Optional/private: never read even when it exists.
                    continue
                if include:
                    if not include.is_file():
                        self.add('error', 'missing-include', label, number, 'Included project file is missing')
                    else:
                        self.config(include, stack + (path,))
            if key in ('profile', 'profile-append'):
                for name in unquote(value).split(','):
                    self.references.append((label, number, name.strip()))
            for asset in ASSET.findall(text):
                self.asset(asset, label, number)

    def asset(self, value, file, line):
        path = self.local_path(value, file, line)
        if path and not path.is_file():
            self.add('error', 'missing-asset', file, line, 'Referenced asset missing: ' + value)

    def inputs(self, path):
        label = path.relative_to(self.root).as_posix()
        for number, raw in enumerate(self.read(path), 1):
            text = uncomment(raw)
            if not text:
                continue
            for asset in ASSET.findall(text):
                self.asset(asset, label, number)
            for name in PROFILE_COMMAND.findall(text):
                self.references.append((label, number, name))

    def run(self):
        for name in ('mpv.conf', 'profiles.conf'):
            path = self.root / name
            if path.is_file():
                self.config(path)
            else:
                self.add('error', 'missing-config', name, 1, 'Required project configuration missing')
        for name in ('input.conf', 'inputevent_key.conf'):
            path = self.root / name
            if path.is_file():
                self.inputs(path)
            elif name == 'input.conf':
                self.add('error', 'missing-config', name, 1, 'Required project configuration missing')
        for file, line, name in self.references:
            if '${' in name:
                self.add('warning', 'dynamic-profile', file, line, 'Dynamic profile needs runtime verification')
            elif name and name not in self.profiles:
                self.add('error', 'missing-profile', file, line, 'Profile not defined in project: ' + name)
        return self.findings


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config-root', type=Path, default=CONFIG)
    parser.add_argument('--json', action='store_true', help='JSON on stdout; no report files written')
    options = parser.parse_args()
    checker = Checker(options.config_root)
    findings = checker.run()
    if options.json:
        print(json.dumps({'findings': [asdict(f) for f in findings],
                          'checked_files': len(checker.sources)}, ensure_ascii=False, indent=2))
    else:
        for finding in findings:
            print(f'{finding.file}:{finding.line}: {finding.severity.upper()} [{finding.rule}] {finding.message}')
        print(f'Checked {len(checker.sources)} files: '
              f'{sum(f.severity == "error" for f in findings)} errors, '
              f'{sum(f.severity == "warning" for f in findings)} warnings')
        print('Literal references only; input parser, script wiring and GPU execution not checked.')
    return 1 if any(f.severity == 'error' for f in findings) else 0


if __name__ == '__main__':
    sys.exit(main())
