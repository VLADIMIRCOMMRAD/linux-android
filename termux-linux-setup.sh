#!/data/data/com.termux/files/usr/bin/bash
#######################################################
#  Termux Linux Desktop Setup Script
#
#  Features:
#  - Choice of Desktop Environment (XFCE4, LXQt, MATE, KDE)
#  - Smart GPU acceleration detection (Turnip/Zink)
#  - Conflict-safe package installer (no more silent exits)
#  - SSH server pre-installed and configured
#  - Productivity & Media tools (VLC, Firefox)
#  - Google Antigravity IDE (via Ubuntu proot-distro bridge + desktop icon)
#  - Python 3 + pip
#  - Optional: Windows App Support (Wine/Hangover + Box64)
#  - One-line install (curl | bash) and unattended flags: see --help
#
#  Tested on: LineageOS (Android 9+), arm64 devices
#######################################################

# Intentionally avoiding set -e (exit on error) and set -u (nounset):
# - set -e silently kills the script on any failed package install
# - set -u crashes on variables that are legitimately empty in Termux
# pipefail is kept so piped commands still report failures.
set -o pipefail

# ============== DYNAMIC PATH DETECTION ==============
# Supports standard and custom Termux installs (e.g. secondary user profiles)
TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TERMUX_HOME="${HOME:-/data/data/com.termux/files/home}"

# ============== CONFIGURATION ==============
INSTALL_ANTIGRAVITY="yes"
ANTIGRAVITY_READY="no"
INSTALL_WINE="no"
DE_CHOICE="1"
GPU_STACK="stock"
DE_NAME="XFCE4"
CURRENT_STEP=0
REQUIRED_FAILURES=()
OPTIONAL_FAILURES=()
# TOTAL_STEPS is set after user choices are made

# Official Google Antigravity IDE Linux distribution endpoints.
ANTIGRAVITY_DOWNLOAD_PAGE="https://antigravity.google/download"
ANTIGRAVITY_FALLBACK_VERSION="2.8.0-6733682917113856"
ANTIGRAVITY_INSTALL_DIR="/opt/antigravity-ide"

# Set from command-line flags (see usage below).
DE_FROM_FLAG=""
ANTIGRAVITY_FROM_FLAG=""
WINE_FROM_FLAG=""
ASSUME_YES="no"

LOG_FILE="$TERMUX_HOME/termux-setup.log"

# Options for every apt call.
# - confold/confdef: never stop to ask about a changed config file.
# - Retries/Timeout: a stalled mirror fails and retries instead of hanging the
#   install forever with the spinner still going (issue #7).
# - Lock::Timeout: wait for another apt/dpkg (e.g. a second Termux session)
#   instead of failing at once.
APT_OPTS=(
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
    -o Acquire::Retries=3
    -o Acquire::http::Timeout=30
    -o Acquire::https::Timeout=30
    -o DPkg::Lock::Timeout=300
)
# Same options as a string for apt inside the Ubuntu proot container.
APT_OPTS_STR="${APT_OPTS[*]}"

# ============== COMMAND-LINE FLAGS ==============
usage() {
    cat << 'USAGE'
Usage: bash termux-linux-setup.sh [options]

Turn an Android phone into a Linux desktop with Termux + Termux-X11.
Run with no options for the interactive installer.

Options:
  --de <name>       Desktop to install: xfce (default), lxqt, mate, kde
  --antigravity     Install Google Antigravity IDE via Ubuntu proot (default)
  --no-antigravity  Skip Google Antigravity IDE
  --wine            Also install Windows app support (Hangover Wine + Box64)
  --no-wine         Skip Wine (default)
  -y, --yes         Don't ask anything; use the flags above or the defaults
  -h, --help        Show this help

One-line install:
  curl -fsSL https://raw.githubusercontent.com/VLADIMIRCOMMRAD/linux-android/main/termux-linux-setup.sh | bash

One-line, unattended, KDE without Wine:
  curl -fsSL https://raw.githubusercontent.com/VLADIMIRCOMMRAD/linux-android/main/termux-linux-setup.sh | bash -s -- --de kde --no-wine -y

Re-running is safe: installed packages are skipped and the launchers are
regenerated. Install log: ~/termux-setup.log
USAGE
}

# Map a desktop name or number to DE_CHOICE.
de_from_name() {
    case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
        1|xfce|xfce4)        echo 1 ;;
        2|lxqt)              echo 2 ;;
        3|mate)              echo 3 ;;
        4|kde|plasma|kde-plasma) echo 4 ;;
        *) return 1 ;;
    esac
}

parse_args() {
    local arg val
    while [ $# -gt 0 ]; do
        arg=$1
        case "$arg" in
            --de|--desktop)
                val=${2:-}
                [ $# -ge 2 ] && shift
                ;;
            --de=*|--desktop=*)
                val=${arg#*=}
                arg=--de
                ;;
        esac
        case "$arg" in
            --de|--desktop)
                if ! DE_FROM_FLAG=$(de_from_name "$val"); then
                    echo "Unknown desktop: '${val}'. Use xfce, lxqt, mate or kde." >&2
                    exit 2
                fi
                ;;
            --antigravity)    ANTIGRAVITY_FROM_FLAG="yes" ;;
            --no-antigravity) ANTIGRAVITY_FROM_FLAG="no" ;;
            --wine)           WINE_FROM_FLAG="yes" ;;
            --no-wine)        WINE_FROM_FLAG="no" ;;
            -y|--yes)         ASSUME_YES="yes" ;;
            -h|--help)        usage; exit 0 ;;
            *)
                echo "Unknown option: $arg" >&2
                usage >&2
                exit 2
                ;;
        esac
        shift
    done
}

# Where to read answers from. With `curl ... | bash` stdin is the script
# itself, so a plain `read` would swallow the rest of it; read from the
# terminal instead. No terminal at all (CI, nohup) means use the defaults.
TTY_IN=""
if [ -t 0 ]; then
    TTY_IN=/dev/stdin
elif { : < /dev/tty; } 2>/dev/null; then
    TTY_IN=/dev/tty
fi

# ask <var> <prompt> — read one answer, or leave it empty (= default) when
# running unattended.
ask() {
    local __reply=""
    if [ "$ASSUME_YES" != "yes" ] && [ -n "$TTY_IN" ]; then
        read -rp "$2" __reply < "$TTY_IN" || __reply=""
    fi
    printf -v "$1" '%s' "$__reply"
}

# ============== COLORS ==============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'
BOLD='\033[1m'

# ============== LOGGING ==============
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ============== PROGRESS BAR ==============
update_progress() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local PERCENT=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    local FILLED=$((PERCENT / 5))
    local EMPTY=$((20 - FILLED))

    local BAR="${GREEN}"
    for ((i=0; i<FILLED; i++)); do BAR+="█"; done
    BAR+="${GRAY}"
    for ((i=0; i<EMPTY; i++)); do BAR+="░"; done
    BAR+="${NC}"

    echo ""
    echo -e "${WHITE}────────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}  PROGRESS: ${WHITE}Step ${CURRENT_STEP}/${TOTAL_STEPS}${NC}  ${BAR}  ${WHITE}${PERCENT}%${NC}"
    echo -e "${WHITE}────────────────────────────────────────────────────────────${NC}"
    echo ""
}

# ============== SPINNER ==============
#
# Big packages (KDE, Firefox, Wine) can take many minutes on a slow phone or
# connection, and a bare spinner looks exactly like a hang (issue #7). So the
# spinner shows the elapsed time and, after a few seconds, the latest line apt
# wrote to the log ("Get:12 ... firefox [74.1 MB]", "Unpacking ...").
# If the log stops moving for several minutes it says so, once.

# Latest non-empty log line, stripped of control characters.
last_log_line() {
    tail -n 3 "$LOG_FILE" 2>/dev/null \
        | tr -d '\r' \
        | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        | grep -v '^[[:space:]]*$' \
        | tail -n 1
}

