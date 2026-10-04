#!/bin/bash
#
# IB9JHO C++ development environment setup and diagnostics for macOS.
#
# Installs and verifies every tool needed to build IB9JHO coursework with
# Clang, CMake and Ninja in Visual Studio Code:
#
#   1. Pre-flight checks          (macOS version, architecture, disk, network)
#   2. Xcode Command Line Tools   (Apple Clang, Git, LLDB, the macOS SDK)
#   3. Homebrew                   (package manager for the remaining tools)
#   4. Git
#   5. Clang C++ compiler         (Apple Clang from the Command Line Tools)
#   6. CMake
#   7. Ninja
#   8. Debugger                   (LLDB, optional)
#   9. Visual Studio Code         (plus the IB9JHO extensions)
#  10. End-to-end test            (configure, build, run and test a CMake project)
#
# Every step is followed by a test that proves the tool works, and every
# failure is reported with specific advice. All commands and their full output
# are written to a timestamped log file so that an instructor can see exactly
# where and why the setup failed.
#
# Apple Clang is used rather than Homebrew's LLVM: it is always present once
# the Command Line Tools are installed, needs no PATH changes and links against
# the system C++ library without extra flags.
#
# Usage:
#   bash setup-macos.sh [options]
#
#   --check-only      Diagnose only; do not install or change anything.
#   --skip-vscode     Skip Visual Studio Code and its extensions.
#   --project DIR     Additionally configure and build the CMake project in DIR
#                     using its "clang" preset.
#   --log-file FILE   Write the log to FILE instead of the default location.
#   --yes             Never prompt; assume "yes" for every question.
#   --help            Show this help and exit.
#
# Exit status: 0 when every required check passed (warnings are allowed),
# 1 when at least one required check failed, 2 on invalid usage.
#
# This script deliberately targets the Bash 3.2 that ships with macOS.

set -o pipefail

readonly SCRIPT_NAME="IB9JHO environment setup (macOS)"
readonly SCRIPT_VERSION="1.0.0"
readonly MIN_CMAKE_VERSION="3.21"
readonly MIN_MACOS_MAJOR=13
readonly MIN_FREE_DISK_MB=5120
readonly HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
readonly VSCODE_APP="/Applications/Visual Studio Code.app"
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
        echo "See the header of scripts/setup-macos.sh in the IB9JHO environment-setup repository."
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
COMPILER_OK=0

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

# Return success when the current step has already recorded a result.
step_has_result() {
    local count=${#RESULT_NAMES[@]}
    [[ $count -gt 0 && "${RESULT_NAMES[$((count - 1))]}" == "$CURRENT_STEP" ]]
}

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

# Return success when dotted version $1 is greater than or equal to $2.
version_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, ".");
        n = (na > nb) ? na : nb;
        for (i = 1; i <= n; i++) {
            if ((x[i] + 0) > (y[i] + 0)) exit 0;
            if ((x[i] + 0) < (y[i] + 0)) exit 1;
        }
        exit 0
    }'
}

# Extract the first dotted version number (e.g. 3.28.3) from a string.
extract_version() {
    printf '%s\n' "$1" | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n1
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
        SDKROOT DEVELOPER_DIR HOMEBREW_PREFIX http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy; do
        [[ -n "${!var}" ]] && log "$var=${!var}"
    done
    local tool
    for tool in brew git clang clang++ cmake ninja lldb code; do
        log "which -a $tool: $(type -a -p "$tool" 2>/dev/null | tr '\n' ' ')"
    done
    log "xcode-select -p: $(xcode-select -p 2>&1)"
    log "---- end of snapshot ----"
}

# Obtain (and cache) administrator rights for the steps that need them.
ensure_sudo() {
    if sudo -n true 2> /dev/null; then
        return 0
    fi
    info "Administrator rights are needed for this step; enter your Mac login password if asked."
    sudo -v
}

# ----------------------------------------------------------------------------
# Step 1: pre-flight checks
# ----------------------------------------------------------------------------

ARCH=""
BREW_PREFIX=""

