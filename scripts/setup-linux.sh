#!/usr/bin/env bash
#
# IB9JHO C++ development environment setup and diagnostics for Linux.
#
# Installs and verifies every tool needed to build IB9JHO coursework with
# Clang, CMake and Ninja in Visual Studio Code:
#
#   1. Pre-flight checks   (distribution, architecture, disk space, network)
#   2. Package manager      (apt, dnf, pacman or zypper)
#   3. Git
#   4. Clang C++ compiler   (plus the C++ standard library headers)
#   5. CMake
#   6. Ninja
#   7. Debugger             (GDB, optional)
#   8. Visual Studio Code   (plus the IB9JHO extensions)
#   9. End-to-end test      (configure, build, run and test a small CMake project)
#
# Every step is followed by a test that proves the tool works, and every
# failure is reported with specific advice. All commands and their full output
# are written to a timestamped log file so that an instructor can see exactly
# where and why the setup failed.
#
# Usage:
#   bash setup-linux.sh [options]
#
#   --check-only      Diagnose only; do not install or change anything.
#   --skip-vscode     Skip Visual Studio Code and its extensions (e.g. on a
#                     headless server, a container or WSL).
#   --project DIR     Additionally configure and build the CMake project in DIR
#                     using its "clang" preset.
#   --log-file FILE   Write the log to FILE instead of the default location.
#   --yes             Never prompt; assume "yes" for every question.
#   --help            Show this help and exit.
#
# Exit status: 0 when every required check passed (warnings are allowed),
# 1 when at least one required check failed, 2 on invalid usage.

set -o pipefail
set -o nounset

readonly SCRIPT_NAME="IB9JHO environment setup (Linux)"
readonly SCRIPT_VERSION="1.0.0"
readonly MIN_CMAKE_VERSION="3.21"
readonly MIN_CLANG_MAJOR=14
readonly MIN_FREE_DISK_MB=3072
readonly VSCODE_EXTENSIONS=(
    ms-vscode.cpptools
    ms-vscode.cpptools-extension-pack
    ms-vscode.cmake-tools
    brobeson.ctest-lab
    github.vscode-github-actions
)

# ----------------------------------------------------------------------------
# Command-line options
# ----------------------------------------------------------------------------

CHECK_ONLY=0
SKIP_VSCODE=0
ASSUME_YES=0
PROJECT_DIR=""
LOG_FILE="${HOME:-/tmp}/ib9jho-setup-$(date +%Y%m%d-%H%M%S).log"

print_usage() {
    # Print the header comment block (minus the shebang) as the help text. When
    # the script is piped from the web there is no file to read, so point to it.
    if [[ -f "${BASH_SOURCE[0]}" ]]; then
        sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    else
        echo "See the header of scripts/$(basename "${BASH_SOURCE[0]:-setup.sh}") in the IB9JHO environment-setup repository."
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only) CHECK_ONLY=1 ;;
        --skip-vscode) SKIP_VSCODE=1 ;;
        --yes | -y) ASSUME_YES=1 ;;
        --project)
            [[ $# -ge 2 ]] || { echo "error: --project requires a directory" >&2; exit 2; }
            PROJECT_DIR="$2"; shift ;;
        --log-file)
            [[ $# -ge 2 ]] || { echo "error: --log-file requires a path" >&2; exit 2; }
            LOG_FILE="$2"; shift ;;
        --help | -h) print_usage; exit 0 ;;
        *) echo "error: unknown option '$1' (use --help)" >&2; exit 2 ;;
    esac
    shift
done

# ----------------------------------------------------------------------------
# Logging and result tracking
# ----------------------------------------------------------------------------

if [[ -t 1 ]]; then
    readonly C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_BLUE=$'\033[34m'
else
    readonly C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ib9jho-setup.XXXXXX")"
readonly WORK_DIR
readonly CMD_OUTPUT_FILE="$WORK_DIR/last-command-output.txt"
trap 'rm -rf "$WORK_DIR"' EXIT

if ! { mkdir -p "$(dirname "$LOG_FILE")" && : > "$LOG_FILE"; }; then
    echo "error: cannot write log file '$LOG_FILE'; use --log-file to choose another location" >&2
    exit 2
fi

RESULT_NAMES=()
RESULT_STATUSES=()
RESULT_DETAILS=()
ADVICE=()
CURRENT_STEP=""

# Append a timestamped line to the log file only.
log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# Print to the console and the log.
say() {
    printf '%s\n' "$*"
    log "$*"
}

info() { printf '  %s\n' "$*"; log "INFO  $*"; }

begin_step() {
    CURRENT_STEP="$1"
    printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$1" "$C_RESET"
    log "================================================================"
    log "STEP  $1"
    log "================================================================"
}

# Record the outcome of the current step. Status is PASS, WARN, FAIL or SKIP.
record() {
    local status="$1" detail="$2" colour
    case "$status" in
        PASS) colour="$C_GREEN" ;;
        WARN | SKIP) colour="$C_YELLOW" ;;
        *) colour="$C_RED" ;;
    esac
    printf '  %s[%s]%s %s\n' "$colour" "$status" "$C_RESET" "$detail"
    log "$status  $CURRENT_STEP: $detail"
    RESULT_NAMES+=("$CURRENT_STEP")
    RESULT_STATUSES+=("$status")
    RESULT_DETAILS+=("$detail")
}

