#!/usr/bin/env bash
# ==============================================================================
# patch_branding.sh - MikroTik RouterOS Custom Branding Tool
# ==============================================================================
# Skrip ini digunakan untuk memodifikasi file ISO RouterOS (v6 atau v7):
# 1. Mengubah tampilan logo ASCII pada CLI terminal (nova/lib/console/logo.txt).
# 2. Menambahkan/mengubah menu "About" di WebFig (option.jg & option.info).
#
# Bekerja pada ISO yang sudah di-patch maupun ISO baru (asalkan di-sign dengan kunci .env).
# TIDAK MEMERLUKAN loader.7z karena hanya memodifikasi branding & filesystem NPK.
# ==============================================================================

set -eo pipefail

C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_MAGENTA='\033[0;35m'
C_BOLD='\033[1m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR=""

cleanup() {
    local exit_code=$?
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        if mountpoint -q "$WORK_DIR/iso_mount" 2>/dev/null; then
            echo -e "${C_YELLOW}[*] Melepas mount ISO...${C_RESET}"
            sudo umount "$WORK_DIR/iso_mount" 2>/dev/null || true
        fi
        rm -rf "$WORK_DIR" 2>/dev/null || true
    fi
    exit $exit_code
}
trap cleanup EXIT INT TERM

log_info()  { echo -e "${C_CYAN}[INFO]${C_RESET} $*"; }
log_ok()    { echo -e "${C_GREEN}[✓]${C_RESET} $*"; }
log_warn()  { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
log_err()   { echo -e "${C_RED}[ERROR]${C_RESET} $*"; }
log_step()  { echo -e "\n${C_BOLD}${C_BLUE}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }

show_banner() {
    echo -e "${C_CYAN}${C_BOLD}"
    cat << 'EOF'
  __  __ _ _             _____ _ _    ____                  _ _             
 |  \/  (_) |           |_   _(_) |  |  _ \                | (_)            
 | \  / |_| | ___ __ ___  | |  _| | _| |_) |_ __ __ _ _ __ | |_ _ __   __ _ 
 | |\/| | | |/ / '__/ _ \ | | | | |/ /  _ <| '__/ _` | '_ \| | | '_ \ / _` |
 | |  | | |   <| | | (_) || | | |   <| |_) | | | (_| | | | | | | | | | (_| |
 |_|  |_|_|_|\_\_|  \___/ |_| |_|_|\_\____/|_|  \__,_|_| |_|_|_|_| |_|\__, |
                                                                        __/ |
  MikroTik RouterOS Custom Branding Tool                               |___/ 
EOF
    echo -e "${C_RESET}"
}

show_help() {
    show_banner
    echo -e "${C_BOLD}Penggunaan:${C_RESET}"
    echo -e "  $0 [OPSI]"
    echo ""
    echo -e "${C_BOLD}Opsi Utama:${C_RESET}"
    echo -e "  ${C_GREEN}-i, --iso <file>${C_RESET}          Path ke file ISO RouterOS sumber (v6 atau v7)"
    echo -e "  ${C_GREEN}-o, --output <file>${C_RESET}       Path ke file ISO hasil (default: <iso_name>_branded.iso)"
    echo -e "  ${C_GREEN}-l, --logo <file>${C_RESET}         File teks berisi gambar/teks ASCII untuk CLI terminal"
    echo -e "  ${C_GREEN}--extract-logo <file>${C_RESET}     Ekstrak logo.txt asli dari ISO ke file teks lokal"
    echo ""
    echo -e "${C_BOLD}Opsi WebFig About Menu:${C_RESET}"
    echo -e "  ${C_GREEN}-t, --title <title>${C_RESET}       Judul menu WebFig (default: 'About')"
    echo -e "  ${C_GREEN}-a, --author <author>${C_RESET}     Nama Author/Pembuat (default: 'Network Admin')"
    echo -e "  ${C_GREEN}-u, --url <website>${C_RESET}       URL Website/Homepage"
    echo -e "  ${C_GREEN}--telegram <kontak>${C_RESET}       Kontak Telegram (username / link channel)"
    echo -e "  ${C_GREEN}--note <catatan>${C_RESET}          Catatan kustom yang ditampilkan di tab About"
    echo ""
    echo -e "${C_BOLD}Opsi Filter:${C_RESET}"
    echo -e "  ${C_GREEN}--skip-logo${C_RESET}               Hanya modifikasi WebFig About (jangan ubah CLI logo)"
    echo -e "  ${C_GREEN}--skip-webfig${C_RESET}             Hanya modifikasi CLI Logo (jangan ubah WebFig About)"
    echo -e "  ${C_GREEN}-m, --interactive${C_RESET}         Jalankan wizard menu interaktif step-by-step"
    echo -e "  ${C_GREEN}-h, --help${C_RESET}                Tampilkan bantuan ini"
    echo ""
    echo -e "${C_BOLD}Contoh Penggunaan:${C_RESET}"
    echo -e "  ${C_YELLOW}# 1. Jalankan wizard interaktif:${C_RESET}"
    echo -e "  $0 -m"
    echo ""
    echo -e "  ${C_YELLOW}# 2. Patch logo dan about sekaligus:${C_RESET}"
    echo -e "  $0 -i mikrotik-7.18.2.iso -l my_logo.txt -a 'PT Network Solusi' -u 'https://netsolusi.co.id' -o routeros_custom.iso"
    echo ""
    echo -e "  ${C_YELLOW}# 3. Ekstrak logo CLI dari ISO untuk dilihat:${C_RESET}"
    echo -e "  $0 -i mikrotik-7.18.2.iso --extract-logo original_logo.txt"
    echo ""
}

# Default variables
INPUT_ISO=""
OUTPUT_ISO=""
LOGO_FILE=""
EXTRACT_LOGO_FILE=""
MENU_TITLE="About"
AUTHOR_NAME="Network Admin"
WEBSITE_URL="https://mikrotik.com"
TELEGRAM_CONTACT=""
CUSTOM_NOTE="Custom RouterOS Edition"
SKIP_LOGO=0
SKIP_WEBFIG=0
INTERACTIVE=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--iso)
            INPUT_ISO="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_ISO="$2"
            shift 2
            ;;
        -l|--logo)
            LOGO_FILE="$2"
            shift 2
            ;;
        --extract-logo)
            EXTRACT_LOGO_FILE="$2"
            shift 2
            ;;
        -t|--title)
            MENU_TITLE="$2"
            shift 2
            ;;
        -a|--author)
            AUTHOR_NAME="$2"
            shift 2
            ;;
        -u|--url)
            WEBSITE_URL="$2"
            shift 2
            ;;
        --telegram)
            TELEGRAM_CONTACT="$2"
            shift 2
            ;;
        --note)
            CUSTOM_NOTE="$2"
            shift 2
            ;;
        --skip-logo)
            SKIP_LOGO=1
            shift
            ;;
        --skip-webfig)
            SKIP_WEBFIG=1
            shift
            ;;
        -m|--interactive)
            INTERACTIVE=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_err "Argumen tidak dikenal: $1"
            show_help
            exit 1
            ;;
    esac