step_preflight() {
    begin_step "Pre-flight checks"

    if [[ "$(uname -s)" != "Darwin" ]]; then
        fail "This script is for macOS, but this system reports '$(uname -s)'."
        advise "Use setup-linux.sh on Linux or setup-windows.ps1 on Windows."
        return 1
    fi

    local product_version major
    product_version="$(sw_vers -productVersion 2>/dev/null)"
    major="${product_version%%.*}"
    ARCH="$(uname -m)"
    info "System: macOS $product_version ($(sw_vers -buildVersion 2>/dev/null)), $ARCH"
    info "User: $(id -un), shell: ${SHELL:-unknown}"
    info "Script: $SCRIPT_NAME $SCRIPT_VERSION$([[ $CHECK_ONLY -eq 1 ]] && echo ' (check-only mode)')"
    log_environment_snapshot

    if [[ -n "$major" && "$major" -lt $MIN_MACOS_MAJOR ]]; then
        warn "macOS $product_version is old; Homebrew and current Xcode tools may not support it."
        advise "Update macOS (System Settings > General > Software Update) to version $MIN_MACOS_MAJOR or newer if your Mac allows it."
    fi

    # A Terminal running under Rosetta on Apple Silicon would install an Intel
    # copy of Homebrew into /usr/local and produce Intel binaries.
    if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" == "1" ]]; then
        ARCH="arm64"
        warn "This terminal is running under Rosetta (Intel emulation) on an Apple Silicon Mac."
        advise "Quit Terminal, open Finder > Applications > Utilities, select Terminal, choose File > Get Info, untick 'Open using Rosetta', then re-run the script."
    fi
    if [[ "$ARCH" == "arm64" ]]; then
        BREW_PREFIX="/opt/homebrew"
    else
        BREW_PREFIX="/usr/local"
    fi

    if ! id -Gn | tr ' ' '\n' | grep -qx admin; then
        warn "Your macOS account is not an administrator; Homebrew cannot be installed without one."
        advise "Ask the owner of the Mac to make your account an administrator (System Settings > Users & Groups), or to run this script for you."
    fi

    local free_mb
    free_mb="$(df -Pm "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -n "$free_mb" && "$free_mb" -lt $MIN_FREE_DISK_MB ]]; then
        warn "Only ${free_mb} MB free; at least ${MIN_FREE_DISK_MB} MB is recommended."
        advise "Free up disk space before installing; the Command Line Tools, Homebrew and VS Code need several GB."
    else
        info "Free disk space: ${free_mb:-unknown} MB"
    fi

    if [[ $CHECK_ONLY -eq 0 ]]; then
        if run curl -fsSL --max-time 20 -o /dev/null https://github.com; then
            info "Network: github.com is reachable."
        else
            show_last_output 5
            warn "Cannot reach https://github.com; installs and cloning repositories may fail."
            advise "Check your internet connection. On university or corporate networks, make sure any proxy is configured (System Settings > Network) and exported as https_proxy in the terminal."
        fi
    fi

    step_has_result || pass "Pre-flight checks completed."
}

# ----------------------------------------------------------------------------
# Step 2: Xcode Command Line Tools
# ----------------------------------------------------------------------------

# Return success when the Command Line Tools (or full Xcode) are usable.
clt_ready() {
    xcode-select -p > /dev/null 2>&1 && xcrun --find clang++ > /dev/null 2>&1
}

# Install the Command Line Tools without the GUI dialogue, using the same
# softwareupdate mechanism as the Homebrew installer.
install_clt_headless() {
    local marker="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    ensure_sudo || return 1
    touch "$marker"
    run softwareupdate -l
    local label
    label="$(grep -B 1 -E 'Command Line Tools' "$CMD_OUTPUT_FILE" \
        | awk -F'*' '/^ *\*/ {print $2}' \
        | sed -e 's/^ *Label: //' -e 's/^ *//' \
        | sort | tail -n1)"
    if [[ -z "$label" ]]; then
        rm -f "$marker"
        info "softwareupdate did not offer the Command Line Tools."
        return 1
    fi
    info "Installing '$label' (this can take 5-15 minutes)."
    run sudo softwareupdate -i "$label" --verbose
    local status=$?
    rm -f "$marker"
    [[ $status -eq 0 ]] && run sudo xcode-select --switch /Library/Developer/CommandLineTools
    return $status
}