_spin() {
    local pid=$1
    local message=$2
    local optional=$3
    local spin=('⠋' '⠙' '⠸' '⠴' '⠦' '⠇')
    local i=0 tick=0
    local start=$SECONDS elapsed
    local cols detail="" line
    local size last_size=-1 last_change=$SECONDS warned=0

    cols=$(tput cols 2>/dev/null || echo 80)
    [ "$cols" -gt 20 ] 2>/dev/null || cols=80

    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$((SECONDS - start))

        # Once a second: refresh the detail line and check for a stall.
        if [ $((tick % 10)) -eq 0 ]; then
            size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
            if [ "$size" != "$last_size" ]; then
                last_size=$size
                last_change=$SECONDS
            fi
            if [ "$elapsed" -ge 4 ]; then
                detail=$(last_log_line)
            fi
            if [ "$warned" -eq 0 ] && [ $((SECONDS - last_change)) -ge 300 ]; then
                warned=1
                printf "\r\033[K  ${YELLOW}⚠${NC}  No progress for 5 minutes. Check your connection and keep\n"
                printf "     Termux in the foreground. If it never moves, press Ctrl+C and\n"
                printf "     re-run the script — installed packages are skipped.\n"
                log "STALL: no log output for 300s during: $message"
            fi
        fi

        line=$(printf "%s [%d:%02d]" "$message" $((elapsed / 60)) $((elapsed % 60)))
        if [ -n "$detail" ]; then
            line="$line · $detail"
        fi
        # Keep it on one line so \r can redraw it.
        line=${line:0:$((cols - 6))}
        printf "\r\033[K  ${CYAN}%s${NC}  %s" "${spin[$i]}" "$line"

        i=$(( (i + 1) % 6 ))
        tick=$((tick + 1))
        sleep 0.1
    done

    wait "$pid"
    local exit_code=$?
    elapsed=$((SECONDS - start))
    local took=""
    [ "$elapsed" -ge 10 ] && took=$(printf " (%d:%02d)" $((elapsed / 60)) $((elapsed % 60)))

    if [ "$exit_code" -eq 0 ]; then
        printf "\r\033[K  ${GREEN}✔${NC}  %-55s${GRAY}%s${NC}\n" "$message" "$took"
        log "OK: $message"
    elif [ "$optional" = "optional" ]; then
        printf "\r\033[K  ${YELLOW}⚠${NC}  %-55s ${YELLOW}(optional — skipped)${NC}\n" "$message"
        log "OPTIONAL FAILED: $message"
        return "$exit_code"
    else
        printf "\r\033[K  ${RED}✘${NC}  %-55s ${RED}(failed — see $LOG_FILE)${NC}\n" "$message"
        log "FAILED: $message"
    fi

    return "$exit_code"
}

spinner() { _spin "$1" "$2" ""; }

# Same as spinner, but a failure is reported as a warning rather than an error.
# For packages the desktop still works without.
spinner_optional() { _spin "$1" "$2" "optional"; }

# ============== DPKG / APT HELPERS ==============

# dpkg -s also succeeds for packages that were removed but left their config
# behind, so ask for the real status instead.
pkg_installed() {
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = "installed" ]
}

pkg_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

# apt-cache show prints one stanza per available version, highest first.
# We only care about the candidate, so cut at the first blank line.
apt_field() {
    apt-cache show "$1" 2>/dev/null \
        | sed -n '1,/^$/p' \
        | grep -i "^$2:" \
        | head -1 \
        | sed "s/^[^:]*:[[:space:]]*//"
}

# Strip version constraints and whitespace from a dependency list, one per line.
# "libmesa, ndk-sysroot (<< 23b-6), mesa" → "libmesa\nndk-sysroot\nmesa"
dep_names() {
    echo "$1" | tr ',' '\n' | sed 's/(.*//' | tr -d ' \t' | grep -v '^$'
}

# Is a single Conflicts entry actually violated right now?
#
# This is the bit the old version got wrong. Termux's mesa-zink declares
#   Conflicts: libmesa, ndk-sysroot (<< 23b-6), mesa
# Treating "ndk-sysroot (<< 23b-6)" as a plain name means any modern
# ndk-sysroot looks like a conflict and mesa-zink gets skipped, even though the
# constraint only covers versions older than 23b-6. (issue #4)
conflict_is_real() {
    local item="$1"
    local cname cop cver iver

    cname=$(echo "$item" | sed 's/(.*//' | tr -d ' \t')
    [ -z "$cname" ] && return 1
    pkg_installed "$cname" || return 1

    # No version constraint → any installed version conflicts.
    case "$item" in
        *"("*")"*) ;;
        *) return 0 ;;
    esac

    cop=$(echo "$item"  | sed -n 's/.*(\([<>=]\{1,2\}\)[[:space:]]*[^)]*).*/\1/p')
    cver=$(echo "$item" | sed -n 's/.*([<>=]\{1,2\}[[:space:]]*\([^)]*\)).*/\1/p')
    iver=$(pkg_version "$cname")
    if [ -z "$cop" ] || [ -z "$cver" ] || [ -z "$iver" ]; then
        return 0
    fi

    case "$cop" in
        "<<") cop="lt" ;;
        "<="|"<") cop="le" ;;
        "=")      cop="eq" ;;
        ">="|">") cop="ge" ;;
        ">>")     cop="gt" ;;
        *) return 0 ;;
    esac

    dpkg --compare-versions "$iver" "$cop" "$cver"
}

# Name of an installed package that already Provides "$1", if any.
provider_of() {
    dpkg-query -W -f='${db:Status-Status}|${Package}|${Provides}\n' 2>/dev/null \
        | awk -F'|' -v want="$1" '
            $1 == "installed" {
                n = split($3, a, ",")
                for (i = 1; i <= n; i++) {
                    p = a[i]; sub(/\(.*/, "", p); gsub(/[ \t]/, "", p)
                    if (p == want) { print $2; exit }
                }
            }'
}

# ============== CONFLICT-SAFE PACKAGE INSTALLER ==============
#
# Why this exists:
#   Termux has packages that hard-conflict with each other
#   (e.g. vulkan-loader-android vs vulkan-loader-generic).
#   Raw apt-get errors out on conflicts and — combined with set -e — would
#   silently kill the entire script.
#
# What this does:
#   1. Skips if the package is already installed, or already provided by
#      something installed (vulkan-loader-generic Provides vulkan-loader-android).
#   2. Reads the package's declared Conflicts and evaluates each one properly,
#      version constraints included.
#   3. Ignores a conflict the package also Replaces/Provides — that is a
#      supported swap (mesa → mesa-zink), not a breakage, and apt handles it.
#   4. Only then skips, with a warning, on a conflict that is genuinely unsafe.
#
# Usage: safe_install_pkg <pkg> [display name] [optional]
#   Passing "optional" as the third argument downgrades a failed install from a
#   red error to a yellow warning, for packages the desktop can live without.
#
record_package_failure() {
    if [ "${2:-}" = "optional" ]; then
        OPTIONAL_FAILURES+=("$1")
        return 0
    fi
    REQUIRED_FAILURES+=("$1")
    return 1
}

check_required_packages() {
    [ "${#REQUIRED_FAILURES[@]}" -eq 0 ] && return 0
    echo -e "${RED}Required packages failed: ${REQUIRED_FAILURES[*]}${NC}"
    echo "Setup is incomplete. Check $LOG_FILE, fix the package error, then re-run the installer."
    log "INCOMPLETE: required packages failed: ${REQUIRED_FAILURES[*]}"
    return 1
}

safe_install_pkg() {
    local pkg=$1
    local name=${2:-$pkg}
    local optional=${3:-}

    if pkg_installed "$pkg"; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already installed)${NC}\n" "$name"
        log "SKIP (already installed): $pkg"
        return 0
    fi

    # Already satisfied by a virtual provider?
    local provider
    provider=$(provider_of "$pkg")
    if [ -n "$provider" ]; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(provided by %s)${NC}\n" "$name" "$provider"
        log "SKIP (provided by $provider): $pkg"
        return 0
    fi

    if ! apt-cache show "$pkg" >/dev/null 2>&1; then
        printf "  ${YELLOW}⚠${NC}  %-55s ${YELLOW}(not in any enabled repo)${NC}\n" "$name"
        log "SKIP (unavailable): $pkg"
        record_package_failure "$pkg" "$optional"
        return $?
    fi

    # Conflicts the package can legitimately take over are not blockers.
    local swappable
    swappable=$(dep_names "$(apt_field "$pkg" Replaces)
$(apt_field "$pkg" Provides)")

    local item cname
    while IFS= read -r item; do
        [ -z "$(echo "$item" | tr -d ' \t')" ] && continue

        if conflict_is_real "$item"; then
            cname=$(echo "$item" | sed 's/(.*//' | tr -d ' \t')
            if echo "$swappable" | grep -qx "$cname"; then
                log "CONFLICT OK (${pkg} replaces ${cname}): apt will swap them"
            else
                printf "  ${YELLOW}⚠${NC}  %-55s ${YELLOW}(skipped — conflicts with: %s)${NC}\n" \
                    "$name" "$cname"
                log "SKIP (conflict with $cname): $pkg"
                record_package_failure "$pkg" "$optional"
                return $?
            fi
        fi
    done <<< "$(apt_field "$pkg" Conflicts | tr ',' '\n')"

    log "INSTALL: $pkg"
    (DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_OPTS[@]}" \
        "$pkg" < /dev/null >> "$LOG_FILE" 2>&1) &

    if [ "$optional" = "optional" ]; then
        spinner_optional $! "Installing ${name}..." && return 0
    else
        spinner $! "Installing ${name}..." && return 0
    fi
    record_package_failure "$pkg" "$optional"
}

# ============== BANNER ==============
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║                                                      ║
  ║          Termux Linux Desktop Setup Script           ║
  ║             Run full Linux on your Android           ║
  ║                                                      ║
  ╚══════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
    echo -e "${GRAY}  Detailed logs → $LOG_FILE${NC}"
    echo ""
}