done

check_dependencies() {
    log_step "Memeriksa Kebutuhan Sistem & Dependency..."

    local missing=()
    for cmd in python3 mksquashfs unsquashfs; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    # Check for ISO extraction tool: xorriso or 7z
    if ! command -v xorriso &>/dev/null && ! command -v 7z &>/dev/null; then
        missing+=("xorriso (atau p7zip-full)")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        log_err "Dependensi berikut belum terpasang:"
        for item in "${missing[@]}"; do
            echo -e "  - ${C_RED}$item${C_RESET}"
        done
        echo ""
        log_warn "Di Ubuntu/Debian, Anda dapat memasangnya dengan:"
        echo -e "  ${C_YELLOW}sudo apt-get update && sudo apt-get install -y squashfs-tools xorriso p7zip-full python3-crcmod${C_RESET}"
        exit 1
    fi

    # Check python crcmod
    if ! python3 -c "import crcmod" &>/dev/null; then
        log_warn "Python package 'crcmod' belum terdeteksi. Mencoba verifikasi..."
        if ! python3 -c "import crcmod" &>/dev/null; then
            log_err "Package python3-crcmod diperlukan untuk menghitung checksum WebFig."
            log_warn "Jalankan: sudo apt-get install -y python3-crcmod (atau pip install crcmod)"
            exit 1
        fi
    fi

    # Check .env keys
    if [ ! -f "$SCRIPT_DIR/.env" ] && [ -z "$CUSTOM_LICENSE_PRIVATE_KEY" ]; then
        log_warn "File .env belum ditemukan. Membuat pasangan kunci tanda tangan kriptografi baru..."
        python3 "$SCRIPT_DIR/gen_keys.py"
        log_ok "Kunci kriptografi berhasil dibuat dan disimpan di .env"
    fi

    log_ok "Semua dependensi dan kunci kriptografi siap!"
}