step_clt() {
    begin_step "Xcode Command Line Tools"

    if ! clt_ready && [[ $CHECK_ONLY -eq 0 ]]; then
        if ! install_clt_headless; then
            show_last_output
            info "Falling back to the graphical installer."
            xcode-select --install > /dev/null 2>&1
            fail "The Command Line Tools are not installed yet."
            advise "A window titled 'Install Command Line Developer Tools' should have opened. Click Install, wait for it to finish, then re-run this script."
            return 1
        fi
    fi

    if ! clt_ready; then
        run xcode-select -p
        fail "The Xcode Command Line Tools are missing or broken."
        if grep -qi 'invalid active developer path' "$CMD_OUTPUT_FILE"; then
            advise "This usually happens after a macOS upgrade. Run: xcode-select --install  (or if that says they are installed: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install)."
        else
            advise "Run: xcode-select --install  and follow the dialogue, then re-run this script."
        fi
        return 1
    fi

    run clang++ --version
    if grep -qi 'agree.*license' "$CMD_OUTPUT_FILE"; then
        fail "The Xcode licence has not been accepted, so the compiler refuses to run."
        advise "Run: sudo xcodebuild -license accept  then re-run this script."
        return 1
    fi

    local sdk
    sdk="$(xcrun --show-sdk-path 2>/dev/null)"
    if [[ -z "$sdk" || ! -d "$sdk" ]]; then
        fail "The macOS SDK could not be found (xcrun --show-sdk-path)."
        advise "Reinstall the Command Line Tools: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
        return 1
    fi
    pass "Installed at $(xcode-select -p) (SDK: $sdk)."
}

# ----------------------------------------------------------------------------
# Step 3: Homebrew
# ----------------------------------------------------------------------------

# Make sure future terminals (zsh and bash login shells) can find Homebrew.
persist_brew_shellenv() {
    local line="eval \"\$($BREW_PREFIX/bin/brew shellenv)\""
    local profile
    for profile in "$HOME/.zprofile" "$HOME/.bash_profile"; do
        # Only touch bash_profile when bash is the user's shell or it exists.
        if [[ "$profile" == *bash_profile && "${SHELL:-}" != */bash && ! -f "$profile" ]]; then
            continue
        fi
        if ! grep -qs "brew shellenv" "$profile"; then
            if [[ $CHECK_ONLY -eq 1 ]]; then
                warn "Homebrew is not set up in $profile, so new terminals will not find it."
                advise "Add this line to $profile: $line"
            else
                printf '\n# Homebrew (added by the IB9JHO setup script)\n%s\n' "$line" >> "$profile"
                info "Added Homebrew to $profile."
            fi
        fi
    done
}

step_homebrew() {
    begin_step "Homebrew"

    if [[ -x "$BREW_PREFIX/bin/brew" ]]; then
        eval "$("$BREW_PREFIX/bin/brew" shellenv)"
    elif command -v brew > /dev/null 2>&1; then
        BREW_PREFIX="$(brew --prefix)"
        if [[ "$ARCH" == "arm64" && "$BREW_PREFIX" == "/usr/local" ]]; then
            warn "Only an Intel (Rosetta) copy of Homebrew was found in /usr/local on this Apple Silicon Mac."
            advise "Install the native Homebrew in /opt/homebrew (re-run this script from a non-Rosetta terminal) to avoid mixing Intel and Apple Silicon tools."
        fi
    elif [[ $CHECK_ONLY -eq 1 ]]; then
        fail "Homebrew is not installed."
        advise "Run this script without --check-only to install Homebrew, or follow https://brew.sh."
        return 1
    else
        info "Installing Homebrew (you may be asked for your password)."
        ensure_sudo || true
        local installer="$WORK_DIR/install-homebrew.sh"
        if ! run curl -fsSL --retry 3 -o "$installer" "$HOMEBREW_INSTALL_URL"; then
            show_last_output 5
            fail "Could not download the Homebrew installer."
            advise "Check that https://raw.githubusercontent.com is reachable from this network, then re-run the script."
            return 1
        fi
        if ! run env NONINTERACTIVE=1 /bin/bash "$installer"; then
            show_last_output 20
            fail "The Homebrew installer failed."
            if grep -qi 'need sudo access\|insufficient permissions\|not an administrator' "$CMD_OUTPUT_FILE"; then
                advise "Homebrew must be installed from an administrator account. Ask the owner of the Mac to make your account an administrator."
            else
                advise "Read the installer output above (full output in the log). You can also install Homebrew by following https://brew.sh, then re-run this script."
            fi
            return 1
        fi
        eval "$("$BREW_PREFIX/bin/brew" shellenv)"
    fi

    if ! run brew --version; then
        show_last_output
        fail "brew is installed but does not run."
        advise "Try 'brew update-reset'. If that fails, reinstall Homebrew following https://brew.sh."
        return 1
    fi
    local version
    version="$(extract_version "$(head -n1 "$CMD_OUTPUT_FILE")")"
    persist_brew_shellenv

    # 'brew doctor' warnings are informative only; keep them in the log.
    run brew doctor > /dev/null 2>&1 || info "'brew doctor' reported warnings (see the log); these rarely matter."
    step_has_result || pass "Homebrew $version ($BREW_PREFIX)."
}

