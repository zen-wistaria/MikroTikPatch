#!/usr/bin/env bash
# ==============================================================================
# MikroTikPatch - Local Build Script
# 
# Digunakan untuk membangun dan mem-patch image MikroTik RouterOS (v7 & v6)
# secara lokal di lingkungan Linux atau WSL (Windows Subsystem for Linux).
# ==============================================================================

set -euo pipefail

# --- Warna Output Terminal ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- Konfigurasi Default ---
VERSION=""
ARCH="x86"
MAJOR_VERSION=""
TARGET="all" # all, npk, iso, chr, install
KEEP_BUILD=false
ENV_FILE="$SCRIPT_DIR/.env"
BUILD_BASE_DIR="/tmp/mikrotik_build"
PUBLISH_BASE_DIR="$SCRIPT_DIR/publish"
AUTHOR="Unknown - Local Patched Build"

# --- Banner ---
show_banner() {
    cat << "EOF"
  __  __ _ _             _____ _ _    _____atch
 |  \/  (_) |           |_   _(_) |  |  __ \     
 | \  / |_| | ___ __ ___  | |  _| | _| |__) |__ _ 
 | |\/| | | |/ / '__/ _ \ | | | | |/ /  ___/ _` |
 | |  | | |   <| | | (_) || | | |   <| |  | (_| |
 |_|  |_|_|_|\_\_|  \___/ |_| |_|_|\_\_|   \__,_|
                  Local Image Builder
==================================================
EOF
}

# --- Bantuan Penggunaan ---
show_help() {
    show_banner
    cat << EOF
Penggunaan:
  sudo ./build_local.sh [OPSI]

Opsi:
  -v, --version <versi>    Versi RouterOS (contoh: 7.18.2 atau 6.49.13)
                           Default: Otomatis mendeteksi versi stable terbaru
  -a, --arch <arch>        Arsitektur target: 'x86' atau 'arm64' (Default: x86)
  -t, --target <target>    Target yang dibangun: 'all', 'npk', 'iso', 'chr', 'install'
                           Default: 'all'
  -m, --major <v7|v6>      Versi mayor: 'v7' atau 'v6' (Default: otomatis sesuai versi)
  -e, --env <file>         Path file konfigurasi .env (Default: ./.env)
  -o, --output <dir>       Direktori output (Default: ./publish/<version>)
  -b  --by <author name>   Nama author untuk about
  -k, --keep-build         Jangan hapus folder sementara build setelah selesai
  -h, --help               Tampilkan pesan bantuan ini

Contoh:
  sudo ./build_local.sh -v 7.18.2 -a x86 -t all
  sudo ./build_local.sh -v 7.18.2 -t chr
  sudo ./build_local.sh -v 6.49.13 -a x86 -t npk
EOF
    exit 0
}

# --- Parse Argumen CLI ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -a|--arch)
            ARCH="$2"
            shift 2
            ;;
        -t|--target)
            TARGET="$2"
            shift 2
            ;;
        -m|--major)
            MAJOR_VERSION="$2"
            shift 2
            ;;
        -e|--env)
            ENV_FILE="$2"
            shift 2
            ;;
        -o|--output)
            PUBLISH_BASE_DIR="$2"
            shift 2
            ;;
        -b|--by)
            AUTHOR="$2"
            shift 2
            ;;
        -k|--keep-build)
            KEEP_BUILD=true
            shift 1
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo -e "${RED}[!] Parameter tidak dikenal: $1${NC}"
            show_help
            ;;
    esac
done

# --- Validasi Arsitektur ---
if [[ "$ARCH" != "x86" && "$ARCH" != "arm64" ]]; then
    echo -e "${RED}[!] Arsitektur tidak didukung: $ARCH (Gunakan 'x86' atau 'arm64')${NC}"
    exit 1
fi

# --- Logging Helpers ---
log_info() { echo -e "${CYAN}[*] $1${NC}"; }
log_step() { echo -e "\n${BOLD}${BLUE}==> $1${NC}"; }
log_ok()   { echo -e "${GREEN}[✓] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[!] $1${NC}"; }
log_err()  { echo -e "${RED}[✗] $1${NC}" >&2; }

# --- Validasi OS Linux & Root Privileges ---
check_system() {
    log_step "Memeriksa Lingkungan Sistem"
    if [[ "$OSTYPE" != "linux"* ]]; then
        log_err "Script ini membutuhkan Linux / WSL untuk operasi mounting disk, loop device, dan squashfs."
        exit 1
    fi

    if [[ "$EUID" -ne 0 ]]; then
        log_warn "Script tidak dijalankan sebagai root/sudo."
        log_warn "Operasi mount, losetup, qemu-nbd, dan mksquashfs memerlukan hak akses root."
        read -rp "Lanjutkan dengan meminta sudo? (y/n) " yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            exec sudo -E bash "$0" "$@"
        else
            log_err "Akses root diperlukan. Keluar."
            exit 1
        fi
    fi
}

# --- Pemeriksaan Dependensi ---
check_dependencies() {
    log_step "Memeriksa Paket Dependensi"
    local missing_pkgs=()

    # Tools CLI penting
    local required_bins=(python3 zip unzip mksquashfs unsquashfs jq wget curl xorriso qemu-img parted sgdisk sfdisk mkfs.vfat mkfs.ext4 mkfs.ext2 truncate)
    for b in "${required_bins[@]}"; do
        if ! command -v "$b" >/dev/null 2>&1; then
            missing_pkgs+=("$b")
        fi
    done

    # Modul Python penting
    local required_py_modules=(crcmod pefile elftools)
    for mod in "${required_py_modules[@]}"; do
        if ! python3 -c "import $mod" >/dev/null 2>&1; then
            missing_pkgs+=("python3-$mod")
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        log_warn "Terdapat paket dependensi yang belum terpasang: ${missing_pkgs[*]}"
        echo -e "${YELLOW}Untuk Ubuntu/Debian/WSL, pasang dengan perintah:${NC}"
        echo -e "  sudo apt-get update"
        echo -e "  sudo apt-get install -y zip unzip squashfs-tools jq wget curl \\"
        echo -e "    xorriso isolinux syslinux syslinux-common dosfstools parted util-linux \\"
        echo -e "    qemu-utils p7zip-full build-essential python3-crcmod python3-pefile python3-pyelftools"
        echo ""
        read -rp "Apakah Anda ingin script ini mencoba menginstalnya otomatis sekarang? (y/n) " yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            apt-get update
            apt-get install -y zip unzip squashfs-tools jq wget curl \
                xorriso isolinux syslinux syslinux-common dosfstools parted util-linux \
                qemu-utils p7zip-full build-essential python3-crcmod python3-pefile python3-pyelftools
            log_ok "Dependensi berhasil dipasang."
        else
            log_err "Harap pasang dependensi di atas sebelum melanjutkan."
            exit 1
        fi
    else
        log_ok "Semua paket dependensi terpenuhi."
    fi
}