pass() { record PASS "$1"; }
warn() { record WARN "$1"; }
skip() { record SKIP "$1"; }
fail() { record FAIL "$1"; }

# Register a piece of advice for the summary, attributed to the current step.
advise() {
    ADVICE+=("[$CURRENT_STEP] $1")
    log "ADVICE $1"
}

# Run a command, streaming its combined output to the log file. The output is
# also kept in CMD_OUTPUT_FILE so that callers can inspect it. Returns the
# command's exit status.
run() {
    log "\$ $*"
    "$@" 2>&1 | tee "$CMD_OUTPUT_FILE" >> "$LOG_FILE"
    local status=${PIPESTATUS[0]}
    log "[exit status $status]"
    return "$status"
}

# Show the last lines of the most recent command's output on the console, so
# that the student sees the actual error without opening the log.
show_last_output() {
    local lines="${1:-15}"
    [[ -s "$CMD_OUTPUT_FILE" ]] || return 0
    printf '  %s--- last %s lines of output ---%s\n' "$C_YELLOW" "$lines" "$C_RESET"
    tail -n "$lines" "$CMD_OUTPUT_FILE" | sed 's/^/  | /'
    printf '  %s--------------------------------%s\n' "$C_YELLOW" "$C_RESET"
}

# Return success when version $1 is greater than or equal to version $2.
version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# Extract the first dotted version number (e.g. 3.28.3) from a string.
extract_version() {
    grep -Eo '[0-9]+(\.[0-9]+)+' <<< "$1" | head -n1
}

# Ask a yes/no question; returns success for yes. Honours --yes and stays
# non-interactive when there is no terminal to ask on.
confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    [[ -t 0 ]] || return 0
    local reply
    read -r -p "  $1 [Y/n] " reply
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# Record the state of the tool chain in the log; invaluable when diagnosing
# PATH problems remotely.
log_environment_snapshot() {
    log "---- environment snapshot ----"
    log "PATH=$PATH"
    local var
    for var in CC CXX CMAKE_GENERATOR CMAKE_MAKE_PROGRAM CMAKE_PREFIX_PATH CPLUS_INCLUDE_PATH \
        LD_LIBRARY_PATH http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy; do
        [[ -n "${!var:-}" ]] && log "$var=${!var}"
    done
    local tool
    for tool in git clang clang++ gcc g++ cmake ninja gdb code; do
        log "which -a $tool: $(type -a -p "$tool" 2>/dev/null | tr '\n' ' ')"
    done
    log "---- end of snapshot ----"
}

# ----------------------------------------------------------------------------
# Privilege handling and package manager abstraction
# ----------------------------------------------------------------------------

SUDO=()
PKG_MANAGER=""
PKG_INSTALL_ADVISED=0
DISTRO_ID="unknown"
DISTRO_NAME="unknown Linux distribution"
IS_WSL=0

# Run a command as root, using sudo when the script is not already root.
as_root() {
    run "${SUDO[@]}" "$@"
}

# Install the given packages with the detected package manager.
pkg_install() {
    case "$PKG_MANAGER" in
        apt) as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
        dnf) as_root dnf install -y "$@" ;;
        pacman) as_root pacman -S --needed --noconfirm "$@" ;;
        zypper) as_root zypper --non-interactive install "$@" ;;
        *) return 1 ;;
    esac
}

# Translate a logical package name into the distribution's package name(s).
pkg_names() {
    local logical="$1"
    case "$PKG_MANAGER:$logical" in
        apt:git) echo "git ca-certificates" ;;
        apt:compiler) echo "clang build-essential" ;;
        apt:cmake) echo "cmake" ;;
        apt:ninja) echo "ninja-build" ;;
        apt:gdb) echo "gdb" ;;
        dnf:git) echo "git" ;;
        dnf:compiler) echo "clang gcc-c++" ;;
        dnf:cmake) echo "cmake" ;;
        dnf:ninja) echo "ninja-build" ;;
        dnf:gdb) echo "gdb" ;;
        pacman:git) echo "git" ;;
        pacman:compiler) echo "clang gcc" ;;
        pacman:cmake) echo "cmake" ;;
        pacman:ninja) echo "ninja" ;;
        pacman:gdb) echo "gdb" ;;
        zypper:git) echo "git" ;;
        zypper:compiler) echo "clang gcc-c++" ;;
        zypper:cmake) echo "cmake" ;;
        zypper:ninja) echo "ninja" ;;
        zypper:gdb) echo "gdb" ;;
    esac
}