# ============== ENVIRONMENT & USER SELECTION ==============
setup_environment() {
    log "=== Setup started ==="

    echo -e "${PURPLE}[*] Detecting your device...${NC}"
    echo ""

    # `getprop X || echo default` does not do what it looks like: `||` only runs
    # when the command *fails* (non-zero exit), but a getprop that succeeds and
    # prints nothing still yields an empty string. The defaults were therefore
    # never applied when the property was empty, and the banner printed
    # `Device :`, `Android: Android` and `CPU ABI:` with blank values.
    # Apply the default to the captured value instead.
    DEVICE_MODEL=$(getprop ro.product.model 2>/dev/null)
    DEVICE_MODEL=${DEVICE_MODEL:-Unknown}
    DEVICE_BRAND=$(getprop ro.product.brand 2>/dev/null)
    DEVICE_BRAND=${DEVICE_BRAND:-Unknown}
    ANDROID_VERSION=$(getprop ro.build.version.release 2>/dev/null)
    ANDROID_VERSION=${ANDROID_VERSION:-Unknown}
    CPU_ABI=$(getprop ro.product.cpu.abi 2>/dev/null)
    CPU_ABI=${CPU_ABI:-arm64-v8a}

    # Use actual EGL/hardware properties — NOT brand name.
    # Brand-based detection is wrong: Samsung ships both Adreno (Snapdragon)
    # and Mali (Exynos) phones, so checking "samsung" tells you nothing.
    GPU_RENDERER=$(getprop ro.hardware.egl 2>/dev/null || echo "")
    GPU_VENDOR_PROP=$(getprop ro.hardware 2>/dev/null || echo "")

    echo -e "  ${CYAN}Device :${NC}  ${WHITE}${DEVICE_BRAND} ${DEVICE_MODEL}${NC}"
    echo -e "  ${CYAN}Android:${NC}  ${WHITE}Android ${ANDROID_VERSION}${NC}"
    echo -e "  ${CYAN}CPU ABI:${NC}  ${WHITE}${CPU_ABI}${NC}"

    # Termux-X11, Turnip and Hangover are only built for 64-bit ARM. Warn
    # rather than abort: some 32-bit userlands on 64-bit chips still get far.
    case "$(uname -m)" in
        aarch64|arm64) ;;
        *)
            echo -e "  ${YELLOW}⚠  $(uname -m) detected. This script targets arm64 (aarch64);${NC}"
            echo -e "  ${YELLOW}   GPU acceleration and Wine will likely be unavailable.${NC}"
            log "WARNING: non-arm64 arch $(uname -m)"
            ;;
    esac

    local free_mb
    free_mb=$(df -m "$TERMUX_HOME" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$free_mb" ] && [ "$free_mb" -lt 4000 ] 2>/dev/null; then
        echo -e "  ${YELLOW}⚠  Only ${free_mb} MB free. A desktop needs 4–6 GB (more with Wine/KDE).${NC}"
        log "WARNING: low storage ${free_mb}MB"
    fi

    if [[ "$GPU_RENDERER" == *"adreno"* ]] || \
       [[ "$GPU_RENDERER" == *"Adreno"* ]] || \
       [[ "$GPU_VENDOR_PROP" == *"adreno"* ]] || \
       [[ "$GPU_VENDOR_PROP" == *"msm"* ]]   || \
       [[ "$GPU_VENDOR_PROP" == *"qcom"* ]]; then
        GPU_DRIVER="freedreno"
        echo -e "  ${CYAN}GPU    :${NC}  ${WHITE}Adreno / Qualcomm — Turnip hardware acceleration ✔${NC}"
    else
        GPU_DRIVER="zink_native"
        echo -e "  ${CYAN}GPU    :${NC}  ${YELLOW}Non-Adreno (Mali / PowerVR / other)${NC}"
        echo -e "             ${YELLOW}Falling back to Zink/Vulkan. Use XFCE4 or LXQt for best results.${NC}"
    fi
    echo ""

    # ---- Desktop Environment ----
    echo -e "${CYAN}Choose your Desktop Environment:${NC}"
    echo ""
    echo -e "  ${WHITE}1) XFCE4${NC}       — Fast, customizable, macOS-style dock. ${GREEN}(Recommended)${NC}"
    echo -e "  ${WHITE}2) LXQt${NC}        — Ultra-lightweight. Best for low-RAM phones."
    echo -e "  ${WHITE}3) MATE${NC}        — Classic look. Moderate resource use."
    echo -e "  ${WHITE}4) KDE Plasma${NC}  — Modern Windows-style UI. Requires 4 GB+ RAM."
    echo ""

    if [ -n "$DE_FROM_FLAG" ]; then
        DE_CHOICE="$DE_FROM_FLAG"
    else
        while true; do
            ask DE_INPUT "  Enter number (1-4) [default: 1]: "
            DE_INPUT=${DE_INPUT:-1}
            if [[ "$DE_INPUT" =~ ^[1-4]$ ]]; then
                DE_CHOICE="$DE_INPUT"; break
            else
                echo -e "  ${RED}Invalid — enter 1, 2, 3, or 4.${NC}"
            fi
        done
    fi

    case $DE_CHOICE in
        1) DE_NAME="XFCE4";;
        2) DE_NAME="LXQt";;
        3) DE_NAME="MATE";;
        4) DE_NAME="KDE Plasma";;
    esac
    echo -e "\n  ${GREEN}✔ Selected: ${BOLD}${DE_NAME}${NC}"

    # ---- Optional: Antigravity IDE ----
    echo ""
    echo -e "${CYAN}Optional: Install Google Antigravity IDE?${NC}"
    echo -e "  ${GRAY}Adds ~1.2 GB (Ubuntu proot glibc runtime + Antigravity IDE).${NC}"
    echo -e "  ${GRAY}Launches from your desktop alongside Firefox, VLC, and Terminal.${NC}"
    echo ""
    if [ -n "$ANTIGRAVITY_FROM_FLAG" ]; then
        INSTALL_ANTIGRAVITY="$ANTIGRAVITY_FROM_FLAG"
    else
        while true; do
            ask AGY_INPUT "  Install Antigravity IDE? (y/n) [default: y]: "
            AGY_INPUT=${AGY_INPUT:-y}
            case "$AGY_INPUT" in
                [Yy]*) INSTALL_ANTIGRAVITY="yes"; break;;
                [Nn]*) INSTALL_ANTIGRAVITY="no";  break;;
                *) echo -e "  ${RED}Please enter y or n.${NC}";;
            esac
        done
    fi
    if [ "$INSTALL_ANTIGRAVITY" == "yes" ]; then
        echo -e "  ${GREEN}✔ Antigravity IDE will be installed.${NC}"
    else
        echo -e "  ${GRAY}  Antigravity IDE skipped.${NC}"
    fi

    # ---- Optional: Wine ----
    echo ""
    echo -e "${CYAN}Optional: Install Windows app support (Wine + Box64/Hangover)?${NC}"
    echo -e "  ${GRAY}Adds ~500 MB. Runs some Windows x86 apps on ARM.${NC}"
    echo ""
    if [ -n "$WINE_FROM_FLAG" ]; then
        INSTALL_WINE="$WINE_FROM_FLAG"
    else
        while true; do
            ask WINE_INPUT "  Install Wine? (y/n) [default: n]: "
            WINE_INPUT=${WINE_INPUT:-n}
            case "$WINE_INPUT" in
                [Yy]*) INSTALL_WINE="yes"; break;;
                [Nn]*) INSTALL_WINE="no";  break;;
                *) echo -e "  ${RED}Please enter y or n.${NC}";;
            esac
        done
    fi
    if [ "$INSTALL_WINE" == "yes" ]; then
        echo -e "  ${GREEN}✔ Wine will be installed.${NC}"
    else
        echo -e "  ${GRAY}  Wine skipped.${NC}"
    fi

    TOTAL_STEPS=10
    [ "$INSTALL_ANTIGRAVITY" == "yes" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    [ "$INSTALL_WINE" == "yes" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))

    log "DE=$DE_NAME, GPU=$GPU_DRIVER, Antigravity=$INSTALL_ANTIGRAVITY, Wine=$INSTALL_WINE"
    sleep 1
}

# ============== STEP 1: UPDATE SYSTEM ==============
step_update() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Updating system packages...${NC}"
    echo ""

    (DEBIAN_FRONTEND=noninteractive apt-get update -y "${APT_OPTS[@]}" \
        < /dev/null >> "$LOG_FILE" 2>&1) &
    spinner $! "Updating package lists..." || return 1

    # Run pkg upgrade in FOREGROUND (not backgrounded via &) so we can catch
    # the libpcre/libandroid-selinux crash that kills binaries like 'sleep'
    # mid-session when core libraries are replaced. If it fails, we tell the
    # user exactly what to do rather than dying silently.
    echo -e "  ${CYAN}⠿${NC}  Upgrading packages (may take a few minutes)..."
    if ! DEBIAN_FRONTEND=noninteractive pkg upgrade -y "${APT_OPTS[@]}" \
            < /dev/null >> "$LOG_FILE" 2>&1; then
        echo ""
        echo -e "  ${YELLOW}⚠  Upgrade hit a library conflict — this is common on first run.${NC}"
        echo ""
        echo -e "  ${WHITE}To fix:${NC}"
        echo -e "    1. Close Termux completely (swipe away from recents)"
        echo -e "    2. Reopen Termux and run:  ${GREEN}pkg upgrade -y${NC}"
        echo -e "    3. Then re-run this script"
        echo ""
        echo -e "  ${GRAY}Full error: $LOG_FILE${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✔${NC}  Packages upgraded."
}

