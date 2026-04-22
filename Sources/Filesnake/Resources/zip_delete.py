#!/usr/bin/env python3
"""Delete entries from a ZIP archive in-place using Python's zipfile module.
Handles Zip64 natively. Copies only untouched entries (raw, no recompression)
so it's efficient even for large archives.

Usage: zip_delete.py <archive.zip> <path1> [path2] ...

Exit codes:
  0  — success
  1  — error (message on stderr)
"""
import sys
import os
import zipfile
import shutil
import tempfile

def main():
    if len(sys.argv) < 3:
        print("Usage: zip_delete.py <archive> <path> [path...]", file=sys.stderr)
        sys.exit(1)

    archive_path = sys.argv[1]
    to_delete = set(sys.argv[2:])

    if not os.path.isfile(archive_path):
        print(f"File not found: {archive_path}", file=sys.stderr)
        sys.exit(1)

    # Create temp file in the same directory to avoid cross-device moves
    dir_name = os.path.dirname(os.path.abspath(archive_path))
    fd, tmp_path = tempfile.mkstemp(suffix='.zip', dir=dir_name)
    os.close(fd)

    try:
        with zipfile.ZipFile(archive_path, 'r') as src:
            with zipfile.ZipFile(tmp_path, 'w', allowZip64=True) as dst:
                for item in src.infolist():
                    if item.filename in to_delete:
                        continue
                    # Copy raw bytes — no decompression/recompression
                    data = src.read(item.filename)
                    dst.writestr(item, data)

        # Atomically replace original
        os.replace(tmp_path, archive_path)
    except Exception as e:
        # Clean up temp file on error
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