# --- Setup Kunci Kriptografi & Environment ---
setup_environment() {
    log_step "Memeriksa Konfigurasi Kunci & Environment"

    if [ ! -f "$ENV_FILE" ]; then
        log_warn "File $ENV_FILE tidak ditemukan."
        log_info "Membuat pasangan kunci baru otomatis menggunakan gen_keys.py..."
        python3 gen_keys.py "$ENV_FILE"
    fi

    # Muat environment variable dari .env
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a

    # Validasi keberadaan kunci wajib
    local mandatory_keys=(
        "MIKRO_LICENSE_PUBLIC_KEY"
        "MIKRO_NPK_SIGN_PUBLIC_KEY"
        "CUSTOM_LICENSE_PRIVATE_KEY"
        "CUSTOM_LICENSE_PUBLIC_KEY"
        "CUSTOM_NPK_SIGN_PRIVATE_KEY"
        "CUSTOM_NPK_SIGN_PUBLIC_KEY"
    )

    for k in "${mandatory_keys[@]}"; do
        if [ -z "${!k:-}" ]; then
            log_err "Variabel lingkungan $k wajib diisi di $ENV_FILE!"
            exit 1
        fi
        if [ ${#k} -lt 64 ] && [ ${#k} -gt 0 ]; then
            # Hanya cek panjang jika string hex
            if [[ ! "${!k}" =~ ^[0-9a-fA-F]{64}$ ]]; then
                log_warn "Nilai $k (${!k}) mungkin tidak valid (diharapkan 64 hex karakter)."
            fi
        fi
    done

    # Default URLs jika kosong
    export MIKRO_UPGRADE_URL="${MIKRO_UPGRADE_URL:-upgrade.mikrotik.com}"
    export MIKRO_LICENCE_URL="${MIKRO_LICENCE_URL:-licence.mikrotik.com}"
    export MIKRO_RENEW_URL="${MIKRO_RENEW_URL:-renew.mikrotik.com}"
    export MIKRO_CLOUD_URL="${MIKRO_CLOUD_URL:-cloud.mikrotik.com}"
    export MIKRO_CLOUD2_URL="${MIKRO_CLOUD2_URL:-cloud2.mikrotik.com}"

    log_ok "Kunci kriptografi dan environment siap."
}

# --- Deteksi / Validasi Versi RouterOS ---
resolve_version() {
    log_step "Menentukan Versi RouterOS"

    if [ -z "$VERSION" ]; then
        log_info "Mencari versi stable RouterOS terbaru dari MikroTik..."
        OFFICIAL_UPGRADE=$(curl -fsSL https://upgrade.mikrotik.com/routeros/upgrade.json) || {
            log_err "Gagal mengambil data versi dari upgrade.mikrotik.com"
            exit 1
        }
        VERSION=$(echo "$OFFICIAL_UPGRADE" | jq -r '.upgradePaths["NEWESTa7.stable"].version')
        log_ok "Versi stable v7 terbaru terdeteksi: $VERSION"
    else
        log_info "Menggunakan versi yang ditentukan: $VERSION"
    fi

    # Tentukan versi mayor
    if [ -z "$MAJOR_VERSION" ]; then
        if [[ "$VERSION" =~ ^6\. ]]; then
            MAJOR_VERSION="v6"
        elif [[ "$VERSION" =~ ^7\. ]]; then
            MAJOR_VERSION="v7"
        else
            log_err "Tidak dapat mendeteksi versi mayor untuk: $VERSION"
            exit 1
        fi
    fi

    if [[ "$MAJOR_VERSION" == "v6" && "$ARCH" == "arm64" ]]; then
        log_err "RouterOS v6 tidak mendukung arsitektur arm64."
        exit 1
    fi

    log_ok "Target Build: RouterOS $MAJOR_VERSION ($VERSION) - Arsitektur: $ARCH"
}

# --- Setup Direktori Kerja ---
setup_dirs() {
    BUILD_DIR="$BUILD_BASE_DIR/$VERSION-$ARCH"
    PUBLISH_DIR="$PUBLISH_BASE_DIR/$VERSION-$ARCH"

    if [ "$ARCH" == "x86" ]; then
        ARCH_EXT=""
    else
        ARCH_EXT="-$ARCH"
    fi

    export ARCH_EXT
    export BUILD_DIR
    export PUBLISH_DIR
    export ARCH
    export VERSION

    log_info "BUILD_DIR   : $BUILD_DIR"
    log_info "PUBLISH_DIR : $PUBLISH_DIR"

    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    mkdir -p "$PUBLISH_DIR"
}

# --- Trap Pembersihan Mount Point ---
cleanup() {
    local exit_code=$?
    log_info "Membersihkan mount point dan perangkat loop/nbd jika ada..."
    sync || true
    
    # Lepaskan mount build dir
    if [ -n "${BUILD_DIR:-}" ] && [ -d "$BUILD_DIR" ]; then
        grep "$BUILD_DIR" /proc/mounts | awk '{print $2}' | sort -r | while read -r mnt; do
            umount -l "$mnt" 2>/dev/null || true
        done
    fi

    # Putuskan nbd jika aktif
    if command -v qemu-nbd >/dev/null 2>&1; then
        qemu-nbd -d /dev/nbd0 2>/dev/null || true
    fi

    # Hapus folder build jika tidak diminta keep
    if [ "$KEEP_BUILD" = false ] && [ -n "${BUILD_DIR:-}" ]; then
        rm -rf "$BUILD_DIR"
        log_info "Direktori build sementara telah dibersihkan."
    fi

    if [ $exit_code -eq 0 ]; then
        log_ok "Proses selesai dengan sukses!"
    else
        log_err "Proses terhenti atau mengalami error (Exit code: $exit_code)."
    fi
}
trap cleanup EXIT INT TERM

# ==============================================================================
# PIPELINE ROUTEROS V7
# ==============================================================================

build_v7_option() {
    log_step "[V7] 1. Membangun Squashfs Option dan Python"

    # 1. Option Squashfs (Busybox + Keygen + WebFig patch menu)
    log_info "Membuat option.sfs untuk arsitektur: $ARCH"
    mkdir -p "$BUILD_DIR/option-root/bin/"
    install -m 755 "./busybox/busybox_$ARCH" "$BUILD_DIR/option-root/bin/busybox"
    install -m 755 "./keygen/keygen_$ARCH" "$BUILD_DIR/option-root/bin/keygen"
    chmod +x "./busybox/busybox_x86"

    # Symlink busybox applets
    local commands
    commands=$("./busybox/busybox_x86" --list)
    for cmd in $commands; do
        ln -sf /pckg/option/bin/busybox "$BUILD_DIR/option-root/bin/$cmd"
    done

    mkdir -p "$BUILD_DIR/option-root/home/web/webfig/"
    local busybox_ver
    busybox_ver=$("./busybox/busybox_x86" | head -1 | cut -d' ' -f2)

    cat << EOF > "$BUILD_DIR/option.jg"
[
    {
        name:'About',
        title:'About',
        icon: 30,
        prio: 2000,
        c:[
            {
                title:'About',
                type:'item',
                path:[24, 2],
                autorefresh: 1000, 
                ro: 1,
                c: [
                    {type:'gridcell'},
                    {name:'Patch',type:'tab',inline: 1},
                    {name:'Author',type:'string',def:'$AUTHOR'},
                    {name:'Busybox',type:'string',def:'$busybox_ver'},
                    {name:'System',type:'tab',inline: 1},
                    {name:'Uptime',type:'interval',id:'u1'},
                    {name:'Architecture Name',type:'string',id:'s1a'},
                    {name:'Board Name',type:'string',id:'s2c'},
                    {name:'Version',type:'version',id:'s16'},
                    {name:'Build Time',type:'string',id:'s27'},
                    {type:'separator'},
                    {type:'toolbar',
                        c: [
                            {name:'License',type:'contextmenu',autostart: 1,group:'System',link: [],open:'License',tab:'License'},
                            {name:'Check For Updates',type:'contextmenu',autostart: 1,group:'System',link: [],open:'Packages',tab:'Check For Updates'}
                        ]
                    }
                ]
            }
        ]
    }
]
EOF

    # Hitung SHA1 dan CRC menggunakan python crcmod
    local hash_out sha1_prefix crc
    hash_out=$(python3 -E <<EOF
import hashlib, crcmod
with open('$BUILD_DIR/option.jg','rb') as f:
    data = f.read()
    sha1 = hashlib.sha1(data).hexdigest()[:12]
    crc = crcmod.mkCrcFun(0x104C11DB7, initCrc=0xFFFFFFFF, rev=False, xorOut=0xFFFFFFFF)(data)
    print(f"{sha1} {crc}")
EOF
)
    sha1_prefix=$(echo "$hash_out" | awk '{print $1}')
    crc=$(echo "$hash_out" | awk '{print $2}')

    mv "$BUILD_DIR/option.jg" "$BUILD_DIR/option-$sha1_prefix.jg"
    python3 -E << EOF
import gzip
gzip.open('$BUILD_DIR/option-$sha1_prefix.jg.gz', 'wb', compresslevel=0).write(open('$BUILD_DIR/option-$sha1_prefix.jg', 'rb').read())
EOF
    local size
    size=$(stat -c %s "$BUILD_DIR/option-$sha1_prefix.jg.gz")
    mv "$BUILD_DIR/option-$sha1_prefix.jg.gz" "$BUILD_DIR/option-root/home/web/webfig/"
    cat << EOF > "$BUILD_DIR/option-root/home/web/webfig/option.info"
{ crc: $crc, size: $size, name: "option.jg", unique: "option-$sha1_prefix.jg",version: "$VERSION" },
EOF
    ln -sf "option-$sha1_prefix.jg.gz" "$BUILD_DIR/option-root/home/web/webfig/option.jg.gz"

    mksquashfs "$BUILD_DIR/option-root" "$BUILD_DIR/option.sfs" -no-recovery -noappend -exit-on-error -quiet -comp xz -no-xattrs -b 256k -all-root
    rm -rf "$BUILD_DIR/option-root"
    log_ok "Option squashfs dibuat: $BUILD_DIR/option.sfs"

    # 2. Python3 Squashfs (Python Standalone Musl/Glibc)
    log_info "Mengunduh python standalone untuk $ARCH..."
    if [ "$ARCH" == "x86" ]; then
        wget -nv -O "$BUILD_DIR/cpython.tar.gz" https://github.com/astral-sh/python-build-standalone/releases/download/20241206/cpython-3.11.11+20241206-x86_64-unknown-linux-musl-install_only_stripped.tar.gz
    elif [ "$ARCH" == "arm64" ]; then
        wget -nv -O "$BUILD_DIR/cpython.tar.gz" https://github.com/indygreg/python-build-standalone/releases/download/20241206/cpython-3.11.11+20241206-aarch64-unknown-linux-gnu-install_only_stripped.tar.gz
    fi

    tar -xzf "$BUILD_DIR/cpython.tar.gz" -C "$BUILD_DIR"
    rm -f "$BUILD_DIR/cpython.tar.gz"
    rm -rf "$BUILD_DIR/python/include" "$BUILD_DIR/python/share"
    mksquashfs "$BUILD_DIR/python" "$BUILD_DIR/python3.sfs" -no-recovery -noappend -exit-on-error -quiet -comp xz -no-xattrs -b 256k -all-root
    rm -rf "$BUILD_DIR/python"
    log_ok "Python3 squashfs dibuat: $BUILD_DIR/python3.sfs"
}

build_v7_download_and_extract() {
    log_step "[V7] 2. Mengunduh & Mengekstrak Official RouterOS $VERSION"

    local iso_file="$BUILD_DIR/mikrotik-$VERSION$ARCH_EXT.iso"
    if [ ! -f "$iso_file" ]; then
        log_info "Mengunduh ISO resmi dari download.mikrotik.com..."
        wget -nv -O "$iso_file" "https://download.mikrotik.com/routeros/$VERSION/mikrotik-$VERSION$ARCH_EXT.iso"
    fi

    # Ambil packages.csv untuk mendata semua paket
    local packages_csv="$BUILD_DIR/packages.csv"
    wget -nv -O "$packages_csv" "https://${MIKRO_UPGRADE_URL}/routeros/$VERSION/packages.csv" || true

    local pkg_list=""
    if [ -f "$packages_csv" ]; then
        pkg_list=$(grep "^$ARCH," "$packages_csv" | cut -d',' -f2 | tr '\n' ' ' || true)
        rm -f "$packages_csv"
    fi

    mkdir -p "$BUILD_DIR/all_packages" "$BUILD_DIR/iso" "$BUILD_DIR/new_iso"
    mount -o loop,ro "$iso_file" "$BUILD_DIR/iso"
    cp -v "$BUILD_DIR/iso/"*.npk "$BUILD_DIR/all_packages/"
    mv "$BUILD_DIR/all_packages/routeros-$VERSION$ARCH_EXT.npk" "$BUILD_DIR/"
    cp -v "$BUILD_DIR/iso/efiboot.img" "$BUILD_DIR/new_iso/"
    cp -v "$BUILD_DIR/iso/defpacks" "$BUILD_DIR/new_iso/" 2>/dev/null || true
    umount "$BUILD_DIR/iso"
    rm -rf "$BUILD_DIR/iso"

    # Unduh paket yang belum ada di dalam ISO
    if [ -n "$pkg_list" ]; then
        for pkg in $pkg_list; do
            local pkg_file="${pkg}-$VERSION$ARCH_EXT.npk"
            local pkg_path="$BUILD_DIR/all_packages/$pkg_file"
            if [ ! -f "$pkg_path" ]; then
                log_info "Mengunduh paket tambahan: $pkg_file"
                wget -nv -O "$pkg_path" "https://download.mikrotik.com/routeros/$VERSION/$pkg_file" || true
            fi
        done
    fi
    log_ok "Ekstraksi paket selesai."
}

build_v7_patch_npk() {
    log_step "[V7] 3. Melakukan Patching & Signing Paket NPK"

    # Loader optional check (jika user memiliki loader patch sendiri)
    if [ -n "${LOADER_7Z_PASSWORD:-}" ] && [ -n "${CUSTOM_UPGRADE_URL:-}" ]; then
        log_info "Mencoba mengunduh file loader.7z..."
        if wget -nv -O "$BUILD_DIR/loader.7z" "https://${CUSTOM_UPGRADE_URL}/routeros/loader.7z"; then
            7z x -p"${LOADER_7Z_PASSWORD}" "$BUILD_DIR/loader.7z" -o"$SCRIPT_DIR" -y >/dev/null 2>&1 || true
            rm -f "$BUILD_DIR/loader.7z"
        fi
    fi

    chmod +w "$BUILD_DIR/all_packages/"*.npk 2>/dev/null || true
    local npk_files
    npk_files=$(find "$BUILD_DIR/all_packages" -name "*.npk")
    for file in $npk_files; do
        python3 npk.py sign "$file" "$file"
    done

    # Buat option.npk dan python3.npk
    python3 npk.py create "$BUILD_DIR/all_packages/gps-$VERSION$ARCH_EXT.npk" "$BUILD_DIR/all_packages/option-$VERSION$ARCH_EXT.npk" option "$BUILD_DIR/option.sfs" -desc="busybox"
    rm -f "$BUILD_DIR/option.sfs"

    python3 npk.py create "$BUILD_DIR/all_packages/gps-$VERSION$ARCH_EXT.npk" "$BUILD_DIR/all_packages/python3-$VERSION$ARCH_EXT.npk" python3 "$BUILD_DIR/python3.sfs" -desc="python 3.11.13"
    rm -f "$BUILD_DIR/python3.sfs"

    # Zip all_packages
    (cd "$BUILD_DIR/all_packages" && zip -r "$PUBLISH_DIR/all_packages-$ARCH-$VERSION.zip" .)
    mv "$BUILD_DIR/all_packages/"*.npk "$PUBLISH_DIR/"
    rm -rf "$BUILD_DIR/all_packages"

    # Patch paket utama routeros.npk
    log_info "Mem-patch paket utama routeros-$VERSION$ARCH_EXT.npk..."
    python3 patch.py npk "$BUILD_DIR/routeros-$VERSION$ARCH_EXT.npk" -O "$PUBLISH_DIR/routeros-$VERSION$ARCH_EXT.npk"
    log_ok "Paket utama berhasil di-patch: $PUBLISH_DIR/routeros-$VERSION$ARCH_EXT.npk"
}

build_v7_iso_and_install() {
    log_step "[V7] 4. Membangun File ISO & USB Install Image"

    cp -v "$PUBLISH_DIR/routeros-$VERSION$ARCH_EXT.npk" "$BUILD_DIR/new_iso/"
    unzip -q "$PUBLISH_DIR/all_packages-$ARCH-$VERSION.zip" -d "$BUILD_DIR/new_iso/"
    mkdir -p "$BUILD_DIR/efiboot"

    if [ "$ARCH" == "x86" ]; then
        log_info "Menyusun CD-ROM ISO x86..."
        mkdir -p "$BUILD_DIR/new_iso/isolinux"
        cp -vf /usr/lib/ISOLINUX/isolinux.bin "$BUILD_DIR/new_iso/isolinux/" 2>/dev/null || cp -vf /usr/lib/syslinux/isolinux.bin "$BUILD_DIR/new_iso/isolinux/"
        cp -vf /usr/lib/syslinux/modules/bios/ldlinux.c32 "$BUILD_DIR/new_iso/isolinux/" 2>/dev/null || true
        cp -vf /usr/lib/syslinux/modules/bios/libutil.c32 "$BUILD_DIR/new_iso/isolinux/" 2>/dev/null || true
        cp -vf /usr/lib/syslinux/modules/bios/menu.c32 "$BUILD_DIR/new_iso/isolinux/" 2>/dev/null || true

        cat << 'EOF' > "$BUILD_DIR/new_iso/isolinux/isolinux.cfg"
UI menu.c32
MENU TITLE MikroTik RouterOS Install CDROM
MENU CLEAR
DEFAULT system
TIMEOUT 0
LABEL system
    MENU LABEL Install RouterOS
    KERNEL linux
    APPEND load_ramdisk=1 root=/dev/ram0 -install -cdrom
EOF

        # Ekstrak kernel dari efiboot bawaan dan patch
        mount -o loop "$BUILD_DIR/new_iso/efiboot.img" "$BUILD_DIR/efiboot"
        python3 patch.py kernel "$BUILD_DIR/efiboot/linux.x86_64" -O "$BUILD_DIR/new_iso/isolinux/linux"
        umount "$BUILD_DIR/efiboot"

        # Rekonstruksi efiboot.img dengan rEFInd
        log_info "Mengunduh rEFInd bootloader..."
        local refind_zip="$BUILD_DIR/refind-bin-0.14.2.zip"
        if [ ! -f "$refind_zip" ]; then
            wget -nv -O "$refind_zip" https://downloads.sourceforge.net/project/refind/0.14.2/refind-bin-0.14.2.zip
        fi

        rm -f "$BUILD_DIR/new_iso/efiboot.img"
        truncate --size 64M "$BUILD_DIR/new_iso/efiboot.img"
        mkfs.vfat -n "Boot" "$BUILD_DIR/new_iso/efiboot.img"
        mount -o loop "$BUILD_DIR/new_iso/efiboot.img" "$BUILD_DIR/efiboot"
        mkdir -p "$BUILD_DIR/efiboot/EFI/BOOT"
        unzip -j -q "$refind_zip" "refind-bin-0.14.2/refind/refind_x64.efi" -d "$BUILD_DIR/efiboot/EFI/BOOT/"
        mv "$BUILD_DIR/efiboot/EFI/BOOT/refind_x64.efi" "$BUILD_DIR/efiboot/EFI/BOOT/BOOTX64.EFI"

        cat << 'EOF' > "$BUILD_DIR/efiboot/EFI/BOOT/refind.conf"
timeout 0
textonly
textmode 0
showtools shutdown, reboot, exit
menuentry "Install RouterOS" {
    loader /linux.x86_64
    options "load_ramdisk=1 root=/dev/ram0 -install -cdrom debug"
}
default_selection /EFI/BOOT/BOOTX64.EFI
EOF
        cp -vf "$BUILD_DIR/new_iso/isolinux/linux" "$BUILD_DIR/efiboot/linux.x86_64"
        sync
        umount "$BUILD_DIR/efiboot"

        # Buat ISO akhir x86
        xorriso -as mkisofs -o "$PUBLISH_DIR/mikrotik-$VERSION$ARCH_EXT.iso" \
            -V 'MikroTik' -publisher "WWW.MIKROTIK.COM" -preparer "MIKROTIK" -A "MIKROTIK_ROUTER" \
            -sysid "" -b 'isolinux/isolinux.bin' -c 'isolinux/boot.cat' \
            -no-emul-boot -boot-load-size 4 -eltorito-alt-boot \
            -e efiboot.img -no-emul-boot -boot-load-size 2048 \
            -R -J -input-charset utf-8 -iso-level 3 \
            "$BUILD_DIR/new_iso"
        log_ok "ISO x86 berhasil dibuat: $PUBLISH_DIR/mikrotik-$VERSION$ARCH_EXT.iso"

        # Buat USB Install Image
        log_info "Membuat image installer USB (install-image-$VERSION.img)..."
        local install_img="$BUILD_DIR/install-image-$VERSION.img"
        truncate --size 128M "$install_img"
        mkfs.vfat -I -F 32 -n "Install" "$install_img"
        local loop_dev
        loop_dev=$(losetup -f --show "$install_img")
        syslinux --install "$loop_dev"
        mkdir -p "$BUILD_DIR/install"
        mount -o loop "$loop_dev" "$BUILD_DIR/install"
        cp -vf "$BUILD_DIR/new_iso/isolinux/linux" "$BUILD_DIR/install/"
        cp -vf /usr/lib/syslinux/modules/bios/ldlinux.c32 "$BUILD_DIR/install/" 2>/dev/null || true
        mkdir -p "$BUILD_DIR/install/EFI/BOOT"
        unzip -j -q "$refind_zip" "refind-bin-0.14.2/refind/refind_x64.efi" -d "$BUILD_DIR/install/EFI/BOOT"
        mv "$BUILD_DIR/install/EFI/BOOT/refind_x64.efi" "$BUILD_DIR/install/EFI/BOOT/BOOTX64.EFI"

        cat << 'EOF' > "$BUILD_DIR/install/EFI/BOOT/refind.conf"
timeout 0
textonly
textmode 0
showtools shutdown, reboot, exit
menuentry "Install RouterOS" {
	loader /linux
	options "load_ramdisk=1 root=/dev/ram0 -install -hdd"
}
default_selection /EFI/BOOT/BOOTX64.EFI
EOF
        cat << 'EOF' > "$BUILD_DIR/install/syslinux.cfg"
default system
label system
	kernel linux
	append load_ramdisk=1 -install -hdd
EOF
        # Copy npk files as 1.npk, 2.npk, etc.
        local idx=1
        for npk in "$BUILD_DIR/new_iso/"*.npk; do
            cp "$npk" "$BUILD_DIR/install/$idx.npk"
            ((idx++))
        done
        touch "$BUILD_DIR/install/CHOOSE"
        touch "$BUILD_DIR/install/autorun.scr"
        sync
        umount "$BUILD_DIR/install"
        losetup -d "$loop_dev"
        rm -rf "$BUILD_DIR/install"
        (cd "$BUILD_DIR" && zip "$PUBLISH_DIR/install-image-$VERSION.zip" "install-image-$VERSION.img")
        rm -f "$install_img"
        log_ok "USB install image berhasil dibuat: $PUBLISH_DIR/install-image-$VERSION.zip"

    elif [ "$ARCH" == "arm64" ]; then
        log_info "Menyusun CD-ROM ISO arm64..."
        mount -o loop "$BUILD_DIR/new_iso/efiboot.img" "$BUILD_DIR/efiboot"
        python3 patch.py kernel "$BUILD_DIR/efiboot/EFI/BOOT/BOOTAA64.EFI" -O "$BUILD_DIR/BOOTAA64.EFI"
        umount "$BUILD_DIR/efiboot"

        rm -f "$BUILD_DIR/new_iso/efiboot.img"
        truncate --size 16M "$BUILD_DIR/new_iso/efiboot.img"
        mkfs.vfat -n "Boot" "$BUILD_DIR/new_iso/efiboot.img"
        mount -o loop "$BUILD_DIR/new_iso/efiboot.img" "$BUILD_DIR/efiboot"
        mkdir -p "$BUILD_DIR/efiboot/EFI/BOOT"
        mv "$BUILD_DIR/BOOTAA64.EFI" "$BUILD_DIR/efiboot/EFI/BOOT/BOOTAA64.EFI"
        sync
        umount "$BUILD_DIR/efiboot"

        xorriso -as mkisofs -o "$PUBLISH_DIR/mikrotik-$VERSION$ARCH_EXT.iso" \
            -V 'MikroTik' -publisher "WWW.MIKROTIK.COM" -preparer "MIKROTIK" -A "MIKROTIK_ROUTER" \
            -sysid "" -e '/efiboot.img' -no-emul-boot -boot-load-size 2048 \
            -R -J -input-charset utf-8 -iso-level 3 \
            "$BUILD_DIR/new_iso"
        log_ok "ISO arm64 berhasil dibuat: $PUBLISH_DIR/mikrotik-$VERSION$ARCH_EXT.iso"
    fi

    rm -rf "$BUILD_DIR/new_iso" "$BUILD_DIR/efiboot"
}

build_v7_chr() {
    log_step "[V7] 5. Membangun Image CHR Virtual Appliance"
    modprobe nbd 2>/dev/null || true

    mkdir -p "$BUILD_DIR/chr/"{boot,routeros}

    local ovf_template='<?xml version="1.0" encoding="UTF-8"?>
<Envelope vmw:buildId="build-18663434" xmlns="http://schemas.dmtf.org/ovf/envelope/1" xmlns:cim="http://schemas.dmtf.org/wbem/wscim/1/common" xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1" xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData" xmlns:vmw="http://www.vmware.com/schema/ovf" xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <References>
    <File ovf:href="{VMDK_FILE}" ovf:id="file1" ovf:size="{FILE_SIZE}"/>
  </References>
  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:capacity="128" ovf:capacityAllocationUnits="byte * 2^20" ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
  </DiskSection>
  <NetworkSection>
    <Info>The list of logical networks</Info>
    <Network ovf:name="VM Network"><Description>The VM Network network</Description></Network>
  </NetworkSection>
  <VirtualSystem ovf:id="vm">
    <Info>A virtual machine</Info>
    <Name>MikroTik_RouterOS_CHR</Name>
    <OperatingSystemSection ovf:id="100" vmw:osType="other3xLinux64Guest"><Info>Guest OS</Info></OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System><vssd:ElementName>Virtual Hardware Family</vssd:ElementName><vssd:InstanceID>0</vssd:InstanceID><vssd:VirtualSystemIdentifier>MikroTik_RouterOS_CHR</vssd:VirtualSystemIdentifier><vssd:VirtualSystemType>vmx-10</vssd:VirtualSystemType></System>
      <Item><rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits><rasd:Description>Number of CPUs</rasd:Description><rasd:ElementName>1 vCPU</rasd:ElementName><rasd:InstanceID>1</rasd:InstanceID><rasd:ResourceType>3</rasd:ResourceType><rasd:VirtualQuantity>1</rasd:VirtualQuantity></Item>
      <Item><rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits><rasd:Description>Memory Size</rasd:Description><rasd:ElementName>1024MB RAM</rasd:ElementName><rasd:InstanceID>2</rasd:InstanceID><rasd:ResourceType>4</rasd:ResourceType><rasd:VirtualQuantity>1024</rasd:VirtualQuantity></Item>
      <Item><rasd:Address>0</rasd:Address><rasd:Description>IDE Controller</rasd:Description><rasd:ElementName>ideController0</rasd:ElementName><rasd:InstanceID>3</rasd:InstanceID><rasd:ResourceType>5</rasd:ResourceType></Item>
      <Item><rasd:AddressOnParent>0</rasd:AddressOnParent><rasd:ElementName>disk0</rasd:ElementName><rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource><rasd:InstanceID>4</rasd:InstanceID><rasd:Parent>3</rasd:Parent><rasd:ResourceType>17</rasd:ResourceType></Item>
      <Item><rasd:AddressOnParent>1</rasd:AddressOnParent><rasd:AutomaticAllocation>true</rasd:AutomaticAllocation><rasd:Connection>VM Network</rasd:Connection><rasd:ElementName>ethernet0</rasd:ElementName><rasd:InstanceID>5</rasd:InstanceID><rasd:ResourceSubType>VmxNet3</rasd:ResourceSubType><rasd:ResourceType>10</rasd:ResourceType></Item>
      <vmw:Config ovf:required="false" vmw:key="firmware" vmw:value="{FIRMWARE_TYPE}"/>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>'

    prepare_chr_image() {
        local image="$1"
        local boot_mode="$2"

        truncate --size 128M "$image"
        local end=$(( ($(stat -c '%s' "$image") / 512 - 4096) / 8 * 8 - 1 ))
        sgdisk --set-alignment=1 \
            --new=1:34:65535 --typecode=1:EF00 --change-name=1:"RouterOS Boot" \
            --new=2:65536:$end --typecode=2:8300 --change-name=2:"RouterOS" \
            --hybrid=1:2:EE \
            "$image"

        # Active CHR mode marker
        printf '\x01' | dd of="$image" bs=1 seek=336 conv=notrunc status=none
        # Active boot partition
        printf '\x80' | dd of="$image" bs=1 seek=446 conv=notrunc status=none
        # Partition type 0x83
        printf '\x83' | dd of="$image" bs=1 seek=450 conv=notrunc status=none

        if [[ "$boot_mode" == "bios" ]]; then
            echo "FA31C08ED0BC007C89E65007501FFBFCBF0006B90001F2A5EA1D060000BEBE07B304803C807423803C00750983C610FECB75EFCD18BE9B06AC3C00740B56BB0700B40ECD105EEBF0EBFE8B148B4C0289F5BF0500BB007CB8010257CD135F730C31C0CD134F75EDBE7C06EBCCBFFE7D813D55AA75C289EEEA007C00004572726F72206C6F6164696E67206F7065726174696E672073797374656D004D697373696E67206F7065726174696E672073797374656D0000000000" |
                xxd -r -p 2>/dev/null || true | dd of="$image" bs=1 conv=notrunc status=none
        fi
    }

    build_chr_disk() {
        local image="$1"
        local boot_mode="$2"

        prepare_chr_image "$image" "$boot_mode"

        qemu-nbd -d /dev/nbd0 2>/dev/null || true
        qemu-nbd -c /dev/nbd0 -f raw "$image"
        partprobe /dev/nbd0 || sleep 1

        # Partisi Boot
        if [[ "$boot_mode" == "bios" ]]; then
            mkfs.ext2 -F -m 0 -L "RouterOS Boot" /dev/nbd0p1
        else
            mkfs.vfat -F 16 -n "BOOT" /dev/nbd0p1
        fi

        mount /dev/nbd0p1 "$BUILD_DIR/chr/boot"
        mkdir -p "$BUILD_DIR/chr/boot/EFI/BOOT"
        if [ "$ARCH" == "x86" ]; then
            cp -vf "$BUILD_DIR/chr/BOOTX64.EFI" "$BUILD_DIR/chr/boot/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || true
        elif [ "$ARCH" == "arm64" ]; then
            cp -vf "$BUILD_DIR/chr/BOOTAA64.EFI" "$BUILD_DIR/chr/boot/EFI/BOOT/BOOTAA64.EFI"
        fi

        if [[ "$boot_mode" == "bios" && -f "$BUILD_DIR/chr/milo" ]]; then
            "$BUILD_DIR/chr/milo" "$BUILD_DIR/chr/boot"
        fi
        umount "$BUILD_DIR/chr/boot"

        # Partisi RouterOS
        mkfs.ext4 -F -m 0 -L "RouterOS" /dev/nbd0p2
        mount /dev/nbd0p2 "$BUILD_DIR/chr/routeros"
        mkdir -p "$BUILD_DIR/chr/routeros/"{var/pdb/{system,option},boot,bin,rw/disk}
        if [ -f "$BUILD_DIR/chr/milo" ]; then
            install -m 0755 "$BUILD_DIR/chr/milo" "$BUILD_DIR/chr/routeros/bin/milo"
        fi
        if [ -f "$BUILD_DIR/chr/bash" ]; then
            install -m 0755 "$BUILD_DIR/chr/bash" "$BUILD_DIR/chr/routeros/bin/bash"
        fi

        cp -v "$PUBLISH_DIR/option-$VERSION$ARCH_EXT.npk" "$BUILD_DIR/chr/routeros/var/pdb/option/image"
        cp -v "$PUBLISH_DIR/routeros-$VERSION$ARCH_EXT.npk" "$BUILD_DIR/chr/routeros/var/pdb/system/image"
        cat << 'EOF' > "$BUILD_DIR/chr/routeros/rw/disk/rc.local"
#!/bin/sh
# This script will be executed *before* RouterOS *loader* start.
# Put custom initialization commands here.
EOF
        chmod +x "$BUILD_DIR/chr/routeros/rw/disk/rc.local"
        sync
        umount "$BUILD_DIR/chr/routeros"
        qemu-nbd -d /dev/nbd0

        # Konversi disk image ke berbagai format VM
        local prefix="${image%.img}"
        local name="${prefix##*/}"

        log_info "Mengonversi format image virtual untuk $name..."
        qemu-img convert -f raw -O qcow2 "$image" "$prefix.qcow2"
        qemu-img convert -f raw -O vmdk  "$image" "$prefix.vmdk"
        qemu-img convert -f raw -O vpc   "$image" "$prefix.vhd"
        qemu-img convert -f raw -O vhdx  "$image" "$prefix.vhdx"
        qemu-img convert -f raw -O vdi   "$image" "$prefix.vdi"

        # Buat OVA
        local vmdk_stream="$name-disk1.vmdk"
        local ovf_file="$name.ovf"
        local ova_file="$name.ova"

        qemu-img convert -f raw -O vmdk -o subformat=streamOptimized "$image" "$BUILD_DIR/$vmdk_stream"
        local fsize
        fsize=$(stat -c %s "$BUILD_DIR/$vmdk_stream")
        echo "$ovf_template" | sed -e "s|{VMDK_FILE}|$vmdk_stream|g" -e "s|{FILE_SIZE}|$fsize|g" -e "s|{FIRMWARE_TYPE}|$boot_mode|g" > "$BUILD_DIR/$ovf_file"
        (cd "$BUILD_DIR" && tar -cf "$ova_file" "$ovf_file" "$vmdk_stream")
        rm -f "$BUILD_DIR/$vmdk_stream" "$BUILD_DIR/$ovf_file"

        # Kompresi hasil ke direktori publish
        (cd "$BUILD_DIR" && \
            zip -q "$PUBLISH_DIR/$name.ova.zip" "$name.ova" && \
            zip -q "$PUBLISH_DIR/$name.qcow2.zip" "$name.qcow2" && \
            zip -q "$PUBLISH_DIR/$name.vmdk.zip" "$name.vmdk" && \
            zip -q "$PUBLISH_DIR/$name.vhd.zip" "$name.vhd" && \
            zip -q "$PUBLISH_DIR/$name.vhdx.zip" "$name.vhdx" && \
            zip -q "$PUBLISH_DIR/$name.vdi.zip" "$name.vdi" && \
            zip -q "$PUBLISH_DIR/$name.img.zip" "$name.img" )
        rm -f "$prefix".*
        log_ok "Image CHR $name berhasil dibuat."
    }

    if [ "$ARCH" == "x86" ]; then
        log_info "Mengekstrak file bootloader dari routeros NPK..."
        python3 npk.py extract "$PUBLISH_DIR/routeros-$VERSION$ARCH_EXT.npk" boot/EFI/BOOT/BOOTX64.EFI "$BUILD_DIR/chr/BOOTX64.EFI" || true
        python3 npk.py extract "$PUBLISH_DIR/routeros-$VERSION$ARCH_EXT.npk" bin/milo "$BUILD_DIR/chr/milo" || true
        python3 npk.py extract "$PUBLISH_DIR/routeros-$VERSION$ARCH_EXT.npk" bin/bash "$BUILD_DIR/chr/bash" || true
        chmod +x "$BUILD_DIR/chr/milo" 2>/dev/null || true

        log_info "Membangun CHR x86 UEFI image..."
        build_chr_disk "$BUILD_DIR/chr-$VERSION$ARCH_EXT.img" efi

        log_info "Membangun CHR x86 Legacy BIOS image..."
        build_chr_disk "$BUILD_DIR/chr-$VERSION$ARCH_EXT-legacy-bios.img" bios

    elif [ "$ARCH" == "arm64" ]; then
        log_info "Mengekstrak kernel arm64 dari routeros NPK..."
        python3 npk.py extract "$PUBLISH_DIR/routeros-$VERSION$ARCH_EXT.npk" boot/kernel "$BUILD_DIR/chr/kernel"
        python3 patch.py buildefi "$BUILD_DIR/chr/kernel" "$BUILD_DIR/chr/BOOTAA64.EFI"
        rm -f "$BUILD_DIR/chr/kernel"

        log_info "Membangun CHR arm64 UEFI image..."
        build_chr_disk "$BUILD_DIR/chr-$VERSION$ARCH_EXT.img" efi
    fi

    rm -rf "$BUILD_DIR/chr"
}

# ==============================================================================
# PIPELINE ROUTEROS V6
# ==============================================================================

build_v6_option() {
    log_step "[V6] 1. Membangun Option Squashfs"
    mkdir -p "$BUILD_DIR/option-root/bin/"
    cp "./busybox/busybox_$ARCH" "$BUILD_DIR/option-root/bin/busybox"
    chmod +x "$BUILD_DIR/option-root/bin/busybox"
    cp "./keygen/keygen_$ARCH" "$BUILD_DIR/option-root/bin/keygen"
    chmod +x "$BUILD_DIR/option-root/bin/keygen"
    chmod +x "./busybox/busybox_x86"

    local commands
    commands=$("./busybox/busybox_x86" --list)
    for cmd in $commands; do
        ln -sf /pckg/option/bin/busybox "$BUILD_DIR/option-root/bin/$cmd"
    done

    mkdir -p "$BUILD_DIR/option-root/home/web/webfig/"
    local busybox_ver
    busybox_ver=$("./busybox/busybox_x86" | head -1 | cut -d' ' -f2)

    cat << EOF > "$BUILD_DIR/option.jg"
[
    {
        name:'About',
        title:'About',
        icon: 30,
        prio: 2000,
        c:[
            {
                title:'About',
                type:'item',
                path:[24, 2],
                autorefresh: 1000, 
                ro: 1,
                c: [
                    {type:'gridcell'},
                    {name:'Patch',type:'tab',inline: 1},
                    {name:'Author',type:'string',def:'$AUTHOR'},
                    {name:'Busybox',type:'string',def:'$busybox_ver'},
                    {name:'System',type:'tab',inline: 1},
                    {name:'Uptime',type:'interval',id:'u1'},
                    {name:'Architecture Name',type:'string',id:'s1a'},
                    {name:'Board Name',type:'string',id:'s2c'},
                    {name:'Version',type:'version',id:'s16'},
                    {name:'Build Time',type:'string',id:'s27'},
                    {type:'separator'},
                    {type:'toolbar',
                        c: [
                            {name:'License',type:'contextmenu',autostart: 1,group:'System',link: [],open:'License',tab:'License'},
                            {name:'Check For Updates',type:'contextmenu',autostart: 1,group:'System',link: [],open:'Packages',tab:'Check For Updates'}
                        ]
                    }
                ]
            }
        ]
    }
]
EOF

    local hash_out sha1_prefix crc
    hash_out=$(python3 -E <<EOF
import hashlib, crcmod
with open('$BUILD_DIR/option.jg','rb') as f:
    data = f.read()
    sha1 = hashlib.sha1(data).hexdigest()[:12]
    crc = crcmod.mkCrcFun(0x104C11DB7, initCrc=0xFFFFFFFF, rev=False, xorOut=0xFFFFFFFF)(data)
    print(f"{sha1} {crc}")
EOF
)
    sha1_prefix=$(echo "$hash_out" | awk '{print $1}')
    crc=$(echo "$hash_out" | awk '{print $2}')
    mv "$BUILD_DIR/option.jg" "$BUILD_DIR/option-$sha1_prefix.jg"
    python3 -E << EOF
import gzip
gzip.open('$BUILD_DIR/option-$sha1_prefix.jg.gz', 'wb', compresslevel=0).write(open('$BUILD_DIR/option-$sha1_prefix.jg', 'rb').read())
EOF
    local size
    size=$(stat -c %s "$BUILD_DIR/option-$sha1_prefix.jg.gz")
    mv "$BUILD_DIR/option-$sha1_prefix.jg.gz" "$BUILD_DIR/option-root/home/web/webfig/"
    cat << EOF > "$BUILD_DIR/option-root/home/web/webfig/option.info"
{ crc: $crc, size: $size, name: "option.jg", unique: "option-$sha1_prefix.jg",version: "$VERSION" },
EOF
    ln -sf "option-$sha1_prefix.jg.gz" "$BUILD_DIR/option-root/home/web/webfig/option.jg.gz"
    mksquashfs "$BUILD_DIR/option-root" "$BUILD_DIR/option.sfs" -no-recovery -noappend -exit-on-error -quiet -comp xz -no-xattrs -b 256k -all-root
    rm -rf "$BUILD_DIR/option-root"
    log_ok "Option squashfs dibuat: $BUILD_DIR/option.sfs"
}

build_v6_download_and_extract() {
    log_step "[V6] 2. Mengunduh & Mengekstrak Official RouterOS v6 ($VERSION)"
    local iso_file="$BUILD_DIR/mikrotik-$VERSION.iso"
    wget -nv -O "$iso_file" "https://download.mikrotik.com/routeros/$VERSION/mikrotik-$VERSION.iso"
    local ros_npk="$BUILD_DIR/routeros-$ARCH-$VERSION.npk"
    wget -nv -O "$ros_npk" "https://download.mikrotik.com/routeros/$VERSION/routeros-$ARCH-$VERSION.npk"

    mkdir -p "$BUILD_DIR/all_packages" "$BUILD_DIR/iso" "$BUILD_DIR/new_iso"
    mount -o loop,ro "$iso_file" "$BUILD_DIR/iso"
    cp -r "$BUILD_DIR/iso/"* "$BUILD_DIR/new_iso/"
    chmod -R +w "$BUILD_DIR/new_iso/"
    mv "$BUILD_DIR/new_iso/"*.npk "$BUILD_DIR/all_packages/"
    mv "$BUILD_DIR/all_packages/system-$VERSION.npk" "$BUILD_DIR/"
    umount "$BUILD_DIR/iso"
    rm -rf "$BUILD_DIR/iso"
    log_ok "Ekstraksi paket v6 selesai."
}

build_v6_patch_npk() {
    log_step "[V6] 3. Melakukan Patching & Signing Paket NPK v6"
    for file in "$BUILD_DIR/all_packages/"*.npk; do
        python3 npk.py sign "$file" "$file"
    done

    python3 npk.py create "$BUILD_DIR/all_packages/gps-$VERSION.npk" "$BUILD_DIR/all_packages/option-$VERSION.npk" option "$BUILD_DIR/option.sfs" -desc="busybox"
    rm -rf "$BUILD_DIR/option.sfs"

    log_info "Mem-patch system-$VERSION.npk..."
    python3 patch.py npk "$BUILD_DIR/system-$VERSION.npk" -O "$BUILD_DIR/all_packages/system-$VERSION.npk"

    (cd "$BUILD_DIR/all_packages" && zip -r "$PUBLISH_DIR/all_packages-$ARCH-$VERSION.zip" .)
    mv "$BUILD_DIR/all_packages/"*.npk "$PUBLISH_DIR/"
    rm -rf "$BUILD_DIR/all_packages"

    log_info "Mem-patch routeros-$ARCH-$VERSION.npk..."
    python3 patch.py npk "$ros_npk" -O "$PUBLISH_DIR/routeros-$ARCH-$VERSION.npk"
    log_ok "Paket v6 berhasil di-patch & sign: $PUBLISH_DIR/routeros-$ARCH-$VERSION.npk"
}

build_v6_iso_and_install() {
    log_step "[V6] 4. Membangun ISO & USB Install Image v6"
    unzip -q "$PUBLISH_DIR/all_packages-$ARCH-$VERSION.zip" -d "$BUILD_DIR/new_iso/"

    # Patch initrd.rgz
    mv "$BUILD_DIR/new_iso/isolinux/initrd.rgz" "$BUILD_DIR/initrd.rgz"
    python3 patch.py kernel "$BUILD_DIR/initrd.rgz" -O "$BUILD_DIR/new_iso/isolinux/initrd.rgz"
    rm -f "$BUILD_DIR/initrd.rgz"

    # 1. ISO Image
    log_info "Menyusun CD-ROM ISO v6..."
    xorriso -as mkisofs -o "$PUBLISH_DIR/mikrotik-$VERSION.iso" \
        -V "MikroTik $VERSION" -sysid "" -preparer "MiKroTiK" \
        -publisher "" -A "MiKroTiK RouterOS" -input-charset utf-8 \
        -b isolinux/isolinux.bin -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table -R -J \
        "$BUILD_DIR/new_iso"
    log_ok "ISO v6 berhasil dibuat: $PUBLISH_DIR/mikrotik-$VERSION.iso"

    # 2. USB Install Image
    log_info "Membuat image installer USB v6 (install-image-$VERSION.img)..."
    local install_img="$BUILD_DIR/install-image-$VERSION.img"
    truncate --size 128M "$install_img"
    mkfs.vfat -I -F 32 -n "Install" "$install_img"
    local loop_dev
    loop_dev=$(losetup -f --show "$install_img")
    syslinux --install "$loop_dev"
    mkdir -p "$BUILD_DIR/install"
    mount -o loop "$loop_dev" "$BUILD_DIR/install"

    cp -vf "$BUILD_DIR/new_iso/isolinux/linux" "$BUILD_DIR/install/"
    cp -vf /usr/lib/syslinux/modules/bios/ldlinux.c32 "$BUILD_DIR/install/" 2>/dev/null || cp -vf /usr/lib/syslinux/ldlinux.c32 "$BUILD_DIR/install/" 2>/dev/null || true
    cp -vf "$BUILD_DIR/new_iso/isolinux/initrd.rgz" "$BUILD_DIR/install/initrd.rgz"

    cat << 'EOF' > "$BUILD_DIR/install/syslinux.cfg"
default system
LABEL system
  KERNEL linux
  APPEND load_ramdisk=1 initrd=initrd.rgz -hdd-install
EOF

    local idx=1
    for npk in "$BUILD_DIR/new_iso/"*.npk; do
        cp "$npk" "$BUILD_DIR/install/$idx.npk"
        ((idx++))
    done
    touch "$BUILD_DIR/install/CHOOSE"
    sync
    umount "$BUILD_DIR/install"
    losetup -d "$loop_dev"
    rm -rf "$BUILD_DIR/install"

    (cd "$BUILD_DIR" && zip "$PUBLISH_DIR/install-image-$VERSION.zip" "install-image-$VERSION.img")
    rm -f "$install_img"
    rm -rf "$BUILD_DIR/new_iso"
    log_ok "USB install image v6 berhasil dibuat: $PUBLISH_DIR/install-image-$VERSION.zip"
}

build_v6_chr() {
    log_step "[V6] 5. Membangun CHR Image v6"
    modprobe nbd 2>/dev/null || true

    mkdir -p "$BUILD_DIR/chr"
    local chr_img="$BUILD_DIR/chr-$VERSION$ARCH_EXT.img"
    truncate --size 128M "$chr_img"

    # MBR partition menggunakan sfdisk
    sfdisk "$chr_img" <<EOF
label: dos
unit: sectors
start=1, size=, type=83, bootable
EOF

    dd if="$chr_img" of="$BUILD_DIR/mbr.bin" bs=1 count=512 conv=notrunc status=none
    # Tulis boot sector code
    python3 -c "import sys; sys.stdout.buffer.write(bytes.fromhex('FA31C08ED0BC007C89E65007501FFBFCBF0006B90001F2A5EA1D060000BEBE07B304803C807423803C00750983C610FECB75EFCD18BE9B06AC3C00740B56BB0700B40ECD105EEBF0EBFE8B148B4C0289F5BF0500BB007CB8010257CD135F730C31C0CD134F75EDBE7C06EBCCBFFE7D813D55AA75C289EEEA007C00004572726F72206C6F6164696E67206F7065726174696E672073797374656D004D697373696E67206F7065726174696E672073797374656D0000000000'))" | dd of="$BUILD_DIR/mbr.bin" bs=1 count=440 conv=notrunc status=none
    # Active CHR mode marker (byte offset 336: 0x01)
    printf '\x01' | dd of="$BUILD_DIR/mbr.bin" bs=1 count=1 seek=336 conv=notrunc status=none
    dd if="$BUILD_DIR/mbr.bin" of="$chr_img" bs=1 count=512 conv=notrunc status=none
    rm -f "$BUILD_DIR/mbr.bin"

    qemu-nbd -d /dev/nbd0 2>/dev/null || true
    qemu-nbd -c /dev/nbd0 -f raw "$chr_img"
    partprobe /dev/nbd0 || sleep 1

    mkfs.ext3 -F -L "system" -m 0 /dev/nbd0p1
    mount /dev/nbd0p1 "$BUILD_DIR/chr"

    mkdir -p "$BUILD_DIR/chr/"{boot,bin,rw/disk,var/pdb/{routeros-x86,option,dude}}
    mkdir -p "$BUILD_DIR/"{boot,bin}

    log_info "Mengekstrak kernel & bootloader milo v6 dari NPK..."
    python3 npk.py extract "$PUBLISH_DIR/routeros-$ARCH-$VERSION.npk" bin/milo "$BUILD_DIR/bin/milo"
    chmod +x "$BUILD_DIR/bin/milo"
    python3 npk.py extract "$PUBLISH_DIR/routeros-$ARCH-$VERSION.npk" boot/vmlinuz-64 "$BUILD_DIR/boot/vmlinuz-64"
    python3 npk.py extract "$PUBLISH_DIR/routeros-$ARCH-$VERSION.npk" boot/initrd.rgz "$BUILD_DIR/boot/initrd.rgz"
    python3 npk.py extract "$PUBLISH_DIR/routeros-$ARCH-$VERSION.npk" boot/map "$BUILD_DIR/boot/map"
    python3 npk.py extract "$PUBLISH_DIR/routeros-$ARCH-$VERSION.npk" boot/milo.conf "$BUILD_DIR/boot/milo.conf"
    python3 npk.py extract "$PUBLISH_DIR/routeros-$ARCH-$VERSION.npk" boot/vmlinuz "$BUILD_DIR/boot/vmlinuz"
    python3 npk.py extract "$PUBLISH_DIR/routeros-$ARCH-$VERSION.npk" boot/vmlinuz-smp "$BUILD_DIR/boot/vmlinuz-smp"

    mv "$BUILD_DIR/boot" "$BUILD_DIR/chr/"
    mv "$BUILD_DIR/bin" "$BUILD_DIR/chr/"

    cp -v "$PUBLISH_DIR/routeros-$ARCH-$VERSION.npk" "$BUILD_DIR/chr/var/pdb/routeros-x86/image"
    cp -v "$PUBLISH_DIR/option-$VERSION$ARCH_EXT.npk" "$BUILD_DIR/chr/var/pdb/option/image"
    if [ -f "$PUBLISH_DIR/dude-$VERSION$ARCH_EXT.npk" ]; then
        cp -v "$PUBLISH_DIR/dude-$VERSION$ARCH_EXT.npk" "$BUILD_DIR/chr/var/pdb/dude/image"
    fi

    cat << 'EOF' > "$BUILD_DIR/chr/rw/disk/rc.local"
#!/bin/sh
# This script will be executed *before* RouterOS *loader* start.
# Put custom initialization commands here.
EOF
    chmod +x "$BUILD_DIR/chr/rw/disk/rc.local"
    touch "$BUILD_DIR/chr/rw/REBOOT"
    touch "$BUILD_DIR/chr/rw/ENABLE_X86_64"
    touch "$BUILD_DIR/chr/UPGRADED"
    touch "$BUILD_DIR/chr/SHOW_LICENSE"
    chown -R root:root "$BUILD_DIR/chr"

    # Pasang bootloader milo via chroot
    chroot "$BUILD_DIR/chr" /bin/milo /boot

    sync
    umount "$BUILD_DIR/chr"
    qemu-nbd -d /dev/nbd0 2>/dev/null || true
    rm -rf "$BUILD_DIR/chr"

    log_info "Mengonversi format image virtual v6..."
    local prefix="${chr_img%.img}"
    local name="${prefix##*/}"

    qemu-img convert -f raw -O qcow2 "$chr_img" "$prefix.qcow2"
    qemu-img convert -f raw -O vmdk  "$chr_img" "$prefix.vmdk"
    qemu-img convert -f raw -O vpc   "$chr_img" "$prefix.vhd"
    qemu-img convert -f raw -O vhdx  "$chr_img" "$prefix.vhdx"
    qemu-img convert -f raw -O vdi   "$chr_img" "$prefix.vdi"

    (cd "$BUILD_DIR" && \
        zip -q "$PUBLISH_DIR/$name.qcow2.zip" "$name.qcow2" && \
        zip -q "$PUBLISH_DIR/$name.vmdk.zip" "$name.vmdk" && \
        zip -q "$PUBLISH_DIR/$name.vhd.zip" "$name.vhd" && \
        zip -q "$PUBLISH_DIR/$name.vhdx.zip" "$name.vhdx" && \
        zip -q "$PUBLISH_DIR/$name.vdi.zip" "$name.vdi" && \
        zip -q "$PUBLISH_DIR/$name.img.zip" "$name.img" )
    rm -f "$prefix".*
    log_ok "Semua format image CHR v6 berhasil dibuat."
}

# ==============================================================================
# MAIN EXECUTION FLOW
# ==============================================================================

main() {
    show_banner
    check_system
    check_dependencies
    setup_environment
    resolve_version
    setup_dirs

    if [[ "$MAJOR_VERSION" == "v7" ]]; then
        build_v7_option
        build_v7_download_and_extract
        build_v7_patch_npk

        if [[ "$TARGET" == "all" || "$TARGET" == "iso" || "$TARGET" == "install" ]]; then
            build_v7_iso_and_install
        fi

        if [[ "$TARGET" == "all" || "$TARGET" == "chr" ]]; then
            build_v7_chr
        fi

    elif [[ "$MAJOR_VERSION" == "v6" ]]; then
        build_v6_option
        build_v6_download_and_extract
        build_v6_patch_npk

        if [[ "$TARGET" == "all" || "$TARGET" == "iso" || "$TARGET" == "install" ]]; then
            build_v6_iso_and_install
        fi

        if [[ "$TARGET" == "all" || "$TARGET" == "chr" ]]; then
            build_v6_chr
        fi
    fi

    # Buat Checksum SHA256
    log_step "Membuat Checksum SHA256 untuk Semua Artefak"
    (
        cd "$PUBLISH_DIR"
        for f in *.zip *.iso *.npk; do
            if [ -f "$f" ]; then
                sha256sum "$f" > "$f.sha256"
            fi
        done
    )

    echo ""
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${BOLD}${GREEN}  BUILD LOKAL SELESAI DENGAN SUKSES!${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "Semua image dan paket telah tersimpan di direktori:"
    echo -e "  ${CYAN}$PUBLISH_DIR${NC}"
    echo ""
    ls -lh "$PUBLISH_DIR"
}

main "$@"