# ============== STEP 2: REPOSITORIES ==============
step_repos() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Adding package repositories...${NC}"
    echo ""
    safe_install_pkg "x11-repo" "X11 Repository"
    safe_install_pkg "tur-repo" "TUR Repository (Firefox, extra apps)" optional
    check_required_packages || return 1

    # MUST refresh after adding repos — otherwise packages from x11-repo
    # and tur-repo (termux-x11-nightly, firefox, etc.) won't be found.
    echo ""
    (DEBIAN_FRONTEND=noninteractive apt-get update -y "${APT_OPTS[@]}" \
        < /dev/null >> "$LOG_FILE" 2>&1) &
    spinner $! "Refreshing package lists (post-repo)..."
}

# ============== STEP 3: TERMUX-X11 ==============
step_x11() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Termux-X11 display server...${NC}"
    echo ""
    safe_install_pkg "termux-x11-nightly" "Termux-X11 Display Server"
    safe_install_pkg "xorg-xrandr"        "XRandR (Display Settings)" optional
}

# ============== STEP 4: DESKTOP ENVIRONMENT ==============
step_desktop() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing ${DE_NAME} Desktop...${NC}"
    echo ""

    # None of the Termux DE metapackages depend on dbus, but every one of them
    # needs a session bus to reach its settings daemon. Without it XFCE greets
    # you with "Unable to contact settings server". (issue #5)
    safe_install_pkg "dbus" "D-Bus (session message bus)"

    case $DE_CHOICE in
        1)
            safe_install_pkg "xfce4"                    "XFCE4 Desktop"
            safe_install_pkg "xfce4-terminal"           "XFCE4 Terminal"
            safe_install_pkg "xfce4-whiskermenu-plugin" "Whisker Menu Plugin" optional
            safe_install_pkg "plank-reloaded"           "Plank Dock" optional
            safe_install_pkg "thunar"                   "Thunar File Manager" optional
            safe_install_pkg "mousepad"                 "Mousepad Text Editor" optional
            ;;
        2)
            safe_install_pkg "lxqt"       "LXQt Desktop"
            # The LXQt metapackage includes obconf-qt, but no window manager.
            # Without one a fresh X11 session stops at an empty WM picker.
            safe_install_pkg "openbox"    "Openbox Window Manager"
            safe_install_pkg "qterminal"  "QTerminal"
            safe_install_pkg "pcmanfm-qt" "PCManFM-Qt File Manager" optional
            safe_install_pkg "featherpad" "FeatherPad Text Editor" optional
            ;;
        3)
            safe_install_pkg "mate"            "MATE Desktop"
            safe_install_pkg "mate-tweak"      "MATE Tweak" optional
            safe_install_pkg "plank-reloaded"  "Plank Dock" optional
            safe_install_pkg "mate-terminal"   "MATE Terminal"
            ;;
        4)
            safe_install_pkg "plasma-desktop" "KDE Plasma Desktop"
            safe_install_pkg "konsole"        "Konsole Terminal"
            safe_install_pkg "dolphin"        "Dolphin File Manager" optional
            ;;
    esac
}

# ============== STEP 5: GPU DRIVERS ==============
#
# Termux's own "mesa" package has shipped the Zink Gallium driver
# (lib/dri/zink_dri.so) since Mesa 23, so GALLIUM_DRIVER=zink works against the
# stock, current Mesa. The TUR "mesa-zink" package is Mesa 22.0.5 from 2022:
# installing it REMOVES mesa and drops you back four years, and its companion
# mesa-zink-vulkan-icd-freedreno ships the same libvulkan_freedreno.so as the
# main-repo Turnip driver, so dpkg aborts with a file-overwrite error if both
# land on the device. That was issue #4.
#
# So: prefer the stock stack, and only use the TUR one on installs whose Mesa
# genuinely has no Zink, or that already have mesa-zink from an earlier run.
step_gpu() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing GPU acceleration...${NC}"
    echo ""

    GPU_STACK="stock"

    if pkg_installed "mesa-zink"; then
        # Don't rip out a working legacy setup on re-run — the two stacks
        # overwrite each other's files.
        GPU_STACK="tur"
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(keeping TUR stack)${NC}\n" "Existing mesa-zink install detected"
        log "GPU stack: tur (mesa-zink already installed)"
    else
        safe_install_pkg "mesa" "Mesa (OpenGL + Zink)" || return 1
        if [ ! -f "${TERMUX_PREFIX}/lib/dri/zink_dri.so" ]; then
            GPU_STACK="tur"
            echo -e "  ${YELLOW}⚠${NC}  This Mesa build has no Zink — falling back to TUR mesa-zink."
            log "GPU stack: tur (no zink_dri.so in stock mesa)"
        else
            log "GPU stack: stock (zink_dri.so present)"
        fi
    fi

    # vulkan-loader-generic is the modern loader and is what every
    # mesa-vulkan-icd-* depends on. Do NOT ask for vulkan-loader-android:
    # vulkan-loader-generic both Provides AND Conflicts with it, so requesting
    # it on a normal install aborts the apt transaction for zero benefit.
    safe_install_pkg "vulkan-loader-generic" "Vulkan Loader" optional

    if [ "$GPU_STACK" == "tur" ]; then
        safe_install_pkg "mesa-zink" "Mesa Zink (OpenGL on Vulkan)"
        if [ "$GPU_DRIVER" == "freedreno" ]; then
            safe_install_pkg "mesa-zink-vulkan-icd-freedreno" "Freedreno Vulkan ICD (Turnip)" optional
        else
            safe_install_pkg "mesa-zink-vulkan-icd-swrast"    "SwRast Vulkan ICD (software)" optional
        fi
    else
        if [ "$GPU_DRIVER" == "freedreno" ]; then
            safe_install_pkg "mesa-vulkan-icd-freedreno" "Freedreno Vulkan ICD (Turnip)" optional
        else
            safe_install_pkg "mesa-vulkan-icd-swrast"    "SwRast Vulkan ICD (software)" optional
        fi
    fi

    # Verify here rather than letting a missing ICD show up as a black screen
    # ten minutes from now.
    echo ""
    if [ "$GPU_DRIVER" == "freedreno" ]; then
        if [ -f "${TERMUX_PREFIX}/share/vulkan/icd.d/freedreno_icd.aarch64.json" ]; then
            echo -e "  ${GREEN}✔${NC}  Turnip (Adreno) Vulkan driver in place."
        else
            echo -e "  ${YELLOW}⚠${NC}  Turnip ICD missing — stock Mesa will use software rendering."
            log "WARNING: freedreno ICD json not found"
        fi
    fi
    log "GPU stack final: $GPU_STACK"
}

# ============== STEP 6: AUDIO ==============
step_audio() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing audio server...${NC}"
    echo ""
    safe_install_pkg "pulseaudio" "PulseAudio" optional
}

# ============== STEP 7: APPS ==============
step_apps() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing applications...${NC}"
    echo ""
    safe_install_pkg "firefox"  "Firefox Browser" optional
    safe_install_pkg "vlc"      "VLC Media Player" optional
    safe_install_pkg "git"      "Git Version Control" optional
    safe_install_pkg "wget"     "Wget" optional
    safe_install_pkg "curl"     "cURL" optional
    safe_install_pkg "openssh"  "OpenSSH (SSH server + client)" optional
}

# ============== STEP 8: PYTHON ==============
step_python() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Python...${NC}"
    echo ""
    safe_install_pkg "python"     "Python 3" optional
    safe_install_pkg "python-pip" "pip (Python Package Manager)" optional
}

# ============== ANTIGRAVITY IDE HELPERS ==============

# Map host architecture to Google's Antigravity IDE Linux tarball platform.
antigravity_platform_arch() {
    local machine
    machine="${1:-$(uname -m)}"
    case "$machine" in
        aarch64|arm64) echo "linux-arm" ;;
        x86_64|amd64)  echo "linux-x64" ;;
        *) return 1 ;;
    esac
}

# Resolve the latest official Antigravity IDE tarball URL from the download
# page, falling back to the last verified stable release if offline or changed.
resolve_antigravity_tarball_url() {
    if [ -n "${ANTIGRAVITY_TARBALL_URL:-}" ]; then
        printf '%s\n' "$ANTIGRAVITY_TARBALL_URL"
        return 0
    fi

    local plat url=""
    plat=$(antigravity_platform_arch "${1:-}") || return 1

    if command -v curl >/dev/null 2>&1; then
        url=$(curl -fsSL --max-time 20 "$ANTIGRAVITY_DOWNLOAD_PAGE" 2>/dev/null \
            | grep -Eo "https://edgedl\.me\.gvt1\.com/edgedl/release2/j0qc3/antigravity/stable/[^\"'<>[:space:]]+/${plat}/Antigravity(%20| )IDE\.tar\.gz" \
            | head -n 1 \
            | sed 's/ /%20/g' || true)
    fi

    if [ -z "$url" ]; then
        url="https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/${ANTIGRAVITY_FALLBACK_VERSION}/${plat}/Antigravity%20IDE.tar.gz"
    fi

    printf '%s\n' "$url"
}