interactive_wizard() {
    show_banner
    echo -e "${C_BOLD}=== Wizard Interaktif Custom Branding RouterOS ===${C_RESET}\n"

    # 1. Input ISO
    while [ -z "$INPUT_ISO" ] || [ ! -f "$INPUT_ISO" ]; do
        echo -e "${C_CYAN}Masukkan path file ISO RouterOS (v6 atau v7):${C_RESET}"
        read -rp "> " INPUT_ISO
        INPUT_ISO=$(echo "$INPUT_ISO" | tr -d '\r')
        if [ ! -f "$INPUT_ISO" ]; then
            log_err "File '$INPUT_ISO' tidak ditemukan. Silakan masukkan path yang valid."
        fi
    done

    # 2. Action Menu
    echo -e "\n${C_BOLD}Pilih Aksi yang Ingin Dilakukan:${C_RESET}"
    echo -e "  ${C_GREEN}[1]${C_RESET} Patch Logo CLI ASCII + Menu WebFig About (Rekomendasi)"
    echo -e "  ${C_GREEN}[2]${C_RESET} Patch Logo CLI ASCII saja"
    echo -e "  ${C_GREEN}[3]${C_RESET} Patch Menu WebFig About saja"
    echo -e "  ${C_GREEN}[4]${C_RESET} Ekstrak Logo CLI dari ISO (untuk dilihat/diedit)"
    read -rp "Pilihan [1-4, default: 1]: " ACTION_CHOICE
    ACTION_CHOICE=$(echo "$ACTION_CHOICE" | tr -d '\r')
    ACTION_CHOICE="${ACTION_CHOICE:-1}"

    case "$ACTION_CHOICE" in
        1)
            SKIP_LOGO=0
            SKIP_WEBFIG=0
            ;;
        2)
            SKIP_LOGO=0
            SKIP_WEBFIG=1
            ;;
        3)
            SKIP_LOGO=1
            SKIP_WEBFIG=0
            ;;
        4)
            echo -e "\n${C_CYAN}Masukkan nama file untuk menyimpan logo yang diekstrak:${C_RESET}"
            read -rp "[default: original_logo.txt]: " EXTRACT_LOGO_FILE
            EXTRACT_LOGO_FILE=$(echo "$EXTRACT_LOGO_FILE" | tr -d '\r')
            EXTRACT_LOGO_FILE="${EXTRACT_LOGO_FILE:-original_logo.txt}"
            return 0
            ;;
        *)
            log_warn "Pilihan tidak valid, menggunakan default [1]."
            SKIP_LOGO=0
            SKIP_WEBFIG=0
            ;;
    esac

    # 3. Logo Options
    if [ "$SKIP_LOGO" -eq 0 ]; then
        echo -e "\n${C_BOLD}Pengaturan Logo CLI Terminal:${C_RESET}"
        echo -e "Masukkan path file logo ASCII kustom (kosongkan untuk menggunakan template default):"
        read -rp "[default: $SCRIPT_DIR/default_logo.txt]: " LOGO_INPUT
        LOGO_INPUT=$(echo "$LOGO_INPUT" | tr -d '\r')
        if [ -n "$LOGO_INPUT" ] && [ -f "$LOGO_INPUT" ]; then
            LOGO_FILE="$LOGO_INPUT"
        else
            LOGO_FILE="$SCRIPT_DIR/default_logo.txt"
        fi
        log_info "Menggunakan logo file: $LOGO_FILE"
    fi

    # 4. WebFig About Options
    if [ "$SKIP_WEBFIG" -eq 0 ]; then
        echo -e "\n${C_BOLD}Pengaturan Menu WebFig About:${C_RESET}"

        read -rp "Judul Menu WebFig [default: $MENU_TITLE]: " VAL
        VAL=$(echo "$VAL" | tr -d '\r'); [ -n "$VAL" ] && MENU_TITLE="$VAL"

        read -rp "Nama Author / Organisasi [default: $AUTHOR_NAME]: " VAL
        VAL=$(echo "$VAL" | tr -d '\r'); [ -n "$VAL" ] && AUTHOR_NAME="$VAL"

        read -rp "URL Website / Homepage [default: $WEBSITE_URL]: " VAL
        VAL=$(echo "$VAL" | tr -d '\r'); [ -n "$VAL" ] && WEBSITE_URL="$VAL"

        read -rp "Kontak Telegram [opsional]: " VAL
        VAL=$(echo "$VAL" | tr -d '\r'); [ -n "$VAL" ] && TELEGRAM_CONTACT="$VAL"

        read -rp "Catatan / Note [default: $CUSTOM_NOTE]: " VAL
        VAL=$(echo "$VAL" | tr -d '\r'); [ -n "$VAL" ] && CUSTOM_NOTE="$VAL"
    fi

    # 5. Output ISO
    local iso_dir="$(dirname "$INPUT_ISO")"
    local iso_base="$(basename "$INPUT_ISO" .iso)"
    local def_out="${iso_dir}/${iso_base}_branded.iso"

    echo -e "\n${C_CYAN}Nama file ISO output:${C_RESET}"
    read -rp "[default: $def_out]: " VAL
    VAL=$(echo "$VAL" | tr -d '\r')
    OUTPUT_ISO="${VAL:-$def_out}"
}

