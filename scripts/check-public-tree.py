#!/usr/bin/env python3
"""Small publication hygiene check, not a complete secret/history scanner.

Examines Git-visible working files, including untracked source ready to stage.
Never prints matching content, only paths and rule names.
"""
from pathlib import Path
import hashlib
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
repository = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=root,
                            capture_output=True, text=True)
if repository.returncode or Path(repository.stdout.strip()).resolve() != root:
    raise SystemExit('Run this check in a Git checkout. For a source export, first run git init in its root.')
listed = subprocess.check_output(
    ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root
).decode().split('\0')
private_roots = {'outputs', 'work', 'references', 'v0', 'Debugger', 'Modules', 'V3', '.agents', '.codex', 'Development'}
private_suffixes = {'.pcm', '.wav', '.aiff', '.mp3', '.dmg', '.zip', '.tldraw'}
# Reviewed project artwork and licensed UI cues. Other binary files need review.
public_assets = {
    'docs/images/computah.png': '0ff39bddecaeb1df2fa95a06a6fa7a3456823ce8e58dbfd36bab89d938c391a9',
    'Sources/Computah/Resources/Sounds/sparkle.wav': 'd26b3d5d8eec803d9555f81e396e61575c2d77f51d4088659db02b50923cc731',
    'Sources/Computah/Resources/Sounds/droplet.wav': '8fcee01e0b9de10f77ca08af0ac38c849bba7b5e921d2f0a25ebe9f7094308fc',
}
patterns = {
    'developer home path': re.compile(r'/Users/[A-Za-z0-9._-]+/'),
    'provider secret': re.compile(r'\b(?:sk-|apikey_)[A-Za-z0-9_-]{20,}'),
    'private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
}
failures = []
count = 0
for name in sorted(set(listed)):
    if not name:
        continue
    path = root / name
    if path.is_symlink():
        failures.append((name, 'symlink requires explicit publication review'))
        continue
    if not path.exists():  # Working-tree removals are expected during migration.
        continue
    count += 1
    relative = Path(name)
    if (relative.parts[0] in private_roots or relative.parts[:2] == ('docs', 'local')
            or '.build' in relative.parts or any(p.endswith('.app') for p in relative.parts)):
        failures.append((name, 'private/generated/retired tree'))
        continue
    if relative.name.startswith('.env') and relative.name != '.env.example':
        failures.append((name, 'environment file'))
        continue
    if name in public_assets:
        if hashlib.sha256(path.read_bytes()).hexdigest() != public_assets[name]:
            failures.append((name, 'public asset changed; requires publication review'))
        continue
    if path.suffix.lower() in private_suffixes:
        failures.append((name, 'recording or binary archive'))
        continue
    try:
        text = path.read_text()
    except (UnicodeDecodeError, IsADirectoryError):
        failures.append((name, 'unexpected non-text artifact'))
        continue
    for label, pattern in patterns.items():
        if pattern.search(text):
            failures.append((name, label))
for name, label in failures:
    print(f'{name}: {label}')
if failures:
    sys.exit(1)
print(f'Public working tree: {count} files checked; no configured hygiene violations.')