# Install a Homebrew formula (or cask with --cask) unless in check-only mode.
brew_install() {
    if [[ $CHECK_ONLY -eq 1 ]]; then
        info "Check-only mode: not installing ($*)."
        return 1
    fi
    if ! command -v brew > /dev/null 2>&1; then
        info "Homebrew is unavailable; cannot install ($*)."
        return 1
    fi
    info "Installing with Homebrew: $*"
    if ! run env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install "$@"; then
        show_last_output
        advise "'brew install $*' failed. Read the output above; 'brew update' followed by a retry often helps, and 'brew doctor' lists common problems."
        return 1
    fi
    hash -r
}

# ----------------------------------------------------------------------------
# Step 4: Git
# ----------------------------------------------------------------------------

step_git() {
    begin_step "Git"

    if ! command -v git > /dev/null 2>&1 || ! git --version > /dev/null 2>&1; then
        brew_install git || true
    fi
    if ! run git --version; then
        show_last_output
        fail "git is not available."
        advise "Git comes with the Xcode Command Line Tools; fix that step first, or run 'brew install git'."
        return 1
    fi
    local version
    version="$(extract_version "$(cat "$CMD_OUTPUT_FILE")")"

    local repo="$WORK_DIR/git-test"
    if run git init -q "$repo" \
        && run git -C "$repo" -c user.name="IB9JHO Setup" -c user.email="setup@example.invalid" \
            commit -q --allow-empty -m "setup test"; then
        pass "git $version works ($(command -v git))."
    else
        show_last_output
        fail "git $version is installed but could not create a test commit."
        advise "Check your Git configuration for errors with 'git config --list --show-origin'."
        return 1
    fi

    if [[ -z "$(git config --global user.name 2>/dev/null)" || -z "$(git config --global user.email 2>/dev/null)" ]]; then
        warn "Your Git name and email are not configured, so commits will fail."
        advise "Run: git config --global user.name \"Your Name\"  and  git config --global user.email \"you@example.com\" (use the email of your GitHub account)."
    fi
}

# ----------------------------------------------------------------------------
# Step 5: Clang C++ compiler
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

step_compiler() {
    begin_step "Clang C++ compiler"

    if ! command -v clang++ > /dev/null 2>&1; then
        fail "clang++ is not on PATH."
        advise "clang++ comes with the Xcode Command Line Tools; fix that step first."
        return 1
    fi
    local compiler
    compiler="$(command -v clang++)"
    run clang++ --version
    local version
    version="$(head -n1 "$CMD_OUTPUT_FILE")"
    info "Found: $version ($compiler)"
    if [[ "$compiler" != "/usr/bin/clang++" ]]; then
        info "Note: this is not Apple Clang (/usr/bin/clang++); CMake will use this one because it is first on PATH."
    fi

    local source="$WORK_DIR/compiler-test.cpp" binary="$WORK_DIR/compiler-test"
    write_cpp_test_program "$source"

    if ! run clang++ -std=c++20 -Wall -Wextra -o "$binary" "$source"; then
        show_last_output
        fail "clang++ could not compile a C++20 test program."
        if [[ "$compiler" != "/usr/bin/clang++" ]]; then
            advise "A non-Apple clang++ ($compiler) is first on PATH, probably from an earlier Homebrew LLVM setup. Remove the line adding it to PATH from ~/.zprofile or ~/.zshrc, open a new terminal and re-run the script."
        elif grep -qiE "file not found|no such file|sdk" "$CMD_OUTPUT_FILE"; then
            advise "The macOS SDK or C++ headers are missing. Reinstall the Command Line Tools: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
        else
            advise "Read the compiler error above and send the log file to your instructor."
        fi
        return 1
    fi
    if ! run "$binary"; then
        show_last_output
        fail "The test program compiled but did not run correctly."
        advise "Send the log file to your instructor; security software may be blocking newly built programs."
        return 1
    fi
    COMPILER_OK=1
    pass "$(extract_version "$version") compiles and runs C++20 code ($compiler)."
}