# ============== STEP 9 (OPTIONAL): ANTIGRAVITY IDE ==============
#
# Google Antigravity IDE is a glibc Electron/VS Code-based Linux desktop build
# (requires glibc >= 2.28 and GTK3/X11/NSS runtime libraries). Native Termux
# uses Android's Bionic libc, so we install Antigravity IDE inside a shared
# proot-distro Ubuntu container and display it seamlessly on native Termux-X11
# via --shared-tmp + ~/start-antigravity.sh. Reuses the same Ubuntu container
# as setup-homeassistant.sh without conflict.
step_antigravity() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Google Antigravity IDE...${NC}"
    echo ""

    local plat url
    if ! plat=$(antigravity_platform_arch); then
        echo -e "  ${YELLOW}⚠  Antigravity IDE requires 64-bit Linux (arm64/x86_64); skipping on $(uname -m).${NC}"
        log "OPTIONAL SKIP: antigravity-ide unsupported arch $(uname -m)"
        record_package_failure "antigravity-ide" optional
        return 0
    fi

    safe_install_pkg "proot-distro" "proot-distro (glibc runtime manager)" optional || return 0
    safe_install_pkg "proot"        "proot (user-space chroot)" optional || return 0

    if ! command -v proot-distro >/dev/null 2>&1; then
        echo -e "  ${YELLOW}⚠  proot-distro unavailable — skipping Antigravity IDE.${NC}"
        log "OPTIONAL FAILED: proot-distro command missing for antigravity-ide"
        record_package_failure "antigravity-ide" optional
        return 0
    fi

    if proot-distro login ubuntu -- true < /dev/null &>/dev/null; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already installed)${NC}\n" "Ubuntu glibc runtime container"
        log "SKIP (already installed): Ubuntu proot"
    else
        (proot-distro install ubuntu < /dev/null >> "$LOG_FILE" 2>&1) &
        if ! spinner_optional $! "Setting up Ubuntu glibc container..."; then
            record_package_failure "antigravity-ide" optional
            return 0
        fi
    fi

    (proot-distro login ubuntu -- bash -c \
        "DEBIAN_FRONTEND=noninteractive apt-get update -y ${APT_OPTS_STR}" \
        < /dev/null >> "$LOG_FILE" 2>&1) &
    if ! spinner_optional $! "Updating Ubuntu package lists..."; then
        record_package_failure "antigravity-ide" optional
        return 0
    fi

    # Install Electron/GTK3/X11/NSS/font runtime libraries in one apt call.
    # Handles Ubuntu 24.04+ 64-bit time_t (*t64) package renames automatically.
    (proot-distro login ubuntu -- bash -c '
        set -o pipefail
        apt_opts="$1"
        pkgs=(
            ca-certificates curl tar
            libnss3 libnspr4 libgbm1 libdrm2 libxshmfence1
            libx11-6 libx11-xcb1 libxcb1 libxcb-dri3-0
            libxcomposite1 libxdamage1 libxext6 libxfixes3
            libxkbcommon0 libxkbfile1 libxrandr2
            libcairo2 libpango-1.0-0 libglib2.0-0 libexpat1
            libdbus-1-3 libudev1 libsecret-1-0 libvulkan1
            dbus-x11 xdg-utils fonts-dejavu-core
        )
        for base in libasound2 libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 libcups2 libgtk-3-0; do
            if apt-cache show "${base}t64" >/dev/null 2>&1; then
                pkgs+=("${base}t64")
            else
                pkgs+=("$base")
            fi
        done
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $apt_opts "${pkgs[@]}"
    ' bash "$APT_OPTS_STR" < /dev/null >> "$LOG_FILE" 2>&1) &
    if ! spinner_optional $! "Installing Antigravity IDE runtime libraries (Ubuntu)..."; then
        record_package_failure "antigravity-ide" optional
        return 0
    fi

    if proot-distro login ubuntu -- test -x "${ANTIGRAVITY_INSTALL_DIR}/bin/antigravity-ide" < /dev/null &>/dev/null; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already installed)${NC}\n" "Google Antigravity IDE (${plat})"
        log "SKIP (already installed in Ubuntu): ${ANTIGRAVITY_INSTALL_DIR}"
    else
        url=$(resolve_antigravity_tarball_url)
        log "INSTALL: Antigravity IDE (${plat}) from ${url}"
        echo -e "  ${GRAY}Antigravity IDE is ~190 MB — download and extraction may take a few minutes.${NC}"
        (proot-distro login ubuntu -- bash -c '
            set -o pipefail
            url="$1"
            dest="$2"
            tmp_tar="/tmp/antigravity-ide.$$.tar.gz"
            stage="${dest}.new.$$"
            rm -rf "$stage" "$tmp_tar"
            mkdir -p "$(dirname "$dest")" "$stage"
            trap '\''rm -rf "$tmp_tar" "$stage"'\'' EXIT
            curl -fL --retry 3 --connect-timeout 30 -o "$tmp_tar" "$url"
            tar -xzf "$tmp_tar" --strip-components=1 -C "$stage"
            [ -x "$stage/bin/antigravity-ide" ] || exit 1
            rm -rf "$dest"
            mv "$stage" "$dest"
            mkdir -p /usr/local/bin
            ln -sf "$dest/bin/antigravity-ide" /usr/local/bin/antigravity-ide
        ' bash "$url" "$ANTIGRAVITY_INSTALL_DIR" < /dev/null >> "$LOG_FILE" 2>&1) &
        if ! spinner_optional $! "Downloading & installing Antigravity IDE (${plat})..."; then
            record_package_failure "antigravity-ide" optional
            return 0
        fi
    fi

    # Install an OAuth/URL bridge inside Ubuntu so sign-in links can open in
    # Android/Termux Firefox and are always logged for manual copy-paste.
    proot-distro login ubuntu -- bash -c \
        'mkdir -p /usr/local/bin && cat > /usr/local/bin/antigravity-open-url && chmod +x /usr/local/bin/antigravity-open-url' \
        << 'OPENURLEOF' >> "$LOG_FILE" 2>&1 || true
#!/bin/sh
url="$1"
[ -n "$url" ] || exit 0
if [ -n "${TERMUX_HOME:-}" ]; then
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$url" >> "${TERMUX_HOME}/antigravity-oauth-url.log" 2>/dev/null || true
fi
if [ -n "${TERMUX_PREFIX:-}" ] && [ -x "${TERMUX_PREFIX}/bin/termux-open-url" ]; then
    env -u LD_LIBRARY_PATH -u LD_PRELOAD "${TERMUX_PREFIX}/bin/termux-open-url" "$url" >/dev/null 2>&1 && exit 0
fi
if [ -n "${TERMUX_PREFIX:-}" ] && [ -x "${TERMUX_PREFIX}/bin/firefox" ]; then
    env -u LD_LIBRARY_PATH -u LD_PRELOAD "${TERMUX_PREFIX}/bin/firefox" "$url" >/dev/null 2>&1 &
    exit 0
fi
printf 'Open this URL in your browser: %s\n' "$url" >&2
OPENURLEOF

    # Copy the official IDE icon out to Termux for the native desktop shortcut.
    mkdir -p "$TERMUX_HOME/.local/share/icons"
    if proot-distro login ubuntu -- test -r "${ANTIGRAVITY_INSTALL_DIR}/resources/app/resources/linux/code.png" < /dev/null 2>/dev/null; then
        proot-distro login ubuntu -- cat "${ANTIGRAVITY_INSTALL_DIR}/resources/app/resources/linux/code.png" \
            < /dev/null > "$TERMUX_HOME/.local/share/icons/antigravity-ide.png" 2>/dev/null || true
    fi

    ANTIGRAVITY_READY="yes"
    echo -e "  ${GREEN}✔${NC}  Antigravity IDE ready (${ANTIGRAVITY_INSTALL_DIR} in Ubuntu proot)."
    log "OK: Antigravity IDE ready"
}

# ============== STEP 10 (OPTIONAL): WINE ==============
step_wine() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Windows support (Wine + Box64)...${NC}"
    echo ""

    # Only touch apt when there is actually something to remove. The old
    # unconditional `pkg remove` went through the pkg wrapper (mirror checks,
    # possible prompts) for nothing on almost every install.
    if pkg_installed "wine-stable"; then
        (DEBIAN_FRONTEND=noninteractive apt-get remove -y "${APT_OPTS[@]}" \
            wine-stable < /dev/null >> "$LOG_FILE" 2>&1) &
        spinner_optional $! "Removing old wine-stable..."
    fi

    echo -e "  ${GRAY}Wine is a large download (~500 MB) — this step can take a while.${NC}"

    safe_install_pkg "hangover-wine"     "Hangover Wine" optional
    safe_install_pkg "hangover-wowbox64" "Box64 Wrapper" optional

    local WINE_BIN="${TERMUX_PREFIX}/opt/hangover-wine/bin"
    if [ -f "${WINE_BIN}/wine" ]; then
        ln -sf "${WINE_BIN}/wine"    "${TERMUX_PREFIX}/bin/wine"
        ln -sf "${WINE_BIN}/winecfg" "${TERMUX_PREFIX}/bin/winecfg"
        echo -e "  ${GREEN}✔ Wine binaries linked to PATH.${NC}"
        log "Wine symlinks created."
    else
        echo -e "  ${YELLOW}  Wine binary not found at expected path — symlinks skipped.${NC}"
        log "WARNING: Wine binary not found at $WINE_BIN"
        INSTALL_WINE="no"
    fi
}

