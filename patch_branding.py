#!/usr/bin/env python3
"""
patch_branding.py - Helper script to customize MikroTik RouterOS CLI Logo & WebFig About Menu.
Can patch an already-patched NPK or create/update option.npk without needing loader.7z.
"""

import os
import sys
import gzip
import shutil
import struct
import tempfile
import argparse
import subprocess
import hashlib
from datetime import datetime

from npk import NovaPackage, NpkPartID, NpkFileContainer

def get_env_keys():
    """Load cryptographic keys from environment or .env file."""
    if not os.environ.get('CUSTOM_LICENSE_PRIVATE_KEY'):
        env_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env')
        if os.path.exists(env_file):
            with open(env_file, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#') and '=' in line:
                        k, v = line.split('=', 1)
                        os.environ[k.strip()] = v.strip()

    try:
        kcdsa_priv = bytes.fromhex(os.environ['CUSTOM_LICENSE_PRIVATE_KEY'])
        eddsa_priv = bytes.fromhex(os.environ['CUSTOM_NPK_SIGN_PRIVATE_KEY'])
    except KeyError as e:
        print(f"[!] Error: Environment variable {e} tidak ditemukan.")
        print("    Jalankan 'python3 gen_keys.py' terlebih dahulu untuk membuat file .env.")
        sys.exit(1)

    return kcdsa_priv, eddsa_priv

def extract_logo(npk_file, output_txt):
    """Extract nova/lib/console/logo.txt from an NPK file."""
    npk = NovaPackage.load(npk_file)
    packages = npk._packages if len(npk._packages) > 0 else [npk]

    found = False
    for package in packages:
        if package[NpkPartID.NAME_INFO].data.name == 'system':
            with tempfile.TemporaryDirectory() as tmp_dir:
                squashfs_file = os.path.join(tmp_dir, 'squashfs-root.sfs')
                extract_dir = os.path.join(tmp_dir, 'squashfs-root')
                with open(squashfs_file, 'wb') as f:
                    f.write(package[NpkPartID.SQUASHFS].data)

                res = subprocess.run(['unsquashfs', '-d', extract_dir, squashfs_file],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if res.returncode != 0:
                    print(f"[!] Gagal unsquashfs: {res.stderr.decode()}")
                    return False

                logo_path = os.path.join(extract_dir, "nova/lib/console/logo.txt")
                if os.path.exists(logo_path):
                    with open(logo_path, 'rb') as f_in, open(output_txt, 'wb') as f_out:
                        f_out.write(f_in.read())
                    print(f"[✓] logo.txt berhasil diekstrak ke: {output_txt}")
                    found = True
                    break
    if not found:
        print("[!] File nova/lib/console/logo.txt tidak ditemukan di dalam paket 'system'.")
    return found

def update_logo(input_npk, output_npk, logo_txt_file):
    """Replace nova/lib/console/logo.txt inside NPK's system squashfs."""
    kcdsa_priv, eddsa_priv = get_env_keys()

    if not os.path.exists(logo_txt_file):
        print(f"[!] File logo {logo_txt_file} tidak ditemukan!")
        return False

    with open(logo_txt_file, 'rb') as f:
        new_logo_data = f.read()

    npk = NovaPackage.load(input_npk)
    packages = npk._packages if len(npk._packages) > 0 else [npk]

    modified = False
    for package in packages:
        if package[NpkPartID.NAME_INFO].data.name == 'system':
            with tempfile.TemporaryDirectory() as tmp_dir:
                squashfs_file = os.path.join(tmp_dir, 'squashfs-root.sfs')
                extract_dir = os.path.join(tmp_dir, 'squashfs-root')
                with open(squashfs_file, 'wb') as f:
                    f.write(package[NpkPartID.SQUASHFS].data)

                res = subprocess.run(['unsquashfs', '-d', extract_dir, squashfs_file],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if res.returncode != 0:
                    print(f"[!] Gagal unsquashfs: {res.stderr.decode()}")
                    return False

                logo_path = os.path.join(extract_dir, "nova/lib/console/logo.txt")
                os.makedirs(os.path.dirname(logo_path), exist_ok=True)
                with open(logo_path, 'wb') as f:
                    f.write(new_logo_data)

                # Repack SquashFS
                res = subprocess.run([
                    'mksquashfs', extract_dir, squashfs_file,
                    '-no-recovery', '-noappend', '-exit-on-error', '-quiet',
                    '-comp', 'xz', '-no-xattrs', '-b', '256k', '-all-root'
                ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if res.returncode != 0:
                    print(f"[!] Gagal mksquashfs: {res.stderr.decode()}")
                    return False

                with open(squashfs_file, 'rb') as f:
                    package[NpkPartID.SQUASHFS].data = f.read()
                modified = True
                print(f"[✓] logo.txt berhasil diperbarui di SquashFS!")

    if modified:
        print("[*] Menandatangani ulang NPK dengan kunci kustom...")
        npk.sign(kcdsa_priv, eddsa_priv)
        npk.save(output_npk or input_npk)
        print(f"[✓] NPK berhasil disimpan ke: {output_npk or input_npk}")
        return True
    else:
        print("[!] Paket 'system' tidak ditemukan di dalam file NPK.")
        return False

def build_option_squashfs(output_sfs, arch, title, author, website, telegram, note, version):
    """Build option.sfs containing WebFig option.jg menu and busybox/keygen binaries."""
    try:
        import crcmod
    except ImportError:
        print("[!] Modul python crcmod belum terpasang. Jalankan: apt install python3-crcmod")
        sys.exit(1)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    busybox_bin = os.path.join(script_dir, 'busybox', f'busybox_{arch}')
    keygen_bin = os.path.join(script_dir, 'keygen', f'keygen_{arch}')
    busybox_x86 = os.path.join(script_dir, 'busybox', 'busybox_x86')

    with tempfile.TemporaryDirectory() as tmp_dir:
        opt_root = os.path.join(tmp_dir, 'option-root')
        bin_dir = os.path.join(opt_root, 'bin')
        web_dir = os.path.join(opt_root, 'home', 'web', 'webfig')
        os.makedirs(bin_dir, exist_ok=True)
        os.makedirs(web_dir, exist_ok=True)

        # Copy busybox & keygen if available
        if os.path.exists(busybox_bin):
            try:
                shutil.copy2(busybox_bin, os.path.join(bin_dir, 'busybox'))
                os.chmod(os.path.join(bin_dir, 'busybox'), 0o755)
            except Exception as e:
                print(f"[*] Info: Tidak dapat menyalin busybox: {e}")
        if os.path.exists(keygen_bin):
            try:
                shutil.copy2(keygen_bin, os.path.join(bin_dir, 'keygen'))
                os.chmod(os.path.join(bin_dir, 'keygen'), 0o755)
            except Exception as e:
                print(f"[*] Info: Tidak dapat menyalin keygen: {e}")

        commands = []
        if os.path.exists(busybox_x86):
            try:
                os.chmod(busybox_x86, 0o755)
                res = subprocess.run([busybox_x86, '--list'], stdout=subprocess.PIPE, text=True, timeout=5)
                if res.returncode == 0:
                    commands = res.stdout.split()
            except Exception:
                pass

        if not commands:
            commands = [
                "sh", "ash", "bash", "cat", "chmod", "chown", "cp", "date", "dd", "df", "dmesg",
                "echo", "egrep", "env", "fgrep", "grep", "gzip", "gunzip", "head", "hexdump", "id",
                "ip", "kill", "killall", "ln", "ls", "mkdir", "mknod", "mktemp", "mv", "netstat",
                "nslookup", "ping", "ps", "pwd", "rm", "rmdir", "route", "sed", "sleep", "stat",
                "sync", "tail", "tar", "tee", "test", "touch", "tr", "uname", "vi", "watch", "wc", "which"
            ]

        for cmd in commands:
            target_symlink = os.path.join(bin_dir, cmd)
            try:
                if not os.path.exists(target_symlink):
                    os.symlink('/pckg/option/bin/busybox', target_symlink)
            except Exception:
                pass

        # Generate option.jg JSON structure
        option_jg_content = f"""[
    {{
        name:'{title}',
        title:'{title}',
        icon: 30,
        prio: 2000,
        c:[
            {{
                title:'{title}',
                type:'item',
                path:[24, 2],
                autorefresh: 1000, 
                ro: 1,
                c: [
                    {{type:'gridcell'}},
                    {{name:'Info',type:'tab',inline: 1}},
                    {{name:'Author',type:'string',def:'{author}'}},
                    {{name:'Website',type:'string',def:'{website}', url:1}},
                    {{name:'Telegram',type:'string',def:'{telegram}', url:1}},
                    {{name:'Note',type:'string',def:'{note}'}},
                    {{name:'System',type:'tab',inline: 1}},
                    {{name:'Uptime',type:'interval',id:'u1'}},
                    {{name:'Architecture Name',type:'string',id:'s1a'}},
                    {{name:'Board Name',type:'string',id:'s2c'}},
                    {{name:'Version',type:'version',id:'s16'}},
                    {{name:'Build Time',type:'string',id:'s27'}},
                    {{type:'separator'}},
                    {{type:'toolbar',
                        c: [
                            {{name:'License',type:'contextmenu',autostart: 1,group:'System',link: [],open:'License',tab:'License'}},
                            {{name:'Check For Updates',type:'contextmenu',autostart: 1,group:'System',link: [],open:'Packages',tab:'Check For Updates'}}
                        ]
                    }}
                ]
            }}
        ]
    }}
]
"""
        jg_data = option_jg_content.encode('utf-8')
        sha1_prefix = hashlib.sha1(jg_data).hexdigest()[:12]
        crc_func = crcmod.mkCrcFun(0x104C11DB7, initCrc=0xFFFFFFFF, rev=False, xorOut=0xFFFFFFFF)
        crc_val = crc_func(jg_data)

        unique_name = f"option-{sha1_prefix}.jg"
        unique_gz = f"{unique_name}.gz"
        gz_path = os.path.join(web_dir, unique_gz)

        with gzip.open(gz_path, 'wb', compresslevel=0) as f_gz:
            f_gz.write(jg_data)

        gz_size = os.path.getsize(gz_path)
        info_content = f'{{ crc: {crc_val}, size: {gz_size}, name: "option.jg", unique: "{unique_name}",version: "{version}" }},\n'
        with open(os.path.join(web_dir, 'option.info'), 'w', encoding='utf-8') as f_info:
            f_info.write(info_content)

        os.symlink(unique_gz, os.path.join(web_dir, 'option.jg.gz'))

        # Create squashfs
        res = subprocess.run([
            'mksquashfs', opt_root, output_sfs,
            '-no-recovery', '-noappend', '-exit-on-error', '-quiet',
            '-comp', 'xz', '-no-xattrs', '-b', '256k', '-all-root'
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if res.returncode != 0:
            print(f"[!] Gagal mksquashfs option: {res.stderr.decode()}")
            return False

    print(f"[✓] option.sfs berhasil dibuat: {output_sfs}")
    return True

def create_option_npk(base_npk, output_npk, option_sfs, desc="custom about & shell"):
    """Create option.npk from base_npk (e.g. gps.npk, option.npk) and option.sfs."""
    kcdsa_priv, eddsa_priv = get_env_keys()
    pkg = NovaPackage.load(base_npk)
    target = pkg
    if len(pkg._packages) > 0:
        for sub in pkg._packages:
            if sub[NpkPartID.NAME_INFO].data.name != 'system':
                target = sub
                break
        else:
            target = pkg._packages[0]

        standalone = NovaPackage()
        standalone._parts = [p for p in target._parts if p.id != NpkPartID.SIGNATURE]
        target = standalone

    target[NpkPartID.NAME_INFO].data.name = 'option'
    target[NpkPartID.DESCRIPTION].data = desc.encode()
    target[NpkPartID.NULL_BLOCK].data = b''
    with open(option_sfs, 'rb') as f:
        target[NpkPartID.SQUASHFS].data = f.read()

    target.sign(kcdsa_priv, eddsa_priv)
    target.save(output_npk)
    print(f"[✓] option.npk berhasil dibuat: {output_npk}")
    return True

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="MikroTik RouterOS Custom Branding Tool")
    subparsers = parser.add_subparsers(dest="command")

    p_extract = subparsers.add_parser('extract-logo', help="Ekstrak logo.txt dari paket NPK")
    p_extract.add_argument('npk', help="File NPK input")
    p_extract.add_argument('output', help="File tujuan untuk menyimpan logo.txt")

    p_logo = subparsers.add_parser('update-logo', help="Ganti logo.txt di dalam NPK")
    p_logo.add_argument('input_npk', help="File NPK sumber")
    p_logo.add_argument('output_npk', help="File NPK hasil")
    p_logo.add_argument('logo_file', help="File teks berisi logo ASCII")

    p_sfs = subparsers.add_parser('build-option-sfs', help="Bangun option.sfs untuk WebFig About menu")
    p_sfs.add_argument('output_sfs', help="Path file option.sfs output")
    p_sfs.add_argument('--arch', default='x86', help="Arsitektur (x86 atau arm64)")
    p_sfs.add_argument('--title', default='About', help="Judul menu")
    p_sfs.add_argument('--author', default='Custom Build', help="Nama author")
    p_sfs.add_argument('--website', default='https://mikrotik.com', help="URL website")
    p_sfs.add_argument('--telegram', default='', help="Telegram / Kontak")
    p_sfs.add_argument('--note', default='', help="Catatan tambahan")
    p_sfs.add_argument('--version', default='7.18.2', help="Versi RouterOS")

    p_npk = subparsers.add_parser('create-option-npk', help="Buat option.npk dari base NPK dan option.sfs")
    p_npk.add_argument('base_npk', help="File NPK dasar (misal gps-*.npk)")
    p_npk.add_argument('output_npk', help="File option-*.npk tujuan")
    p_npk.add_argument('sfs_file', help="File option.sfs")
    p_npk.add_argument('--desc', default='Option Package', help="Deskripsi paket")

    args = parser.parse_args()

    if args.command == 'extract-logo':
        extract_logo(args.npk, args.output)
    elif args.command == 'update-logo':
        update_logo(args.input_npk, args.output_npk, args.logo_file)
    elif args.command == 'build-option-sfs':
        build_option_squashfs(args.output_sfs, args.arch, args.title, args.author,
                              args.website, args.telegram, args.note, args.version)
    elif args.command == 'create-option-npk':
        create_option_npk(args.base_npk, args.output_npk, args.sfs_file, args.desc)
    else:
        parser.print_help()