# Install a logical package unless running in check-only mode. Reports a
# failure (with the package manager's output) and returns non-zero on error.
install_logical() {
    local logical="$1" names
    names="$(pkg_names "$logical")"
    if [[ $CHECK_ONLY -eq 1 ]]; then
        info "Check-only mode: not installing ($names)."
        return 1
    fi
    if [[ -z "$PKG_MANAGER" ]]; then
        info "No supported package manager; cannot install ($logical)."
        return 1
    fi
    info "Installing: $names"
    # shellcheck disable=SC2086  # Word splitting of the package list is intended.
    if ! pkg_install $names; then
        show_last_output
        # The cause is usually shared by every later install, so advise once.
        if [[ $PKG_INSTALL_ADVISED -eq 0 ]]; then
            PKG_INSTALL_ADVISED=1
            advise "Installing packages with $PKG_MANAGER failed (first failure: '$names'). Read the package manager output above or in the log; common causes are no internet access, another package manager running (wait and retry) or a broken package database."
        fi
        return 1
    fi
    hash -r
    return 0
}

# ----------------------------------------------------------------------------
# Step 1: pre-flight checks
# ----------------------------------------------------------------------------

step_preflight() {
    begin_step "Pre-flight checks"

    if [[ "$(uname -s)" != "Linux" ]]; then
        fail "This script is for Linux, but this system reports '$(uname -s)'."
        advise "Use setup-macos.sh on macOS or setup-windows.ps1 on Windows."
        return 1
    fi

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091  # Provided by the operating system.
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
    fi
    if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        IS_WSL=1
    fi
    info "System: $DISTRO_NAME, kernel $(uname -r), $(uname -m)$([[ $IS_WSL -eq 1 ]] && echo ', running under WSL')"
    info "User: $(id -un) (uid $(id -u)), shell: ${SHELL:-unknown}"
    info "Script: $SCRIPT_NAME $SCRIPT_VERSION$([[ $CHECK_ONLY -eq 1 ]] && echo ' (check-only mode)')"
    log_environment_snapshot

    # Work out how to obtain root privileges for installing packages.
    if [[ $EUID -eq 0 ]]; then
        SUDO=()
    elif command -v sudo > /dev/null 2>&1; then
        SUDO=(sudo)
    else
        SUDO=(false)
        if [[ $CHECK_ONLY -eq 0 ]]; then
            warn "Not running as root and 'sudo' is not available; packages cannot be installed."
            advise "Run the script as root, or ask your administrator to install sudo and add you to the sudoers group."
        fi
    fi

    # Detect the package manager.
    local candidate
    for candidate in apt-get dnf pacman zypper; do
        if command -v "$candidate" > /dev/null 2>&1; then
            PKG_MANAGER="${candidate%-get}"
            break
        fi
    done
    if [[ -n "$PKG_MANAGER" ]]; then
        info "Package manager: $PKG_MANAGER"
    else
        warn "No supported package manager (apt, dnf, pacman, zypper) was found."
        advise "Install git, clang, cmake (>= $MIN_CMAKE_VERSION) and ninja with your distribution's package manager, then re-run this script with --check-only."
    fi

    # Free disk space in the home directory (where coursework will live).
    local free_mb
    free_mb="$(df -Pm "${HOME:-/}" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -n "$free_mb" && "$free_mb" -lt $MIN_FREE_DISK_MB ]]; then
        warn "Only ${free_mb} MB free in ${HOME:-/}; at least ${MIN_FREE_DISK_MB} MB is recommended."
        advise "Free up disk space before installing; the tool chain and Visual Studio Code need roughly 2-3 GB."
    else
        info "Free disk space in ${HOME:-/}: ${free_mb:-unknown} MB"
    fi

    # Network connectivity, needed for installs and for cloning repositories.
    if [[ $CHECK_ONLY -eq 0 ]]; then
        if command -v curl > /dev/null 2>&1; then
            if run curl -fsSL --max-time 20 -o /dev/null https://github.com; then
                info "Network: github.com is reachable."
            else
                show_last_output 5
                # Not fatal: package mirrors may still be reachable, and the
                # install steps report their own network errors.
                warn "Cannot reach https://github.com; installs and cloning repositories may fail."
                advise "Check your internet connection. On university or corporate networks, make sure the proxy is set (https_proxy) and that HTTPS is not intercepted without the CA certificate installed."
            fi
        else
            info "curl is not installed yet; skipping the network check (it will be installed if needed)."
        fi
    fi

    if [[ $CHECK_ONLY -eq 0 && ${#SUDO[@]} -gt 0 && "${SUDO[0]}" == "sudo" ]]; then
        info "Administrator rights are needed to install packages; you may be asked for your password."
        if ! sudo -v; then
            fail "Could not obtain administrator rights with sudo."
            advise "Make sure your account is allowed to use sudo (e.g. it is in the 'sudo' or 'wheel' group), or run the script with --check-only to diagnose without installing."
            return 1
        fi
    fi

    # Only add a summary PASS when nothing above was flagged for this step.
    if [[ ${#RESULT_NAMES[@]} -eq 0 || "${RESULT_NAMES[-1]}" != "$CURRENT_STEP" ]]; then
        pass "Pre-flight checks completed."
    fi
}

# ----------------------------------------------------------------------------
# Step 2: package manager
# ----------------------------------------------------------------------------

step_package_manager() {
    begin_step "Package manager"

    if [[ -z "$PKG_MANAGER" ]]; then
        fail "No supported package manager available."
        return 1
    fi
    if [[ $CHECK_ONLY -eq 1 ]]; then
        pass "Using $PKG_MANAGER (index not refreshed in check-only mode)."
        return 0
    fi

    local ok=0
    case "$PKG_MANAGER" in
        apt) as_root apt-get update && ok=1 ;;
        dnf) as_root dnf makecache && ok=1 ;;
        pacman) as_root pacman -Sy --noconfirm && ok=1 ;;
        zypper) as_root zypper --non-interactive refresh && ok=1 ;;
    esac

    # apt-get can exit successfully even when some repositories failed to
    # download, leaving packages "unable to locate"; detect that explicitly.
    if [[ $ok -eq 1 ]] && grep -qE '^(Err:|W: Failed to fetch|W: Some index files failed|E: )' "$CMD_OUTPUT_FILE"; then
        show_last_output
        warn "Some package repositories could not be refreshed; installs may fail with 'unable to locate package'."
        advise "Read the 'Err:' lines above (also in the log). They usually point to no internet access, a proxy or firewall blocking the package mirror, or a broken third-party repository in /etc/apt/sources.list.d/."
    fi

    if [[ $ok -eq 1 ]]; then
        # curl is used for network checks and to download Visual Studio Code.
        if ! command -v curl > /dev/null 2>&1; then
            pkg_install curl ca-certificates || true
        fi
        pass "$PKG_MANAGER package index refreshed."
    else
        show_last_output
        fail "Refreshing the $PKG_MANAGER package index failed."
        if grep -qiE 'could not get lock|is locked|another .*process' "$CMD_OUTPUT_FILE"; then
            advise "Another program (often the automatic updater) is using the package manager. Wait for it to finish or restart the computer, then re-run this script."
        elif grep -qiE 'temporary failure resolving|could not resolve|network is unreachable|timed out' "$CMD_OUTPUT_FILE"; then
            advise "The package servers could not be reached. Check your internet connection and proxy settings."
        elif grep -qiE 'NO_PUBKEY|not signed|signature' "$CMD_OUTPUT_FILE"; then
            advise "A third-party repository has an invalid or missing signing key. Remove or fix the offending file in /etc/apt/sources.list.d/ (named in the output), then retry."
        else
            advise "Run the package manager's update command manually to see the full error, and fix any broken repositories it reports."
        fi
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Step 3: Git
# ----------------------------------------------------------------------------

step_git() {
    begin_step "Git"

    if ! command -v git > /dev/null 2>&1; then
        install_logical git || true
    fi
    if ! command -v git > /dev/null 2>&1; then
        fail "git is not installed."
        advise "Install Git with your package manager (e.g. 'sudo apt install git')."
        return 1
    fi

    if ! run git --version; then
        show_last_output
        fail "git is installed at $(command -v git) but does not run."
        advise "Reinstall Git with your package manager."
        return 1
    fi
    local version
    version="$(extract_version "$(cat "$CMD_OUTPUT_FILE")")"

    # Functional test: create a repository and make a commit in a temporary folder.
    local repo="$WORK_DIR/git-test"
    if run git init -q "$repo" \
        && run git -C "$repo" -c user.name="IB9JHO Setup" -c user.email="setup@example.invalid" \
            commit -q --allow-empty -m "setup test"; then
        pass "git $version works ($(command -v git))."
    else
        show_last_output
        fail "git $version is installed but could not create a test commit."
        advise "Check that the temporary directory ($WORK_DIR) is writable and that no global Git hooks or configuration are broken ('git config --list --show-origin')."
        return 1
    fi

    if [[ -z "$(git config --global user.name 2>/dev/null)" || -z "$(git config --global user.email 2>/dev/null)" ]]; then
        warn "Your Git name and email are not configured, so commits will fail."
        advise "Run: git config --global user.name \"Your Name\"  and  git config --global user.email \"you@example.com\" (use the email of your GitHub account)."
    fi
}

# ----------------------------------------------------------------------------
# Step 4: Clang C++ compiler
# ----------------------------------------------------------------------------

# Write a small C++20 program that exercises the language features and the
# standard library headers used early in the course.
write_cpp_test_program() {
    cat > "$1" <<'CPP'
#include <concepts>
#include <iostream>
#include <numeric>
#include <span>
#include <string>
#include <vector>

// A constrained template (C++20 concepts) operating on a std::span (C++20).
template <std::floating_point T>
T mean(std::span<const T> values)
{
    return std::accumulate(values.begin(), values.end(), T{0}) / static_cast<T>(values.size());
}

int main()
{
    const std::vector<double> prices{100.0, 101.5, 99.25, 102.0};
    const std::string message = "IB9JHO toolchain OK";
    std::cout << message << ": mean price = " << mean<double>(prices) << '\n';
    return mean<double>(prices) > 100.0 ? 0 : 1;
}
CPP
}

# On Debian-based systems Clang uses the newest GCC installation it finds for
# the C++ standard library. If that GCC's libstdc++ headers are missing,
# '#include <iostream>' fails. Install the matching headers when possible.
repair_libstdcxx_headers() {
    local selected gcc_major
    selected="$(clang++ -v -E -x c++ /dev/null 2>&1 | sed -n 's/^Selected GCC installation: //p')"
    log "Clang selected GCC installation: ${selected:-none}"
    gcc_major="$(basename "${selected:-}")"
    [[ "$gcc_major" =~ ^[0-9]+$ ]] || return 1
    info "Clang is using the GCC $gcc_major standard library, whose headers appear to be missing."
    advise "Clang selected the GCC $gcc_major installation ($selected) but its C++ headers are missing. Install them with: sudo apt install libstdc++-$gcc_major-dev (or g++-$gcc_major)."
    [[ $CHECK_ONLY -eq 0 && "$PKG_MANAGER" == "apt" ]] || return 1
    info "Installing libstdc++-$gcc_major-dev to fix this."
    pkg_install "libstdc++-$gcc_major-dev"
}

step_compiler() {
    begin_step "Clang C++ compiler"

    if ! command -v clang++ > /dev/null 2>&1 || ! command -v clang > /dev/null 2>&1; then
        install_logical compiler || true
    fi
    if ! command -v clang++ > /dev/null 2>&1; then
        fail "clang++ is not installed (or not on PATH)."
        advise "Install Clang with your package manager (e.g. 'sudo apt install clang'). If you installed a versioned package such as clang-18, also install the unversioned 'clang' package so that 'clang++' is on PATH."
        return 1
    fi

    run clang++ --version
    local version major
    version="$(extract_version "$(head -n1 "$CMD_OUTPUT_FILE")")"
    major="${version%%.*}"
    info "Found clang++ $version at $(command -v clang++)"

    local source="$WORK_DIR/compiler-test.cpp" binary="$WORK_DIR/compiler-test"
    write_cpp_test_program "$source"

    if ! run clang++ -std=c++20 -Wall -Wextra -o "$binary" "$source"; then
        if grep -qE "'(iostream|concepts|vector|string|span)' file not found" "$CMD_OUTPUT_FILE" \
            && repair_libstdcxx_headers \
            && run clang++ -std=c++20 -Wall -Wextra -o "$binary" "$source"; then
            info "Missing standard library headers were installed."
        else
            show_last_output
            fail "clang++ $version could not compile a C++20 test program."
            if grep -qiE "cannot find -l(stdc\+\+|gcc)|unable to find library" "$CMD_OUTPUT_FILE"; then
                advise "The linker cannot find the C++ runtime library. Install the GCC development packages (e.g. 'sudo apt install build-essential' or 'sudo dnf install gcc-c++')."
            elif grep -qiE "file not found" "$CMD_OUTPUT_FILE"; then
                advise "Standard library headers are missing. Install them with 'sudo apt install build-essential' (Debian/Ubuntu) or 'sudo dnf install gcc-c++' (Fedora)."
            elif [[ -n "$major" && "$major" -lt $MIN_CLANG_MAJOR ]]; then
                advise "Clang $version is too old for C++20; version $MIN_CLANG_MAJOR or newer is required. Upgrade your distribution or install a newer Clang from https://apt.llvm.org."
            else
                advise "Read the compiler error above. Re-run with the log file attached when asking your instructor for help."
            fi
            return 1
        fi
    fi

    if ! run "$binary"; then
        show_last_output
        fail "The test program compiled but did not run correctly."
        advise "Check that $WORK_DIR is not on a file system mounted with 'noexec' (set TMPDIR to another directory and retry)."
        return 1
    fi

    if [[ -n "$major" && "$major" -lt $MIN_CLANG_MAJOR ]]; then
        warn "clang++ $version works, but Clang $MIN_CLANG_MAJOR or newer is recommended for C++20."
        advise "Consider upgrading Clang (e.g. from https://apt.llvm.org) to avoid gaps in C++20 support."
    else
        pass "clang++ $version compiles and runs C++20 code."
    fi
}

# ----------------------------------------------------------------------------
# Steps 5 and 6: CMake and Ninja
# ----------------------------------------------------------------------------

step_cmake() {
    begin_step "CMake"

    if ! command -v cmake > /dev/null 2>&1; then
        install_logical cmake || true
    fi
    if ! command -v cmake > /dev/null 2>&1; then
        fail "cmake is not installed."
        advise "Install CMake with your package manager (e.g. 'sudo apt install cmake')."
        return 1
    fi

    if ! run cmake --version; then
        show_last_output
        fail "cmake is installed at $(command -v cmake) but does not run."
        advise "Reinstall CMake with your package manager."
        return 1
    fi
    local version
    version="$(extract_version "$(head -n1 "$CMD_OUTPUT_FILE")")"

    if version_ge "$version" "$MIN_CMAKE_VERSION"; then
        pass "cmake $version ($(command -v cmake))."
    else
        fail "cmake $version is too old; version $MIN_CMAKE_VERSION or newer is required for CMake presets."
        advise "Install a newer CMake: 'pip install --user cmake' (then make sure ~/.local/bin is on PATH), Kitware's APT repository (https://apt.kitware.com) or 'sudo snap install cmake --classic'."
        return 1
    fi
}

step_ninja() {
    begin_step "Ninja build system"

    if ! command -v ninja > /dev/null 2>&1; then
        install_logical ninja || true
    fi
    if ! command -v ninja > /dev/null 2>&1; then
        fail "ninja is not installed."
        advise "Install Ninja with your package manager (Debian/Ubuntu/Fedora: 'ninja-build'; Arch/openSUSE: 'ninja')."
        return 1
    fi
    if run ninja --version; then
        pass "ninja $(head -n1 "$CMD_OUTPUT_FILE") ($(command -v ninja))."
    else
        show_last_output
        fail "ninja is installed at $(command -v ninja) but does not run."
        advise "Reinstall Ninja with your package manager."
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Step 7: debugger (optional)
# ----------------------------------------------------------------------------

step_debugger() {
    begin_step "Debugger (GDB, optional)"

    if ! command -v gdb > /dev/null 2>&1; then
        install_logical gdb || true
    fi
    if command -v gdb > /dev/null 2>&1 && run gdb --version; then
        pass "$(head -n1 "$CMD_OUTPUT_FILE")."
    else
        warn "GDB is not available; building and testing will work, but debugging in VS Code will not."
        advise "Install GDB with your package manager (e.g. 'sudo apt install gdb') to use the VS Code debugger."
    fi
}

# ----------------------------------------------------------------------------
# Step 8: Visual Studio Code and extensions
# ----------------------------------------------------------------------------

# Arguments that let the VS Code command-line run when the script runs as root
# (as it does in containers); VS Code refuses to run as root otherwise.
code_cli() {
    if [[ $EUID -eq 0 ]]; then
        code --no-sandbox --user-data-dir "${HOME:-/root}/.vscode-root" "$@"
    else
        code "$@"
    fi
}

install_vscode() {
    local arch download_os package
    case "$(uname -m)" in
        x86_64) arch="x64" ;;
        aarch64 | arm64) arch="arm64" ;;
        armv7l) arch="armhf" ;;
        *) info "Unsupported architecture $(uname -m) for VS Code packages."; return 1 ;;
    esac

    case "$PKG_MANAGER" in
        apt) download_os="linux-deb-$arch"; package="$WORK_DIR/code.deb" ;;
        dnf | zypper) download_os="linux-rpm-$arch"; package="$WORK_DIR/code.rpm" ;;
        *)
            if command -v snap > /dev/null 2>&1; then
                as_root snap install code --classic
                return
            fi
            info "No VS Code package is available for $PKG_MANAGER."
            advise "Install VS Code manually from https://code.visualstudio.com (Arch: the 'visual-studio-code-bin' AUR package; the open-source 'code' package cannot install the Microsoft C++ extension)."
            return 1 ;;
    esac

    info "Downloading the official VS Code package ($download_os)."
    if ! run curl -fsSL --retry 3 --max-time 600 -o "$package" \
        "https://code.visualstudio.com/sha/download?build=stable&os=$download_os"; then
        advise "Downloading VS Code from code.visualstudio.com failed. Check that the site is reachable from this network (proxies and firewalls sometimes block it), or download the package in a browser and install it manually."
        return 1
    fi

    case "$PKG_MANAGER" in
        apt)
            # Let the package add Microsoft's repository so VS Code updates with the system.
            echo "code code/add-microsoft-repo boolean true" | run "${SUDO[@]}" debconf-set-selections || true
            as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$package" ;;
        dnf) as_root dnf install -y "$package" ;;
        zypper) as_root zypper --non-interactive --no-gpg-checks install "$package" ;;
    esac
}