# LXQt needs an X11 window manager selected before it can start its panel and
# desktop. Keep an existing custom selection and all unrelated session settings.
configure_lxqt_window_manager() {
    local config_dir="${XDG_CONFIG_HOME:-$TERMUX_HOME/.config}/lxqt"
    local config_file="$config_dir/session.conf"
    local config_tmp

    mkdir -p "$config_dir" || return 1
    if [ ! -e "$config_file" ]; then
        printf '[General]\nwindow_manager=openbox\n' > "$config_file" || return 1
    else
        if awk '
            /^[[:space:]]*\[/ { general = ($0 ~ /^[[:space:]]*\[General\][[:space:]]*$/) }
            general && /^[[:space:]]*window_manager[[:space:]]*=/ {
                value = $0
                sub(/^[^=]*=[[:space:]]*/, "", value)
                sub(/[[:space:]]*$/, "", value)
                if (value != "" && value != "\"\"") configured = 1
            }
            END { exit !configured }
        ' "$config_file"; then
            log "LXQt: keeping the configured window manager"
            return 0
        fi

        config_tmp=$(mktemp "$config_dir/.session.conf.XXXXXX") || return 1
        if ! awk '
            /^[[:space:]]*\[/ {
                general = ($0 ~ /^[[:space:]]*\[General\][[:space:]]*$/)
                if (general) {
                    print
                    print "window_manager=openbox"
                    added = 1
                    next
                }
            }
            general && /^[[:space:]]*window_manager[[:space:]]*=/ { next }
            { print }
            END {
                if (!added) print "\n[General]\nwindow_manager=openbox"
            }
        ' "$config_file" > "$config_tmp"; then
            rm -f "$config_tmp"
            return 1
        fi
        mv "$config_tmp" "$config_file" || return 1
    fi
    log "LXQt: selected Openbox as the default X11 window manager"
}

# Android manages the phone's power state. The optional LXQt power daemon can
# repeatedly crash on some Termux devices, so leave it disabled by default.
# A user-owned override is an explicit choice and must survive a setup rerun.
configure_lxqt_power_management() {
    local autostart_dir="${XDG_CONFIG_HOME:-$TERMUX_HOME/.config}/autostart"
    local power_entry="$autostart_dir/lxqt-powermanagement.desktop"

    if [ -e "$power_entry" ] || [ -L "$power_entry" ]; then
        log "LXQt: keeping the existing Power Management autostart override"
        return 0
    fi
    mkdir -p "$autostart_dir" || return 1
    cat > "$power_entry" << 'POWEREND' || return 1
[Desktop Entry]
Type=Application
Version=1.0
Name=Power Management
TryExec=lxqt-powermanagement
Exec=lxqt-powermanagement
OnlyShowIn=LXQt;
X-LXQt-Need-Tray=true
X-LXQt-Module=true
X-LXQt-Autostart-disabled=true
POWEREND
    log "LXQt: disabled optional Power Management autostart for Android"
}

# ============== STEP 11: LAUNCHER SCRIPTS ==============
step_launchers() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Creating startup scripts...${NC}"
    echo ""

    mkdir -p ~/.config

    if [ "$DE_CHOICE" = "2" ]; then
        configure_lxqt_window_manager || return 1
        configure_lxqt_power_management || return 1
    fi

    XDG_INJECT="export XDG_DATA_DIRS=${TERMUX_PREFIX}/share:\${XDG_DATA_DIRS:-}\nexport XDG_CONFIG_DIRS=${TERMUX_PREFIX}/etc/xdg:\${XDG_CONFIG_DIRS:-}\nexport XDG_RUNTIME_DIR=\${TMPDIR:-${TERMUX_PREFIX}/tmp}"

    if [ "$DE_CHOICE" == "4" ]; then
        mkdir -p ~/.config/plasma-workspace/env
        {
            echo "#!${TERMUX_PREFIX}/bin/bash"
            echo -e "$XDG_INJECT"
        } > ~/.config/plasma-workspace/env/xdg_fix.sh
        chmod +x ~/.config/plasma-workspace/env/xdg_fix.sh
    fi

    cat > ~/.config/linux-gpu.sh << EOF
#!${TERMUX_PREFIX}/bin/bash
# GPU & Mesa environment — sourced by start-linux.sh
export MESA_NO_ERROR=1
export MESA_GL_VERSION_OVERRIDE=4.6
export MESA_GLES_VERSION_OVERRIDE=3.2
export GALLIUM_DRIVER=zink
export MESA_LOADER_DRIVER_OVERRIDE=zink
export TU_DEBUG=noconform
export MESA_VK_WSI_PRESENT_MODE=immediate
export ZINK_DESCRIPTORS=lazy
EOF

    if [ "$DE_CHOICE" == "4" ]; then
        echo "export KWIN_COMPOSE=O2ES" >> ~/.config/linux-gpu.sh
    else
        echo -e "$XDG_INJECT" >> ~/.config/linux-gpu.sh
    fi

    if [ "$GPU_DRIVER" == "freedreno" ]; then
        {
            printf 'if [ -r %q ]; then\n' "${TERMUX_PREFIX}/share/vulkan/icd.d/freedreno_icd.aarch64.json"
            printf '    export VK_ICD_FILENAMES=%q\n' "${TERMUX_PREFIX}/share/vulkan/icd.d/freedreno_icd.aarch64.json"
            echo 'else'
            echo '    unset VK_ICD_FILENAMES'
            if [ "$GPU_STACK" = "stock" ]; then
                # Stock Mesa includes llvmpipe. A nonexistent forced ICD
                # prevents Vulkan from considering any fallback at all.
                echo '    unset MESA_LOADER_DRIVER_OVERRIDE'
                echo '    export GALLIUM_DRIVER=llvmpipe LIBGL_ALWAYS_SOFTWARE=1'
                echo '    echo "[!] Turnip ICD missing; using Mesa software rendering."'
            else
                echo '    echo "[!] Turnip ICD missing; install a matching TUR Vulkan driver or switch to stock Mesa."'
            fi
            echo 'fi'
        } >> ~/.config/linux-gpu.sh
    fi

    if [ "$DE_CHOICE" == "1" ] || [ "$DE_CHOICE" == "3" ]; then
        mkdir -p ~/.config/autostart
        cat > ~/.config/autostart/plank.desktop << 'PLANKEOF'
[Desktop Entry]
Type=Application
Name=Plank
Exec=plank
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
PLANKEOF
    else
        rm -f ~/.config/autostart/plank.desktop 2>/dev/null || true
    fi

    case $DE_CHOICE in
        1)
            DESKTOP_COMMAND="startxfce4"
            KILL_CMD="pkill -9 xfce4-session 2>/dev/null; pkill -9 plank 2>/dev/null"
            ;;
        2)
            DESKTOP_COMMAND="startlxqt"
            KILL_CMD="pkill -9 lxqt-session 2>/dev/null"
            ;;
        3)
            DESKTOP_COMMAND="mate-session"
            KILL_CMD="pkill -9 mate-session 2>/dev/null; pkill -9 plank 2>/dev/null"
            ;;
        4)
            DESKTOP_COMMAND="startplasma-x11"
            KILL_CMD="pkill -9 startplasma-x11 2>/dev/null; pkill -9 plasmashell 2>/dev/null; pkill -9 kwin_x11 2>/dev/null"
            ;;
    esac

    # Only these known values are expanded while writing the launcher. Keep
    # the body literal: backticks in its comments used to execute PulseAudio
    # and Termux-X11 here, hanging setup at the launcher step (issue #10).
    {
        printf '#!%s/bin/bash\n' "$TERMUX_PREFIX"
        printf 'TERMUX_PREFIX=%q\nDE_NAME=%q\nDESKTOP_COMMAND=%q\n' \
            "$TERMUX_PREFIX" "$DE_NAME" "$DESKTOP_COMMAND"
        printf 'stop_desktop_session() {\n    %s\n}\n' "$KILL_CMD"
        cat << 'LAUNCHEREOF'
echo ""
echo "[*] Starting ${DE_NAME} on Termux-X11..."
echo ""

for required_command in termux-x11 dbus-daemon "$DESKTOP_COMMAND"; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "[!] Missing command: $required_command. Re-run termux-linux-setup.sh and check ~/termux-setup.log."
        exit 1
    fi
done

source ~/.config/linux-gpu.sh 2>/dev/null

echo "[*] Cleaning up old sessions..."
pkill -9 -f "termux.x11" 2>/dev/null || true
stop_desktop_session || true
pkill -9 -f "dbus-daemon" 2>/dev/null || true
sleep 0.5

# ---- D-Bus session bus ----
# XFCE, MATE and KDE all reach their settings daemon over the session bus.
# If no bus is running -- or if a previous run was SIGKILLed and left a dead
# socket plus a stale address in ~/.dbus behind -- the desktop comes up with
# "Unable to contact settings server" and
# "Failed to connect to socket .../dbus-XXXX: Connection refused".
# Clearing the stale state and starting the bus at a fixed, predictable
# address fixes both. (issue #5)
echo "[*] Starting D-Bus session bus..."
export XDG_RUNTIME_DIR="${TMPDIR:-${TERMUX_PREFIX}/tmp}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

DBUS_DIR="${TERMUX_PREFIX}/var/run/dbus"
rm -rf "$HOME/.dbus" 2>/dev/null || true
rm -f "${XDG_RUNTIME_DIR}/dbus-"* 2>/dev/null || true
mkdir -p "$DBUS_DIR" "${TERMUX_PREFIX}/var/lib/dbus"
rm -f "$DBUS_DIR/session_bus_socket"
dbus-uuidgen --ensure >/dev/null 2>&1 || true

export DBUS_SESSION_BUS_ADDRESS="unix:path=$DBUS_DIR/session_bus_socket"
if ! dbus-daemon --session --address="$DBUS_SESSION_BUS_ADDRESS" --nopidfile --fork; then
    echo "[!] D-Bus could not start. Check the error above before launching the desktop."
    exit 1
fi

echo "[*] Starting PulseAudio..."
unset PULSE_SERVER
# All calls are time-bounded on purpose. `pulseaudio --start` and `pactl` can
# block indefinitely when the audio HAL is wedged, and the "|| true" below only
# rescues a command that *fails* -- not one that never returns. Unbounded, a
# stuck PulseAudio stalls the launcher here and `termux-x11` is never started,
# so the desktop silently never appears (Termux-X11 just says "Not connected")
# with no error to act on. Audio is optional; it must never hold up the display.
if command -v timeout >/dev/null 2>&1; then
    timeout -k 2 5 pulseaudio --kill 2>/dev/null || true
    sleep 0.3
    timeout -k 2 10 pulseaudio --start --exit-idle-time=-1 \
        || echo "[!] PulseAudio did not start - continuing without audio."
    sleep 1
    timeout -k 2 5 pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 2>/dev/null || true
else
    echo "[!] timeout is unavailable; skipping audio so it cannot block the desktop. Run: pkg install coreutils"
fi
export PULSE_SERVER=127.0.0.1

echo "[*] Starting Termux-X11 display server..."
termux-x11 :0 -ac &
sleep 3
export DISPLAY=:0

# Daemons the bus starts on demand (xfconfd, xfsettingsd, ...) inherit the
# bus's environment, not this shell's -- so push DISPLAY across explicitly.
dbus-update-activation-environment DISPLAY XAUTHORITY PULSE_SERVER XDG_DATA_DIRS XDG_CONFIG_DIRS XDG_RUNTIME_DIR >/dev/null 2>&1 || true

echo ""
echo "─────────────────────────────────────────────────"
echo "  ✔ Desktop launching! Open the Termux-X11 app."
echo "─────────────────────────────────────────────────"
echo ""

exec "$DESKTOP_COMMAND"
LAUNCHEREOF
    } > ~/start-linux.sh
    chmod +x ~/start-linux.sh
    echo -e "  ${GREEN}✔ Created ~/start-linux.sh${NC}"

    {
        printf '#!%s/bin/bash\n' "$TERMUX_PREFIX"
        printf 'TERMUX_PREFIX=%q\nDE_NAME=%q\n' "$TERMUX_PREFIX" "$DE_NAME"
        printf 'stop_desktop_session() {\n    %s\n}\n' "$KILL_CMD"
        cat << 'STOPEOF'
echo "[*] Stopping ${DE_NAME}..."
pkill -f "antigravity-ide" 2>/dev/null || true
pkill -9 -f "termux.x11" 2>/dev/null || true
pkill -9 -f "pulseaudio"  2>/dev/null || true
stop_desktop_session || true
pkill -9 -f "dbus-daemon" 2>/dev/null || true
# Leave no dead socket for the next start to trip over.
rm -f "${TERMUX_PREFIX}/var/run/dbus/session_bus_socket" 2>/dev/null || true
rm -rf "$HOME/.dbus" 2>/dev/null || true
echo "[✔] Desktop stopped."
STOPEOF
    } > ~/stop-linux.sh
    chmod +x ~/stop-linux.sh
    echo -e "  ${GREEN}✔ Created ~/stop-linux.sh${NC}"

    if [ "$INSTALL_ANTIGRAVITY" == "yes" ]; then
        {
            printf '#!%s/bin/bash\n' "$TERMUX_PREFIX"
            printf 'TERMUX_PREFIX=%q\nTERMUX_HOME=%q\nANTIGRAVITY_INSTALL_DIR=%q\n' \
                "$TERMUX_PREFIX" "$TERMUX_HOME" "$ANTIGRAVITY_INSTALL_DIR"
            cat << 'AGYSTARTEOF'
if ! command -v proot-distro >/dev/null 2>&1; then
    echo "[!] proot-distro is missing. Re-run termux-linux-setup.sh --antigravity." >&2
    exit 1
fi

if ! proot-distro login ubuntu -- test -x "${ANTIGRAVITY_INSTALL_DIR}/bin/antigravity-ide" < /dev/null 2>/dev/null; then
    echo "[!] Antigravity IDE is not installed in Ubuntu proot yet." >&2
    echo "    Run: bash ~/upgrade-antigravity.sh  (or re-run termux-linux-setup.sh --antigravity)" >&2
    exit 1
fi

export DISPLAY="${DISPLAY:-:0}"
export PULSE_SERVER="${PULSE_SERVER:-127.0.0.1}"
export TMPDIR="${TMPDIR:-${TERMUX_PREFIX}/tmp}"

mkdir -p "${TERMUX_HOME}/.config/Antigravity" "${TERMUX_HOME}/.local/share/antigravity-extensions"

# PRoot runs as uid=0 without Chromium user namespaces or full /dev/shm:
# - --user-data-dir is required by bin/antigravity-ide when running as root
# - --no-sandbox / --disable-dev-shm-usage prevent Chromium startup crashes
# - --password-store=basic avoids blocking on desktop keyring daemons
# - --disable-gpu avoids blank Electron windows inside proot (override with ANTIGRAVITY_GPU=1)
AGY_FLAGS=(
    --no-sandbox
    --disable-gpu-sandbox
    --disable-dev-shm-usage
    --password-store=basic
    "--user-data-dir=${TERMUX_HOME}/.config/Antigravity"
    "--extensions-dir=${TERMUX_HOME}/.local/share/antigravity-extensions"
)
if [ "${ANTIGRAVITY_GPU:-0}" != "1" ]; then
    AGY_FLAGS+=(--disable-gpu)
fi

exec proot-distro login ubuntu \
    --shared-tmp \
    --bind "${TERMUX_HOME}:${TERMUX_HOME}" \
    -- env \
        DISPLAY="$DISPLAY" \
        PULSE_SERVER="$PULSE_SERVER" \
        BROWSER=/usr/local/bin/antigravity-open-url \
        TERMUX_HOME="$TERMUX_HOME" \
        TERMUX_PREFIX="$TERMUX_PREFIX" \
        "${ANTIGRAVITY_INSTALL_DIR}/bin/antigravity-ide" \
        "${AGY_FLAGS[@]}" \
        "$@"
AGYSTARTEOF
        } > "$TERMUX_HOME/start-antigravity.sh"
        chmod +x "$TERMUX_HOME/start-antigravity.sh"
        mkdir -p "$TERMUX_PREFIX/bin"
        ln -sf "$TERMUX_HOME/start-antigravity.sh" "$TERMUX_PREFIX/bin/antigravity-ide"
        echo -e "  ${GREEN}✔ Created ~/start-antigravity.sh (command: antigravity-ide)${NC}"

        {
            printf '#!%s/bin/bash\n' "$TERMUX_PREFIX"
            printf 'set -o pipefail\n'
            printf 'TERMUX_PREFIX=%q\nTERMUX_HOME=%q\nANTIGRAVITY_INSTALL_DIR=%q\nANTIGRAVITY_DOWNLOAD_PAGE=%q\nANTIGRAVITY_FALLBACK_VERSION=%q\n' \
                "$TERMUX_PREFIX" "$TERMUX_HOME" "$ANTIGRAVITY_INSTALL_DIR" "$ANTIGRAVITY_DOWNLOAD_PAGE" "$ANTIGRAVITY_FALLBACK_VERSION"
            declare -f antigravity_platform_arch
            declare -f resolve_antigravity_tarball_url
            cat << 'AGYUPGRADEEOF'

echo ""
echo "[*] Upgrading Google Antigravity IDE..."
echo ""

if ! command -v proot-distro >/dev/null 2>&1; then
    echo "[!] proot-distro is missing. Re-run termux-linux-setup.sh --antigravity." >&2
    exit 1
fi

if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock
    trap 'termux-wake-unlock 2>/dev/null || true' EXIT
fi

pkill -f "antigravity-ide" 2>/dev/null || true
sleep 1

URL=$(resolve_antigravity_tarball_url) || {
    echo "[!] Unsupported architecture: $(uname -m)" >&2
    exit 1
}
echo "[*] Package URL: $URL"

if ! proot-distro login ubuntu -- bash -c '
    set -o pipefail
    url="$1"
    dest="$2"
    tmp_tar="/tmp/antigravity-ide.$$.tar.gz"
    stage="${dest}.new.$$"
    rm -rf "$stage" "$tmp_tar"
    mkdir -p "$(dirname "$dest")" "$stage"
    trap '\''rm -rf "$tmp_tar" "$stage"'\'' EXIT
    curl -fL --retry 3 --connect-timeout 30 -o "$tmp_tar" "$url"
    tar -xzf "$tmp_tar" --strip-components=1 -C "$stage"
    [ -x "$stage/bin/antigravity-ide" ] || exit 1
    rm -rf "$dest"
    mv "$stage" "$dest"
    mkdir -p /usr/local/bin
    ln -sf "$dest/bin/antigravity-ide" /usr/local/bin/antigravity-ide
' bash "$URL" "$ANTIGRAVITY_INSTALL_DIR" < /dev/null; then
    echo "[!] Antigravity IDE upgrade failed." >&2
    exit 1
fi

mkdir -p "$TERMUX_HOME/.local/share/icons"
if proot-distro login ubuntu -- test -r "${ANTIGRAVITY_INSTALL_DIR}/resources/app/resources/linux/code.png" < /dev/null 2>/dev/null; then
    proot-distro login ubuntu -- cat "${ANTIGRAVITY_INSTALL_DIR}/resources/app/resources/linux/code.png" \
        < /dev/null > "$TERMUX_HOME/.local/share/icons/antigravity-ide.png" 2>/dev/null || true
fi

echo "[✔] Antigravity IDE updated. Launch with: antigravity-ide (or desktop icon)"
AGYUPGRADEEOF
        } > "$TERMUX_HOME/upgrade-antigravity.sh"
        chmod +x "$TERMUX_HOME/upgrade-antigravity.sh"
        echo -e "  ${GREEN}✔ Created ~/upgrade-antigravity.sh${NC}"
    fi
}