# ----------------------------------------------------------------------------
# Steps 6 and 7: CMake and Ninja
# ----------------------------------------------------------------------------

step_cmake() {
    begin_step "CMake"

    if ! command -v cmake > /dev/null 2>&1; then
        brew_install cmake || true
    fi
    if ! command -v cmake > /dev/null 2>&1; then
        fail "cmake is not installed."
        if [[ -x "/Applications/CMake.app/Contents/bin/cmake" ]]; then
            advise "CMake.app is installed but its command-line tools are not on PATH. Either run 'brew install cmake', or run: sudo \"/Applications/CMake.app/Contents/bin/cmake-gui\" --install"
        else
            advise "Install CMake with 'brew install cmake'."
        fi
        return 1
    fi
    if ! run cmake --version; then
        show_last_output
        fail "cmake is installed at $(command -v cmake) but does not run."
        advise "Reinstall it with 'brew reinstall cmake'."
        return 1
    fi
    local version
    version="$(extract_version "$(head -n1 "$CMD_OUTPUT_FILE")")"
    if version_ge "$version" "$MIN_CMAKE_VERSION"; then
        pass "cmake $version ($(command -v cmake))."
    else
        fail "cmake $version is too old; version $MIN_CMAKE_VERSION or newer is required for CMake presets."
        advise "Upgrade CMake with 'brew upgrade cmake' (or 'brew install cmake' if it came from elsewhere)."
        return 1
    fi
}

