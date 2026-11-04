#!/usr/bin/env python3
"""Export an explicit source allowlist, excluding personal handoffs and local data."""
import argparse
from pathlib import Path
import shutil


def export(destination):
    source = Path(__file__).resolve().parents[1]
    files = [source / name for name in (
        'Package.swift', 'README.md', 'LICENSE', 'SECURITY.md', 'CONTRIBUTING.md',
        'RELEASE_NOTES.md',
        '.gitignore', '.swift-format',
    )]
    for folder, pattern in (
        ('Sources', '*.swift'), ('Tests', '*.swift'), ('scripts', '*.py'),
        ('scripts', '*.swift'), ('scripts', '*.sh'), ('.github/workflows', '*.yml'),
    ):
        files.extend(sorted((source / folder).rglob(pattern)))
    # Refuse to overwrite any existing folder or file.
    destination.mkdir(parents=True, exist_ok=False)
    for file in files:
        target = destination / file.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target)
    print(f'Exported {len(files)} source/documentation files to {destination}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    export(parser.parse_args().destination.resolve())
