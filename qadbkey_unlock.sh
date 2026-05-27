#!/bin/sh
# =========================================================
# Quectel ADB Unlock Tool for OpenWrt
# =========================================================

TIMEOUT=2

# ---------------------------------------------------------
# Colors
# ---------------------------------------------------------
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# ---------------------------------------------------------
# Print helpers
# ---------------------------------------------------------
info() {
    echo -e "${BLUE}[*]${RESET} $*"
}

ok() {
    echo -e "${GREEN}[OK]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[!]${RESET} $*"
}

err() {
    echo -e "${RED}[ERR]${RESET} $*"
}

# ---------------------------------------------------------
# Detect package manager
# ---------------------------------------------------------
detect_pkgmgr() {
    if command -v apk >/dev/null 2>&1; then
        PKG="apk"
    elif command -v opkg >/dev/null 2>&1; then
        PKG="opkg"
    else
        PKG=""
    fi
}

# ---------------------------------------------------------
# Ensure openssl exists
# ---------------------------------------------------------
check_openssl() {
    if command -v openssl >/dev/null 2>&1; then
        ok "openssl ditemukan"
        return
    fi

    warn "openssl-util belum terinstall"

    detect_pkgmgr

    case "$PKG" in
        apk)
            echo
            echo "Install dengan:"
            echo "apk update && apk add openssl-util"
            ;;
        opkg)
            echo
            echo "Install dengan:"
            echo "opkg update && opkg install openssl-util"
            ;;
        *)
            echo
            echo "Silakan install openssl-util manual"
            ;;
    esac

    exit 1
}

# ---------------------------------------------------------
# Send AT command
# ---------------------------------------------------------
send_at() {
    PORT="$1"
    CMD="$2"

    # clear buffer
    cat "$PORT" >/dev/null 2>&1 &
    CATPID=$!

    sleep 0.2

    echo -ne "${CMD}\r" > "$PORT"

    sleep "$TIMEOUT"

    kill "$CATPID" >/dev/null 2>&1

    RESPONSE="$(timeout "$TIMEOUT" cat "$PORT" 2>/dev/null)"

    echo "$RESPONSE"
}

# ---------------------------------------------------------
# Detect working AT port
# ---------------------------------------------------------
detect_at_port() {
    info "Mendeteksi port AT..."

    for PORT in /dev/ttyUSB* /dev/ttyACM*; do
        [ -e "$PORT" ] || continue

        info "Uji $PORT"

        stty -F "$PORT" 115200 raw -echo -echoe -echok 2>/dev/null

        echo -ne "AT\r" > "$PORT"

        sleep 1

        RESP="$(timeout 2 cat "$PORT" 2>/dev/null)"

        echo "$RESP" | grep -q "OK"

        if [ $? -eq 0 ]; then
            ok "Port AT ditemukan: $PORT"
            AT_PORT="$PORT"
            return 0
        fi
    done

    err "Tidak ada port AT yang merespon"
    exit 1
}

# ---------------------------------------------------------
# Generate unlock key
# ---------------------------------------------------------
generate_unlock_key() {
    SN="$1"

    HASH="$(openssl passwd -1 -salt "$SN" SH_adb_quectel)"

    echo "$HASH" | cut -c13-27
}

# ---------------------------------------------------------
# Get modem challenge
# ---------------------------------------------------------
get_challenge() {
    info "Mengambil challenge key..."

    echo -ne 'AT+QADBKEY?\r' > "$AT_PORT"

    sleep 2

    RESP="$(timeout 3 cat "$AT_PORT" 2>/dev/null)"

    echo "$RESP"

    CHALLENGE="$(echo "$RESP" | grep -o '[0-9]\{8\}' | head -n1)"

    if [ -z "$CHALLENGE" ]; then
        err "Gagal membaca challenge key"
        exit 1
    fi

    ok "Challenge: $CHALLENGE"
}

# ---------------------------------------------------------
# Unlock ADB
# ---------------------------------------------------------
unlock_adb() {
    UNLOCK_KEY="$(generate_unlock_key "$CHALLENGE")"

    ok "Unlock key: $UNLOCK_KEY"

    CMD="AT+QADBKEY=\"$UNLOCK_KEY\""

    info "Mengirim unlock key..."

    echo -ne "${CMD}\r" > "$AT_PORT"

    sleep 2

    RESP="$(timeout 3 cat "$AT_PORT" 2>/dev/null)"

    echo "$RESP"

    echo "$RESP" | grep -q "OK"

    if [ $? -ne 0 ]; then
        err "ADB unlock gagal"
        exit 1
    fi

    ok "ADB unlock berhasil"
}

# ---------------------------------------------------------
# Read current USB config
# ---------------------------------------------------------
read_usbcfg() {
    info "Membaca konfigurasi USB..."

    echo -ne 'AT+QCFG="usbcfg"\r' > "$AT_PORT"

    sleep 2

    RESP="$(timeout 3 cat "$AT_PORT" 2>/dev/null)"

    echo "$RESP"

    CFG_LINE="$(echo "$RESP" | grep '+QCFG: "usbcfg"')"

    if [ -z "$CFG_LINE" ]; then
        err "Gagal membaca usbcfg"
        exit 1
    fi

    ok "Konfigurasi ditemukan"
}

# ---------------------------------------------------------
# Enable ADB in USB config
# ---------------------------------------------------------
enable_adb() {
    info "Mengaktifkan ADB interface..."

    NEWCFG="$(echo "$CFG_LINE" | sed 's/,\([01]\),\([01]\)$/\,1,\2/')"

    CMD="AT+QCFG=\"usbcfg\"${NEWCFG#*\"usbcfg\"}"

    echo
    echo "$CMD"
    echo

    echo -ne "${CMD}\r" > "$AT_PORT"

    sleep 2

    RESP="$(timeout 3 cat "$AT_PORT" 2>/dev/null)"

    echo "$RESP"

    echo "$RESP" | grep -q "OK"

    if [ $? -ne 0 ]; then
        err "Gagal mengaktifkan ADB"
        exit 1
    fi

    ok "ADB interface berhasil diaktifkan"
}

# ---------------------------------------------------------
# Verify
# ---------------------------------------------------------
verify_config() {
    info "Verifikasi konfigurasi..."

    echo -ne 'AT+QCFG="usbcfg"\r' > "$AT_PORT"

    sleep 2

    RESP="$(timeout 3 cat "$AT_PORT" 2>/dev/null)"

    echo "$RESP"

    echo "$RESP" | grep -q ',1,0'

    if [ $? -eq 0 ]; then
        ok "ADB interface aktif"
    else
        warn "ADB interface belum terverifikasi"
    fi
}

# ---------------------------------------------------------
# Reboot modem
# ---------------------------------------------------------
reboot_modem() {
    info "Reboot modem..."

    echo -ne 'AT+CFUN=1,1\r' > "$AT_PORT"

    sleep 1

    ok "Perintah reboot dikirim"
}

# ---------------------------------------------------------
# Main
# ---------------------------------------------------------
clear

echo "========================================="
echo "      Quectel ADB Unlock Tool"
echo "========================================="
echo

check_openssl
detect_at_port
get_challenge
unlock_adb
read_usbcfg
enable_adb
verify_config
reboot_modem

echo
ok "Selesai"
echo