step_ninja() {
    begin_step "Ninja build system"

    if ! command -v ninja > /dev/null 2>&1; then
        brew_install ninja || true
    fi
    if ! command -v ninja > /dev/null 2>&1; then
        fail "ninja is not installed."
        advise "Install Ninja with 'brew install ninja'."
        return 1
    fi
    if run ninja --version; then
        pass "ninja $(head -n1 "$CMD_OUTPUT_FILE") ($(command -v ninja))."
    else
        show_last_output
        fail "ninja is installed at $(command -v ninja) but does not run."
        advise "Reinstall it with 'brew reinstall ninja'."
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Step 8: debugger (optional)
# ----------------------------------------------------------------------------

step_debugger() {
    begin_step "Debugger (LLDB, optional)"

    if command -v lldb > /dev/null 2>&1 && run lldb --version; then
        pass "$(head -n1 "$CMD_OUTPUT_FILE")."
    else
        warn "LLDB is not available; building and testing will work, but debugging in VS Code will not."
        advise "LLDB comes with the Xcode Command Line Tools; reinstalling them restores it."
    fi
}

# ----------------------------------------------------------------------------
# Step 9: Visual Studio Code and extensions
# ----------------------------------------------------------------------------

CODE_CLI=""

# Locate the VS Code command-line launcher, even when it is not on PATH.
find_code_cli() {
    local candidate
    for candidate in "$(command -v code 2>/dev/null)" \
        "$VSCODE_APP/Contents/Resources/app/bin/code" \
        "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            CODE_CLI="$candidate"
            return 0
        fi
    done
    return 1
}

step_vscode() {
    begin_step "Visual Studio Code"

    if [[ $SKIP_VSCODE -eq 1 ]]; then
        skip "Skipped (--skip-vscode)."
        return 0
    fi

    if ! find_code_cli; then
        brew_install --cask visual-studio-code || true
        find_code_cli || true
    fi
    if [[ -z "$CODE_CLI" ]]; then
        fail "Visual Studio Code is not installed."
        advise "Install it with 'brew install --cask visual-studio-code', or download it from https://code.visualstudio.com and drag it into the Applications folder."
        return 1
    fi

    if ! run "$CODE_CLI" --version; then
        show_last_output
        fail "VS Code is installed but its command-line launcher does not run ($CODE_CLI)."
        advise "Reinstall VS Code with 'brew reinstall --cask visual-studio-code'."
        return 1
    fi
    local version
    version="$(head -n1 "$CMD_OUTPUT_FILE")"
    if command -v code > /dev/null 2>&1; then
        pass "VS Code $version ($CODE_CLI)."
    else
        warn "VS Code $version is installed, but the 'code' command is not on PATH."
        advise "In VS Code press Cmd+Shift+P and run 'Shell Command: Install 'code' command in PATH'."
    fi
    if [[ "$CODE_CLI" == *"/Downloads/"* ]]; then
        warn "VS Code is running from the Downloads folder, which breaks updates and the 'code' command."
        advise "Move 'Visual Studio Code' from Downloads into the Applications folder."
    fi

    begin_step "VS Code extensions"
    local extension missing=()
    for extension in "${VSCODE_EXTENSIONS[@]}"; do
        if [[ $CHECK_ONLY -eq 0 ]]; then
            run "$CODE_CLI" --install-extension "$extension" --force || show_last_output 5
        fi
    done
    run "$CODE_CLI" --list-extensions
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
# Step 10: end-to-end CMake test
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
    if [[ $COMPILER_OK -eq 0 ]]; then
        fail "Not run, because Clang cannot compile programs yet (see the compiler step above)."
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
    if [[ $COMPILER_OK -eq 0 ]] || ! command -v cmake > /dev/null 2>&1; then
        fail "Not run, because CMake or a working Clang is missing (see the steps above)."
        return 1
    fi
    # Build in a temporary folder so the student's own build folder (and its
    # cache) is never touched, even in check-only mode.
    local build_dir="$WORK_DIR/project-build"
    local configure_args=(--preset clang -B "$build_dir")
    if [[ ! -f "$PROJECT_DIR/CMakePresets.json" ]]; then
        warn "The project has no CMakePresets.json; using equivalent command-line settings."
        advise "Copy CMakePresets.json from the IB9JHO environment-setup repository into the project so VS Code picks Clang and Ninja automatically."
        configure_args=(-S . -B "$build_dir" -G Ninja -DCMAKE_BUILD_TYPE=Debug -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++)
    fi
    if ! (cd "$PROJECT_DIR" && run cmake "${configure_args[@]}"); then
        show_last_output 25
        fail "The project did not configure."
        advise_configure_failure
        return 1
    fi
    if ! (cd "$PROJECT_DIR" && run cmake --build "$build_dir"); then
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
    for ((i = 0; i < ${#RESULT_NAMES[@]}; i++)); do
        case "${RESULT_STATUSES[$i]}" in
            PASS) colour="$C_GREEN" ;;
            WARN) colour="$C_YELLOW"; warnings=$((warnings + 1)) ;;
            SKIP) colour="$C_YELLOW" ;;
            *) colour="$C_RED"; failures=$((failures + 1)) ;;
        esac
        printf '  %s%-4s%s  %-42s %s\n' "$colour" "${RESULT_STATUSES[$i]}" "$C_RESET" "${RESULT_NAMES[$i]}" "${RESULT_DETAILS[$i]}"
        log "${RESULT_STATUSES[$i]}  ${RESULT_NAMES[$i]}: ${RESULT_DETAILS[$i]}"
    done

    if [[ ${#ADVICE[@]} -gt 0 ]]; then
        printf '\n%sWhat to do next:%s\n' "$C_BOLD" "$C_RESET"
        for ((i = 0; i < ${#ADVICE[@]}; i++)); do
            printf '  - %s\n' "${ADVICE[$i]}"
        done
    fi

    printf '\nFull log: %s\n' "$LOG_FILE"
    if [[ $failures -eq 0 ]]; then
        say "${C_GREEN}${C_BOLD}Your IB9JHO environment is ready${C_RESET}$([[ $warnings -gt 0 ]] && echo " ($warnings warning(s) above)")."
        say "Open a course repository in VS Code and select the 'Clang (IB9JHO)' preset when asked."
        [[ $CHECK_ONLY -eq 0 ]] && say "If 'brew', 'code' or 'cmake' are not found in an existing terminal, open a new terminal window."
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
    if [[ $CHECK_ONLY -eq 0 ]] && ! confirm "Install any missing IB9JHO tools now?"; then
        CHECK_ONLY=1
        info "Continuing in check-only mode."
    fi

    step_clt || true
    step_homebrew || true
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
