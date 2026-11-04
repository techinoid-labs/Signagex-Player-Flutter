#!/usr/bin/env python3
"""Remove CEF debugging data from a staged bundle; preserve all loaded sections."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


def loaded_sections(path):
    with path.open('rb') as stream:
        header = stream.read(64)
        if header[:6] != b'\x7fELF\x02\x01':
            raise ValueError(f'{path}: expected little-endian ELF64')
        fields = struct.unpack('<16sHHIQQQIHHHHHH', header)
        offset, entry_size, count, names_index = fields[6], fields[11], fields[12], fields[13]
        if not count or entry_size != 64 or names_index >= count:
            raise ValueError('Unsupported ELF section table')
        stream.seek(offset)
        sections = [struct.unpack('<IIQQQQIIQQ', stream.read(64)) for _ in range(count)]
        names_section = sections[names_index]
        stream.seek(names_section[4])
        names = stream.read(names_section[5])
        result = {}
        debug_bytes = 0
        for section in sections:
            name = names[section[0]:].split(b'\0', 1)[0].decode()
            if name.startswith(('.debug_', '.zdebug_')):
                debug_bytes += section[5]
            if not section[2] & 2:  # SHF_ALLOC: required in the loaded image
                continue
            digest = hashlib.sha256()
            if section[1] != 8:  # SHT_NOBITS (.bss) has no bytes on disk
                stream.seek(section[4])
                remaining = section[5]
                while remaining:
                    block = stream.read(min(remaining, 1024 * 1024))
                    if not block:
                        raise ValueError('Truncated ELF section')
                    digest.update(block)
                    remaining -= len(block)
            result[name] = (section[1], section[2], section[3], section[5], digest.hexdigest())
        return result, debug_bytes


def trim(path, strip_tool):
    before, debug_bytes = loaded_sections(path)
    if not debug_bytes:
        print(f'{path.name}: no debug sections; unchanged')
        return
    original_size = path.stat().st_size
    fd, name = tempfile.mkstemp(prefix='.cef-trim-', dir=path.parent)
    os.close(fd)
    candidate = Path(name)
    try:
        subprocess.run([strip_tool, '--strip-debug', '-o', str(candidate), str(path)], check=True)
        after, remaining_debug = loaded_sections(candidate)
        if before != after or remaining_debug:
            raise ValueError('CEF trim failed: runtime sections changed or debug sections remain')
        if candidate.stat().st_size >= original_size:
            raise ValueError('CEF trim did not reduce size')
        shutil.copystat(path, candidate)
        os.replace(candidate, path)
        print(f'{path.name}: {original_size:,} -> {path.stat().st_size:,} bytes; loaded sections identical')
    finally:
        candidate.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--strip-tool', default=os.environ.get('STRIP', 'strip'))
    args = parser.parse_args()
    library = args.bundle / 'lib' / 'libcef.so'
    if not library.is_file():
        parser.error(f'Missing browser library: {library}')
    trim(library, args.strip_tool)
