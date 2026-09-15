#!/usr/bin/env python3
"""Reject legacy exercise dataset resources in source or an archived .app."""
import argparse
from pathlib import Path


def verify(root: Path):
    if not root.is_dir():
        raise ValueError(f'Missing directory: {root}')
    forbidden = []
    for path in root.rglob('*'):
        if (path.name.lower() in {'exercisemedia', 'exercisecatalog.json'}
                or path.suffix.lower() == '.gif'):
            forbidden.append(str(path.relative_to(root)))
    if forbidden:
        raise ValueError('Legacy exercise resources / unreviewed GIFs found: ' + ', '.join(forbidden))
    print(f'No legacy exercise dataset resources: {root}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    try:
        verify(args.directory)
    except ValueError as error:
        parser.exit(1, f'{error}\n')
