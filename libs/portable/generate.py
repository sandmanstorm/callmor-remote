#!/usr/bin/env python3

import os
import optparse
from hashlib import md5
import brotli
import datetime

# 4GB maximum
length_count = 4
# encoding
encoding = 'utf-8'

# output: {path: (compressed_data, file_md5)}


def _read_ferrydesk_variant() -> str:
    """Resolve the FerryDesk variant from env var or .ferrydesk-variant
    file at repo root. Searches up to 5 parent dirs from cwd because
    generate.py runs from libs/portable/ during CI but might be invoked
    from other locations during local builds."""
    env = os.environ.get('FERRYDESK_VARIANT', '').strip()
    if env:
        return env
    cur = os.path.abspath(os.curdir)
    for _ in range(5):
        candidate = os.path.join(cur, '.ferrydesk-variant')
        if os.path.isfile(candidate):
            try:
                with open(candidate, 'r', encoding='utf-8') as f:
                    return f.read().strip()
            except Exception:
                pass
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return ''


def _should_exclude_for_free_standalone(rel_path: str) -> bool:
    """Files bundled by default for paid variants but unwanted in the
    free-standalone build:
      - WindowInjection.dll: DLL injection helper for clipboard / file
        copy-paste features. Frequently flagged by Windows Defender /
        EDR on locked-down machines, causing the wrapper to silently
        exit on launch (observed in rc2/rc3/rc4 test runs).
      - printer_driver_adapter.dll + drivers/RustDeskPrinterDriver/...:
        printer redirection feature. Unsigned driver fails signature
        check on hardened Windows; not needed for the free variant.
      - usbmmidd_v2/: virtual display driver. Same signing issue;
        not needed for free.
    The v1.5.8 binary that ships and runs cleanly on the test machine
    didn't include any of these — confirmed via strings diff. Stripping
    them brings the free-standalone bundle to v1.5.8-equivalent content.
    Paid variants keep them (operators paying for the product expect
    printer + virtual-display features)."""
    norm = rel_path.replace('\\', '/').lstrip('./')
    if norm in ('WindowInjection.dll', 'printer_driver_adapter.dll'):
        return True
    if norm.startswith('drivers/') or norm.startswith('usbmmidd_v2/'):
        return True
    return False


def generate_md5_table(folder: str, level) -> dict:
    res: dict = dict()
    curdir = os.curdir
    os.chdir(folder)
    variant = _read_ferrydesk_variant()
    if variant == 'free-standalone':
        print(
            "[generate.py] FERRYDESK_VARIANT=free-standalone — "
            "filtering printer driver / virtual display / WindowInjection "
            "DLLs out of the bundle."
        )
    for root, _, files in os.walk('.'):
        # remove ./
        for f in files:
            md5_generator = md5()
            full_path = os.path.join(root, f)
            if variant == 'free-standalone' and _should_exclude_for_free_standalone(full_path):
                print(f"  SKIP (free-standalone): {full_path}")
                continue
            print(f"Processing {full_path}...")
            f = open(full_path, "rb")
            content = f.read()
            content_compressed = brotli.compress(
                content, quality=level)
            md5_generator.update(content)
            md5_code = md5_generator.hexdigest().encode(encoding=encoding)
            res[full_path] = (content_compressed, md5_code)
    os.chdir(curdir)
    return res


def write_package_metadata(md5_table: dict, output_folder: str, exe: str):
    output_path = os.path.join(output_folder, "data.bin")
    with open(output_path, "wb") as f:
        f.write("rustdesk".encode(encoding=encoding))
        for path in md5_table.keys():
            (compressed_data, md5_code) = md5_table[path]
            data_length = len(compressed_data)
            path = path.encode(encoding=encoding)
            # path length & path
            f.write((len(path)).to_bytes(length=length_count, byteorder='big'))
            f.write(path)
            # data length & compressed data
            f.write(data_length.to_bytes(
                length=length_count, byteorder='big'))
            f.write(compressed_data)
            # md5 code
            f.write(md5_code)
        # end
        f.write("rustdesk".encode(encoding=encoding))
        # executable
        f.write(exe.encode(encoding='utf-8'))
    print(f"Metadata has been written to {output_path}")

def write_app_metadata(output_folder: str):
    output_path = os.path.join(output_folder, "app_metadata.toml")
    with open(output_path, "w") as f:
        f.write(f"timestamp = {int(datetime.datetime.now().timestamp() * 1000)}\n")
    print(f"App metadata has been written to {output_path}")

def build_portable(output_folder: str, target: str):
    os.chdir(output_folder)
    if target:
        os.system("cargo build --release --target " + target)
    else:
        os.system("cargo build --release")

# Linux: python3 generate.py -f ../rustdesk-portable-packer/test -o . -e ./test/main.py
# Windows: python3 .\generate.py -f ..\rustdesk\flutter\build\windows\runner\Debug\ -o . -e ..\rustdesk\flutter\build\windows\runner\Debug\rustdesk.exe


if __name__ == '__main__':
    parser = optparse.OptionParser()
    parser.add_option("-f", "--folder", dest="folder",
                      help="folder to compress")
    parser.add_option("-o", "--output", dest="output_folder",
                      help="the root of portable packer project, default is './'")
    parser.add_option("-e", "--executable", dest="executable",
                      help="specify startup file in --folder, default is rustdesk.exe")
    parser.add_option("-t", "--target", dest="target",
                      help="the target used by cargo")
    parser.add_option("-l", "--level", dest="level", type="int",
                      help="compression level, default is 11, highest", default=11)
    (options, args) = parser.parse_args()
    folder = options.folder or './rustdesk'
    output_folder = os.path.abspath(options.output_folder or './')

    if not options.executable:
        options.executable = 'rustdesk.exe'
    if not options.executable.startswith(folder):
        options.executable = folder + '/' + options.executable
    exe: str = os.path.abspath(options.executable)
    if not exe.startswith(os.path.abspath(folder)):
        print("The executable must locate in source folder")
        exit(-1)
    exe = '.' + exe[len(os.path.abspath(folder)):]
    print("Executable path: " + exe)
    print("Compression level: " + str(options.level))
    md5_table = generate_md5_table(folder, options.level)
    write_package_metadata(md5_table, output_folder, exe)
    write_app_metadata(output_folder)
    build_portable(output_folder, options.target)