# ============== STEP 12: DESKTOP SHORTCUTS ==============
step_shortcuts() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Creating desktop shortcuts...${NC}"
    echo ""

    mkdir -p ~/Desktop

    cat > ~/Desktop/Firefox.desktop << 'EOF'
[Desktop Entry]
Name=Firefox
Exec=firefox
Icon=firefox
Type=Application
Categories=Network;WebBrowser;
EOF

    cat > ~/Desktop/VLC.desktop << 'EOF'
[Desktop Entry]
Name=VLC Media Player
Exec=vlc
Icon=vlc
Type=Application
Categories=Video;AudioVideo;Player;
EOF

    local term_cmd term_icon
    case $DE_CHOICE in
        1) term_cmd="xfce4-terminal"; term_icon="xfce4-terminal";;
        2) term_cmd="qterminal";      term_icon="qterminal";;
        3) term_cmd="mate-terminal";  term_icon="mate-terminal";;
        4) term_cmd="konsole";        term_icon="utilities-terminal";;
    esac

    cat > ~/Desktop/Terminal.desktop << EOF
[Desktop Entry]
Name=Terminal
Exec=${term_cmd}
Icon=${term_icon}
Type=Application
Categories=System;TerminalEmulator;
EOF

    if [ "$INSTALL_ANTIGRAVITY" == "yes" ]; then
        local agy_icon="applications-development"
        if [ -f "$TERMUX_HOME/.local/share/icons/antigravity-ide.png" ]; then
            agy_icon="$TERMUX_HOME/.local/share/icons/antigravity-ide.png"
        fi
        mkdir -p "$TERMUX_HOME/.local/share/applications"
        cat > ~/Desktop/Antigravity_IDE.desktop << EOF