# Main execution logic
main() {
    if [ "$INTERACTIVE" -eq 1 ] || [ -z "$INPUT_ISO" ]; then
        interactive_wizard
    fi

    if [ ! -f "$INPUT_ISO" ]; then
        log_err "File ISO input '$INPUT_ISO' tidak ditemukan!"
        exit 1
    fi

    check_dependencies

    WORK_DIR="$(mktemp -d -t ros_branding_XXXXXX)"
    local ISO_EXTRACT="$WORK_DIR/iso_extracted"
    mkdir -p "$ISO_EXTRACT"

    log_step "Mengekstrak Isi File ISO: $INPUT_ISO"
    if command -v xorriso &>/dev/null; then
        xorriso -osirrox on -indev "$INPUT_ISO" -extract / "$ISO_EXTRACT" 2>/dev/null || {
            log_warn "Ekstraksi xorriso gagal, mencoba metode alternatif..."
            if command -v 7z &>/dev/null; then
                7z x -y "$INPUT_ISO" -o"$ISO_EXTRACT" >/dev/null
            fi
        }
    elif command -v 7z &>/dev/null; then
        7z x -y "$INPUT_ISO" -o"$ISO_EXTRACT" >/dev/null
    else
        log_err "Tidak ada tool untuk mengekstrak ISO (xorriso atau 7z)."
        exit 1
    fi

    chmod -R u+w "$ISO_EXTRACT"
    log_ok "ISO berhasil diekstrak ke direktori kerja."

    # Deteksi paket utama RouterOS
    local MAIN_NPK=""
    local ROS_MAJOR="7"
    local ARCH="x86"
    local VERSION="7.18.2"

    if ls "$ISO_EXTRACT"/routeros-*.npk &>/dev/null; then
        MAIN_NPK=$(ls "$ISO_EXTRACT"/routeros-*.npk | head -n1)
        ROS_MAJOR="7"
    elif ls "$ISO_EXTRACT"/system-*.npk &>/dev/null; then
        MAIN_NPK=$(ls "$ISO_EXTRACT"/system-*.npk | head -n1)
        ROS_MAJOR="6"
    else
        log_err "Tidak dapat menemukan routeros-*.npk atau system-*.npk di dalam ISO!"
        exit 1
    fi

    # Ekstrak versi dari nama file
    local npk_base="$(basename "$MAIN_NPK")"
    if [[ "$npk_base" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
        VERSION="${BASH_REMATCH[1]}"
    fi
    if [[ "$npk_base" =~ arm64 ]]; then
        ARCH="arm64"
    fi

    log_info "Terdeteksi: RouterOS v${ROS_MAJOR} (Versi: ${VERSION}, Arsitektur: ${ARCH})"
    log_info "Paket Utama: $(basename "$MAIN_NPK")"

    # Jika user hanya meminta ekstraksi logo
    if [ -n "$EXTRACT_LOGO_FILE" ]; then
        log_step "Mengekstrak Logo CLI dari NPK Utama..."
        python3 "$SCRIPT_DIR/patch_branding.py" extract-logo "$MAIN_NPK" "$EXTRACT_LOGO_FILE"
        log_ok "Logo berhasil diekstrak ke: ${C_BOLD}$EXTRACT_LOGO_FILE${C_RESET}"
        echo -e "\n${C_GREEN}Silakan edit file '$EXTRACT_LOGO_FILE' lalu jalankan skrip ini kembali dengan opsi:${C_RESET}"
        echo -e "  ${C_YELLOW}$0 -i \"$INPUT_ISO\" -l \"$EXTRACT_LOGO_FILE\"${C_RESET}\n"
        exit 0
    fi

    # Default output path jika belum diset
    if [ -z "$OUTPUT_ISO" ]; then
        local iso_dir="$(dirname "$INPUT_ISO")"
        local iso_base="$(basename "$INPUT_ISO" .iso)"
        OUTPUT_ISO="${iso_dir}/${iso_base}_branded.iso"
    fi

    # Step 1: Patch Logo CLI Terminal
    if [ "$SKIP_LOGO" -eq 0 ]; then
        log_step "Memodifikasi Logo ASCII CLI Terminal..."
        if [ -z "$LOGO_FILE" ]; then
            LOGO_FILE="$SCRIPT_DIR/default_logo.txt"
        fi
        if [ ! -f "$LOGO_FILE" ]; then
            log_err "File logo '$LOGO_FILE' tidak ditemukan!"
            exit 1
        fi

        log_info "Mengganti nova/lib/console/logo.txt dengan: $LOGO_FILE"
        python3 "$SCRIPT_DIR/patch_branding.py" update-logo "$MAIN_NPK" "$MAIN_NPK" "$LOGO_FILE"
        log_ok "Logo CLI berhasil diperbarui dan ditandatangani ulang!"
    else
        log_info "Melewati modifikasi CLI Logo (--skip-logo)."
    fi

    # Step 2: Patch WebFig About Menu
    if [ "$SKIP_WEBFIG" -eq 0 ]; then
        log_step "Membangun Menu WebFig About..."
        local OPTION_SFS="$WORK_DIR/option.sfs"
        local TARGET_OPTION_NPK="$ISO_EXTRACT/option-$VERSION.npk"

        # Bangun option.sfs (WebFig JSON UI + Checksum + Metadata)
        python3 "$SCRIPT_DIR/patch_branding.py" build-option-sfs "$OPTION_SFS" \
            --arch "$ARCH" \
            --title "$MENU_TITLE" \
            --author "$AUTHOR_NAME" \
            --website "$WEBSITE_URL" \
            --telegram "$TELEGRAM_CONTACT" \
            --note "$CUSTOM_NOTE" \
            --version "$VERSION"

        # Cari base package untuk option.npk
        local BASE_NPK=""
        if ls "$ISO_EXTRACT"/option-*.npk &>/dev/null; then
            BASE_NPK=$(ls "$ISO_EXTRACT"/option-*.npk | head -n1)
            TARGET_OPTION_NPK="$BASE_NPK"
            log_info "Memperbarui paket option yang sudah ada: $(basename "$BASE_NPK")"
        elif ls "$ISO_EXTRACT"/gps-*.npk &>/dev/null; then
            BASE_NPK=$(ls "$ISO_EXTRACT"/gps-*.npk | head -n1)
            log_info "Menggunakan gps package sebagai template: $(basename "$BASE_NPK")"
        else
            # Cari paket tambahan lain selain paket utama
            for pkg in "$ISO_EXTRACT"/*.npk; do
                if [ "$pkg" != "$MAIN_NPK" ]; then
                    BASE_NPK="$pkg"
                    break
                fi
            done
        fi

        # Jika tidak ada paket tambahan di dalam ISO (misal ISO minimal vanilla)
        if [ -z "$BASE_NPK" ] || [ ! -f "$BASE_NPK" ]; then
            log_warn "Tidak ada paket tambahan di dalam ISO. Mengunduh gps package resmi sebagai template..."
            mkdir -p "$SCRIPT_DIR/cache/packages"
            local CACHED_GPS="$SCRIPT_DIR/cache/packages/gps-$VERSION.npk"
            if [ ! -f "$CACHED_GPS" ]; then
                local GPS_URL="https://download.mikrotik.com/routeros/$VERSION/gps-$VERSION.npk"
                log_info "Mengunduh: $GPS_URL"
                curl -fsSL -o "$CACHED_GPS" "$GPS_URL" || wget -q -O "$CACHED_GPS" "$GPS_URL" || true
            fi
            if [ -f "$CACHED_GPS" ] && [ -s "$CACHED_GPS" ]; then
                BASE_NPK="$CACHED_GPS"
            else
                log_warn "Tidak dapat mengunduh gps.npk, menggunakan paket utama sebagai basis..."
                BASE_NPK="$MAIN_NPK"
            fi
        fi

        log_info "Membuat option.npk dari: $(basename "$BASE_NPK")"
        python3 "$SCRIPT_DIR/patch_branding.py" create-option-npk "$BASE_NPK" "$TARGET_OPTION_NPK" "$OPTION_SFS"
        log_ok "Paket option.npk untuk WebFig berhasil dibuat dan ditandatangani ulang!"
    else
        log_info "Melewati modifikasi WebFig About (--skip-webfig)."
    fi

    # Step 3: Repack ISO dengan xorriso
    log_step "Membuat Ulang File Bootable ISO: $OUTPUT_ISO"

    # Bersihkan file boot catalog lama jika ada
    rm -f "$ISO_EXTRACT/isolinux/boot.cat"

    local HAS_EFI=0
    if [ -f "$ISO_EXTRACT/efiboot.img" ]; then
        HAS_EFI=1
        log_info "Terdeteksi mode boot hybrid (BIOS + UEFI)."
    else
        log_info "Terdeteksi mode boot standar (BIOS)."
    fi

    local XORRISO_CMD=(
        xorriso -as mkisofs
        -o "$OUTPUT_ISO"
        -V "MikroTik"
        -publisher "WWW.MIKROTIK.COM"
        -preparer "MIKROTIK"
        -A "MIKROTIK_ROUTER"
        -sysid ""
        -b "isolinux/isolinux.bin"
        -c "isolinux/boot.cat"
        -no-emul-boot
        -boot-load-size 4
        -boot-info-table
    )

    if [ "$HAS_EFI" -eq 1 ]; then
        XORRISO_CMD+=(
            -eltorito-alt-boot
            -e "efiboot.img"
            -no-emul-boot
        )
    fi

    XORRISO_CMD+=("$ISO_EXTRACT")

    "${XORRISO_CMD[@]}"

    if [ -f "$OUTPUT_ISO" ] && [ -s "$OUTPUT_ISO" ]; then
        local iso_size
        iso_size=$(du -h "$OUTPUT_ISO" | cut -f1)
        echo ""
        echo -e "${C_GREEN}${C_BOLD}================================================================${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}  [✓] PROSES CUSTOM BRANDING BERHASIL!                         ${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}================================================================${C_RESET}"
        echo -e "  ${C_BOLD}File Output:${C_RESET}      $OUTPUT_ISO"
        echo -e "  ${C_BOLD}Ukuran ISO:${C_RESET}       $iso_size"
        echo -e "  ${C_BOLD}Versi RouterOS:${C_RESET}   v$VERSION ($ARCH)"
        if [ "$SKIP_LOGO" -eq 0 ]; then
            echo -e "  ${C_BOLD}CLI ASCII Logo:${C_RESET}   Telah diperbarui dari '$LOGO_FILE'"
        fi
        if [ "$SKIP_WEBFIG" -eq 0 ]; then
            echo -e "  ${C_BOLD}WebFig About:${C_RESET}     Title: '$MENU_TITLE' | Author: '$AUTHOR_NAME'"
            echo -e "                    Website: '$WEBSITE_URL'"
        fi
        echo -e "${C_GREEN}${C_BOLD}================================================================${C_RESET}"
        echo -e "\n${C_CYAN}Tips Pengujian ISO:${C_RESET}"
        echo -e "  Gunakan VirtualBox, VMware, Proxmox, atau QEMU untuk menguji instalasi:"
        echo -e "  ${C_YELLOW}qemu-system-x86_64 -m 512 -cdrom \"$OUTPUT_ISO\" -boot d${C_RESET}\n"
    else
        log_err "Gagal membuat file ISO output!"
        exit 1
    fi
}

main "$@"
