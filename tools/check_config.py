"""Read-only project configuration checks. Python stdlib only.

Literal references are scanned conservatively; this is not an mpv grammar parser.
Private local.conf and runtime/cache outputs are never inspected.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
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


@dataclass
class Binding:
    file: str
    line: int
    key: str
    command: str
    section: str = 'default'
    event: str = ''
    condition: str = ''


def split_comment(text):
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
            return text[:index].strip(), text[index + 1:]
    return text.strip(), ''


def uncomment(text):
    return split_comment(text)[0]


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
        self.bindings = []
        self.native_version = None

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
            match = re.match(r'^(\S+)\s+(?:\{([^}]+)\}\s*)?(.*)$', text)
            if not match:
                self.add('error', 'input-line', label, number, 'Expected key and command')
                continue
            key, section, command = match.groups()
            event, condition = '', ''
            if path.name == 'inputevent_key.conf':
                tag = re.search(r'(?:^|#)\s*event\s*:\s*([^#]+)', split_comment(raw)[1])
                if not tag:
                    self.add('warning', 'inputevent-tag', label, number, 'No #event annotation; InputEvent ignores this line')
                    continue
                parts = tag[1].strip().split('|', 1)
                event = parts[0].strip()
                condition = parts[1].strip() if len(parts) > 1 else ''
                if event not in ('click', 'double_click', 'triple_click', 'quatra_click', 'penta_click', 'press', 'release'):
                    self.add('error', 'inputevent-event', label, number, 'Unsupported InputEvent action')
            self.bindings.append(Binding(label, number, key, command, section or 'default', event, condition))

    def native(self, mpv):
        """Use unique inert sections so aliases/duplicates survive mpv parsing.

        Only our dump script runs. User commands are parsed but never triggered.
        """
        with tempfile.TemporaryDirectory(prefix='mpv-input-check-') as temp:
            folder = Path(temp)
            config = folder / 'bindings.conf'
            output = folder / 'bindings.json'
            log_path = folder / 'mpv.log'
            probe = folder / 'probe.lua'
            config.write_text('\n'.join(f'{b.key} {{__config_check_{i}}} {b.command}'
                                        for i, b in enumerate(self.bindings)) + '\n', encoding='utf-8')
            target = json.dumps(output.as_posix(), ensure_ascii=False)
            probe.write_text('local u = require("mp.utils")\nmp.add_timeout(0.05, function()\n'
                             ' local r = {bindings = mp.get_property_native("input-bindings"), '
                             'profiles = mp.get_property_native("profile-list"), '
                             'version = mp.get_property("mpv-version")}\n'
                             f' local f = assert(io.open({target}, "w")); f:write(u.format_json(r)); f:close()\n'
                             ' mp.commandv("quit", "0")\nend)\n', encoding='utf-8')
            args = [str(mpv), '--no-config', '--load-scripts=no', '--osc=no', '--ytdl=no',
                    '--input-terminal=no', '--input-default-bindings=no', '--idle=yes',
                    '--vo=null', '--ao=null', '--msg-level=all=v', '--input-conf=' + str(config),
                    '--script=' + str(probe), '--log-file=' + str(log_path)]
            try:
                process = subprocess.Popen(args, cwd=folder, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    code = process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    if os.name == 'nt':
                        subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                    else:
                        process.kill()
                    process.wait(timeout=10)
                    raise RuntimeError('Input parser probe timed out')
                if code != 0 or not output.is_file():
                    raise RuntimeError('Input parser probe did not produce a successful result')
                data = json.loads(output.read_text(encoding='utf-8'))
                if not isinstance(data.get('bindings'), list):
                    raise RuntimeError('mpv input-bindings property unavailable')
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                self.add('error', 'native-probe', 'input.conf', 1, str(error))
                return
            self.native_version = data.get('version')
            self.profiles.update(p['name'] for p in data.get('profiles', []) if 'name' in p)
            errors = set()
            pending_error = False
            log = log_path.read_text(encoding='utf-8', errors='replace') if log_path.exists() else ''
            for line in log.splitlines():
                if re.search(r'\[(?:e|f)\]\[input\]', line):
                    pending_error = True
                    location = re.search(r'bindings\.conf:(\d+)', line)
                    if location:
                        index = int(location[1]) - 1
                        if 0 <= index < len(self.bindings):
                            b = self.bindings[index]
                            self.add('error', 'input-syntax', b.file, b.line,
                                     'mpv rejected key/command syntax; review this source line')
                            errors.add(index)
                        pending_error = False
            if pending_error:
                self.add('error', 'input-syntax', 'input.conf', 1, 'mpv reported an unlocated input syntax error')
            normalized = {}
            for binding in data['bindings']:
                match = re.fullmatch(r'__config_check_(\d+)', binding.get('section', ''))
                if match:
                    normalized[int(match[1])] = binding['key']
            groups = {}
            regular_keys = set()
            event_keys = {}
            for index, binding in enumerate(self.bindings):
                key = normalized.get(index)
                if key is None:
                    if index not in errors:
                        self.add('error', 'input-key', binding.file, binding.line, 'mpv did not accept this key')
                    continue
                group = (binding.file, binding.section, key, binding.event, binding.condition)
                previous = groups.get(group)
                if previous:
                    self.add('error', 'duplicate-key', binding.file, binding.line,
                             f'Equivalent binding {key}; first defined at {previous.file}:{previous.line}')
                else:
                    groups[group] = binding
                if binding.event:
                    event_keys.setdefault(key, binding)
                else:
                    regular_keys.add(key)
            for key in sorted(regular_keys & event_keys.keys()):
                binding = event_keys[key]
                self.add('info', 'inputevent-override', binding.file, binding.line,
                         f'{key} also has a regular binding; InputEvent actions may override it')

    def run(self, mpv=None):
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
        if mpv:
            self.native(mpv)
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
    parser.add_argument('--mpv', action='store_true', help='Also normalize keys and parse commands using mpv')
    parser.add_argument('--mpv-root', type=Path, default=CONFIG.parent)
    options = parser.parse_args()
    checker = Checker(options.config_root)
    mpv = None
    if options.mpv:
        mpv = next((options.mpv_root / name for name in ('mpv.com', 'mpv.exe', 'mpv')
                    if (options.mpv_root / name).is_file()), None)
        if mpv is None:
            checker.add('error', 'native-probe', 'input.conf', 1, 'mpv executable missing; use --mpv-root')
    findings = checker.run(mpv)
    if options.json:
        print(json.dumps({'findings': [asdict(f) for f in findings],
                          'checked_files': len(checker.sources), 'native_mpv': checker.native_version},
                         ensure_ascii=False, indent=2))
    else:
        for finding in findings:
            print(f'{finding.file}:{finding.line}: {finding.severity.upper()} [{finding.rule}] {finding.message}')
        print(f'Checked {len(checker.sources)} files: '
              f'{sum(f.severity == "error" for f in findings)} errors, '
              f'{sum(f.severity == "warning" for f in findings)} warnings')
        print('Native parser: ' + (checker.native_version or 'not run (use --mpv)'))
        print('Script wiring, runtime forced bindings and GPU execution not checked.')
    return 1 if any(f.severity == 'error' for f in findings) else 0


if __name__ == '__main__':
    sys.exit(main())