[Desktop Entry]
Name=Antigravity IDE
Comment=Google Antigravity AI-first IDE
Exec="${TERMUX_HOME}/start-antigravity.sh" %F
Icon=${agy_icon}
Type=Application
Categories=Development;IDE;
StartupNotify=true
StartupWMClass=Antigravity IDE
EOF
        cp ~/Desktop/Antigravity_IDE.desktop "$TERMUX_HOME/.local/share/applications/antigravity-ide.desktop"
    fi

    if [ "$INSTALL_WINE" == "yes" ]; then
        cat > ~/Desktop/Wine_Config.desktop << 'EOF'
[Desktop Entry]
Name=Wine Config
Exec=wine winecfg
Icon=wine
Type=Application
Categories=Utility;
EOF
    fi

    chmod +x ~/Desktop/*.desktop 2>/dev/null || true
    echo -e "  ${GREEN}✔ Desktop shortcuts created.${NC}"
}

# ============== COMPLETION ==============
show_completion() {
    echo ""
    echo -e "${GREEN}"
    cat << 'COMPLETE'
  ╔══════════════════════════════════════════════════════╗
  ║                                                      ║
  ║              ✔  INSTALLATION COMPLETE!               ║
  ║                                                      ║
  ╚══════════════════════════════════════════════════════╝
COMPLETE
    echo -e "${NC}"
    local agy_status="no"
    if [ "$INSTALL_ANTIGRAVITY" == "yes" ]; then
        if [ "$ANTIGRAVITY_READY" == "yes" ]; then
            agy_status="yes"
        else
            agy_status="incomplete (optional — see log)"
        fi
    fi

    echo -e "  ${WHITE}Desktop     : ${GREEN}${DE_NAME}${NC}"
    echo -e "  ${WHITE}GPU         : ${GREEN}${GPU_DRIVER}${NC}"
    echo -e "  ${WHITE}Antigravity : ${GREEN}${agy_status}${NC}"
    echo -e "  ${WHITE}Wine        : ${GREEN}${INSTALL_WINE}${NC}"
    if [ "${#OPTIONAL_FAILURES[@]}" -gt 0 ]; then
        echo -e "  ${YELLOW}Optional packages unavailable: ${OPTIONAL_FAILURES[*]}${NC}"
        echo "  Those features are not installed; see the log and re-run to retry."
    fi
    echo ""
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}▶  START DESKTOP:${NC}  ${GREEN}bash ~/start-linux.sh${NC}"
    echo -e "  ${WHITE}■  STOP DESKTOP: ${NC}  ${GREEN}bash ~/stop-linux.sh${NC}"
    if [ "$INSTALL_ANTIGRAVITY" == "yes" ]; then
        echo -e "  ${WHITE}★  ANTIGRAVITY:  ${NC}  ${GREEN}antigravity-ide${NC} ${GRAY}(or Desktop icon; upgrade: bash ~/upgrade-antigravity.sh)${NC}"
    fi
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${CYAN}SSH into this device from another machine:${NC}"
    echo -e "    1. Start SSH server:  ${GREEN}sshd${NC}"
    echo -e "    2. Set a password:    ${GREEN}passwd${NC}"
    echo -e "    3. Find your IP:      ${GREEN}ip addr show wlan0 | grep 'inet '${NC}"
    echo -e "    4. Connect from PC:   ${GREEN}ssh \$(whoami)@<your-ip> -p 8022${NC}"
    echo ""
    echo -e "  ${GRAY}Full install log: $LOG_FILE${NC}"
    echo ""
}

# ============== MAIN ==============
main() {
    : > "$LOG_FILE"
    log "termux-linux-setup.sh started (args: $*)"

    # This script is for Termux. Bail out early and clearly anywhere else,
    # instead of failing ten steps in.
    if [ ! -d "$TERMUX_PREFIX" ] || ! command -v pkg >/dev/null 2>&1; then
        echo -e "${RED}This script must be run inside Termux on Android.${NC}"
        echo -e "Get Termux from F-Droid: https://f-droid.org/en/packages/com.termux/"
        exit 1
    fi

    # Prevent Android from suspending Termux mid-install when screen turns off.
    # A suspended Termux kills background apt processes, causing random failures.
    if command -v termux-wake-lock &>/dev/null; then
        termux-wake-lock
        log "Wake lock acquired."
        # Release it however we exit: success, an early `exit 1`, or Ctrl+C.
        trap 'termux-wake-unlock 2>/dev/null' EXIT
        trap 'echo; echo "Interrupted. Re-run the script to continue — finished steps are skipped."; exit 130' INT TERM
    else
        echo -e "${YELLOW}  [!] termux-wake-lock unavailable — keep your screen on during install.${NC}"
        echo ""
    fi

    show_banner
    if [ "$ASSUME_YES" == "yes" ] || [ -z "$TTY_IN" ]; then
        echo -e "${GRAY}  Running unattended — using flags/defaults for every choice.${NC}"
        echo ""
    fi
    setup_environment

    step_update || return 1
    step_repos || return 1
    step_x11
    step_desktop
    check_required_packages || return 1
    step_gpu
    check_required_packages || return 1
    step_audio
    step_apps
    step_python

    [ "$INSTALL_ANTIGRAVITY" == "yes" ] && step_antigravity
    [ "$INSTALL_WINE" == "yes" ] && step_wine

    step_launchers || return 1
    step_shortcuts
    show_completion

    if command -v termux-wake-unlock &>/dev/null; then
        termux-wake-unlock
        log "Wake lock released."
    fi
}

parse_args "$@"
main "$@"