step_vscode() {
    begin_step "Visual Studio Code"

    if [[ $SKIP_VSCODE -eq 1 ]]; then
        skip "Skipped (--skip-vscode)."
        return 0
    fi
    if [[ $IS_WSL -eq 1 ]]; then
        skip "Running under WSL: VS Code should be installed on Windows, not inside WSL."
        advise "Install VS Code on Windows (run setup-windows.ps1 there) and the 'WSL' extension (ms-vscode-remote.remote-wsl), then open this Linux folder with 'code .' from the WSL terminal."
        return 0
    fi

    if ! command -v code > /dev/null 2>&1; then
        if [[ $CHECK_ONLY -eq 1 ]]; then
            info "Check-only mode: not installing VS Code."
        else
            install_vscode || show_last_output
            hash -r
        fi
    fi
    if ! command -v code > /dev/null 2>&1; then
        fail "Visual Studio Code ('code' command) is not installed."
        advise "Install VS Code from https://code.visualstudio.com/download (choose the .deb or .rpm package for your distribution), then re-run this script."
        return 1
    fi

    if ! run code_cli --version; then
        show_last_output
        fail "The 'code' command exists ($(command -v code)) but does not run."
        advise "Reinstall VS Code. If you use a Flatpak build, note that it cannot use the system compilers without extra configuration; use the .deb/.rpm package instead."
        return 1
    fi
    pass "VS Code $(head -n1 "$CMD_OUTPUT_FILE") ($(command -v code))."

    begin_step "VS Code extensions"
    local extension missing=()
    for extension in "${VSCODE_EXTENSIONS[@]}"; do
        if [[ $CHECK_ONLY -eq 0 ]]; then
            run code_cli --install-extension "$extension" --force || show_last_output 5
        fi
    done
    run code_cli --list-extensions
    for extension in "${VSCODE_EXTENSIONS[@]}"; do
        grep -qix "$extension" "$CMD_OUTPUT_FILE" || missing+=("$extension")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        pass "All ${#VSCODE_EXTENSIONS[@]} IB9JHO extensions are installed."
    else
        fail "Missing extensions: ${missing[*]}"
        advise "Install the missing extensions from the Extensions tab in VS Code, or run 'code --install-extension <name>' for each. The marketplace must be reachable (check proxy settings)."
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Step 9: end-to-end CMake test
# ----------------------------------------------------------------------------

# Write a minimal project with the same CMake preset that IB9JHO repositories
# use, so that this test reproduces exactly what VS Code will do.
write_smoke_project() {
    local dir="$1"
    mkdir -p "$dir"
    write_cpp_test_program "$dir/main.cpp"
    cat > "$dir/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.21)
project(IB9JHOSmokeTest)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_compile_options(-Wall -Wextra)

add_executable(smoke_test main.cpp)

enable_testing()
add_test(NAME smoke_test_output COMMAND smoke_test)
set_tests_properties(smoke_test_output PROPERTIES PASS_REGULAR_EXPRESSION "IB9JHO toolchain OK")
CMAKE
    cat > "$dir/CMakePresets.json" <<'JSON'
{
    "version": 3,
    "cmakeMinimumRequired": { "major": 3, "minor": 21, "patch": 0 },
    "configurePresets": [
        {
            "name": "clang",
            "generator": "Ninja",
            "binaryDir": "${sourceDir}/build",
            "cacheVariables": {
                "CMAKE_BUILD_TYPE": "Debug",
                "CMAKE_C_COMPILER": "clang",
                "CMAKE_CXX_COMPILER": "clang++",
                "CMAKE_EXPORT_COMPILE_COMMANDS": "ON"
            }
        }
    ],
    "buildPresets": [ { "name": "clang", "configurePreset": "clang" } ],
    "testPresets": [ { "name": "clang", "configurePreset": "clang", "output": { "outputOnFailure": true } } ]
}
JSON
}

# Give targeted advice for a failed CMake configure step.
advise_configure_failure() {
    if grep -qiE 'CMAKE_MAKE_PROGRAM is not set|Unable to find the Ninja|ninja.*not found' "$CMD_OUTPUT_FILE"; then
        advise "CMake cannot find Ninja. Make sure 'ninja' is installed and on PATH (see the Ninja step)."
    elif grep -qiE 'CMAKE_(CXX|C)_COMPILER.*(not found|is not a full path)|could not find compiler' "$CMD_OUTPUT_FILE"; then
        advise "CMake cannot find clang/clang++ on PATH. Make sure the compiler step passed and that 'clang++' runs in a new terminal."
    elif grep -qiE 'is not able to compile a simple test program' "$CMD_OUTPUT_FILE"; then
        advise "The compiler works on its own but not through CMake; the log contains the full compiler error. A stale build folder can also cause this: delete the 'build' folder and try again."
    elif grep -qiE 'Could not read presets|preset.*not found|Unrecognized "version"' "$CMD_OUTPUT_FILE"; then
        advise "CMake could not read CMakePresets.json. Make sure CMake is version $MIN_CMAKE_VERSION or newer."
    else
        advise "Read the CMake output above (full output in the log). Deleting the 'build' folder and reconfiguring fixes many cache-related errors."
    fi
}

step_smoke_test() {
    begin_step "End-to-end test (CMake + Ninja + Clang)"

    local tool missing=()
    for tool in cmake ninja clang clang++; do
        command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        fail "Not run, because these tools are missing: ${missing[*]}."
        advise "Fix the failed steps above first; this test needs CMake, Ninja and Clang."
        return 1
    fi

    local dir="$WORK_DIR/smoke-project"
    write_smoke_project "$dir"

    if ! (cd "$dir" && run cmake --preset clang); then
        show_last_output 25
        fail "CMake could not configure a test project with the 'clang' preset."
        advise_configure_failure
        return 1
    fi
    if ! (cd "$dir" && run cmake --build --preset clang); then
        show_last_output 25
        fail "The test project configured but did not build."
        advise "Read the build errors above. If Clang works on its own (compiler step) but fails here, delete the build folder and retry."
        return 1
    fi
    if ! (cd "$dir" && run ctest --preset clang); then
        show_last_output 25
        fail "The test project built but its test (CTest) did not pass."
        advise "The program built but produced unexpected output; check the log for the program output."
        return 1
    fi
    pass "Configured, built and tested a C++20 project with the 'clang' preset."
}

step_project() {
    [[ -n "$PROJECT_DIR" ]] || return 0
    begin_step "Project build ($PROJECT_DIR)"

    if [[ ! -f "$PROJECT_DIR/CMakeLists.txt" ]]; then
        fail "No CMakeLists.txt in '$PROJECT_DIR'."
        advise "Pass the folder that contains the repository's top-level CMakeLists.txt to --project."
        return 1
    fi
    local configure_args=(--preset clang)
    if [[ ! -f "$PROJECT_DIR/CMakePresets.json" ]]; then
        warn "The project has no CMakePresets.json; using equivalent command-line settings."
        advise "Copy CMakePresets.json from the IB9JHO environment-setup repository into the project so VS Code picks Clang and Ninja automatically."
        configure_args=(-S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++)
    fi
    if ! (cd "$PROJECT_DIR" && run cmake "${configure_args[@]}"); then
        show_last_output 25
        fail "The project did not configure."
        advise_configure_failure
        return 1
    fi
    if ! (cd "$PROJECT_DIR" && run cmake --build build); then
        show_last_output 25
        fail "The project configured but did not build."
        advise "The tool chain works (see the end-to-end test), so this is most likely an error in the project's own code; read the compiler errors above."
        return 1
    fi
    pass "The project configured and built. (Its tests were not run, as coursework tests are expected to fail until completed.)"
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------

print_summary() {
    local i failures=0 warnings=0 colour
    printf '\n%s==> Summary%s\n' "$C_BOLD$C_BLUE" "$C_RESET"
    log "================================================================"
    log "SUMMARY"
    for i in "${!RESULT_NAMES[@]}"; do
        case "${RESULT_STATUSES[$i]}" in
            PASS) colour="$C_GREEN" ;;
            WARN | SKIP) colour="$C_YELLOW"; [[ "${RESULT_STATUSES[$i]}" == WARN ]] && warnings=$((warnings + 1)) ;;
            *) colour="$C_RED"; failures=$((failures + 1)) ;;
        esac
        printf '  %s%-4s%s  %-42s %s\n' "$colour" "${RESULT_STATUSES[$i]}" "$C_RESET" "${RESULT_NAMES[$i]}" "${RESULT_DETAILS[$i]}"
        log "${RESULT_STATUSES[$i]}  ${RESULT_NAMES[$i]}: ${RESULT_DETAILS[$i]}"
    done

    if [[ ${#ADVICE[@]} -gt 0 ]]; then
        printf '\n%sWhat to do next:%s\n' "$C_BOLD" "$C_RESET"
        local item
        for item in "${ADVICE[@]}"; do
            printf '  - %s\n' "$item"
        done
    fi

    printf '\nFull log: %s\n' "$LOG_FILE"
    if [[ $failures -eq 0 ]]; then
        say "${C_GREEN}${C_BOLD}Your IB9JHO environment is ready${C_RESET}$([[ $warnings -gt 0 ]] && echo " ($warnings warning(s) above)")."
        say "Open a course repository in VS Code and select the 'Clang (IB9JHO)' preset when asked."
        [[ $CHECK_ONLY -eq 0 ]] && say "If 'code', 'clang++' or 'cmake' are not found in an existing terminal, open a new terminal."
        return 0
    fi
    say "${C_RED}${C_BOLD}$failures check(s) failed.${C_RESET} Follow the advice above and re-run this script."
    say "If you are stuck, send the log file above to your instructor."
    return 1
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
    say "${C_BOLD}$SCRIPT_NAME $SCRIPT_VERSION${C_RESET}"
    say "Logging to $LOG_FILE"

    if ! step_preflight; then
        print_summary
        return 1
    fi
    if [[ $CHECK_ONLY -eq 0 ]] && [[ -n "$PKG_MANAGER" ]] && ! confirm "Install any missing IB9JHO tools now?"; then
        CHECK_ONLY=1
        info "Continuing in check-only mode."
    fi

    step_package_manager || true
    step_git || true
    step_compiler || true
    step_cmake || true
    step_ninja || true
    step_debugger || true
    step_vscode || true
    step_smoke_test || true
    step_project || true

    log_environment_snapshot
    print_summary
}

main
