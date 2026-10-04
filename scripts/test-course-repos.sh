#!/usr/bin/env bash
#
# Build and test IB9JHO course repositories with the standard tool chain.
#
# Every repository directory given on the command line is configured with
# Clang and Ninja (using its CMakePresets.json "clang" preset when present,
# or the equivalent settings otherwise), built, and tested with CTest.
# Benchmarks are never run: CTest tests whose name or label contains "bench"
# are excluded, because they are slow, timing-dependent and not pass/fail.
#
# Usage:
#   bash test-course-repos.sh [--log-dir DIR] REPO_DIR...
#
# A summary table is printed at the end (and appended to the GitHub Actions
# job summary when GITHUB_STEP_SUMMARY is set). Full output for each
# repository is written to DIR/<repository>.log (default: ./course-repo-logs).
#
# Exit status: 0 when every repository built and passed its tests, 1 otherwise.

set -o pipefail
set -o nounset

# CTest regular expression for tests (and labels) that are benchmarks.
readonly BENCHMARK_PATTERN='[Bb][Ee][Nn][Cc][Hh]'

LOG_DIR="$PWD/course-repo-logs"
REPOS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --log-dir)
            [[ $# -ge 2 ]] || { echo "error: --log-dir requires a directory" >&2; exit 2; }
            LOG_DIR="$2"; shift ;;
        -h | --help) sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) REPOS+=("$1") ;;
    esac
    shift
done
if [[ ${#REPOS[@]} -eq 0 ]]; then
    echo "error: no repository directories given (use --help)" >&2
    exit 2
fi
mkdir -p "$LOG_DIR"
# Commands run inside each repository, so every path must be absolute.
LOG_DIR="$(cd "$LOG_DIR" && pwd)"

NAMES=()
RESULTS=()
DETAILS=()

# Record the outcome for one repository.
record() {
    NAMES+=("$1")
    RESULTS+=("$2")
    DETAILS+=("$3")
    printf '  [%s] %s\n' "$2" "$3"
}

# Run a command in the current directory, appending its output to the log.
run() {
    printf '\n$ %s\n' "$*" >> "$LOG"
    "$@" >> "$LOG" 2>&1
}

# Show the end of a repository's log so the failure is visible in CI output.
show_log_tail() {
    echo "  --- last 30 lines of $LOG ---"
    tail -n 30 "$LOG" | sed 's/^/  | /'
}

test_repo() {
    local dir name
    dir="$(cd "$1" && pwd)" || { record "$(basename "$1")" FAIL "directory not found"; return 1; }
    name="$(basename "$dir")"
    LOG="$LOG_DIR/$name.log"
    : > "$LOG"
    echo
    echo "==> $name"

    if [[ ! -f "$dir/CMakeLists.txt" ]]; then
        record "$name" SKIP "no top-level CMakeLists.txt"
        return 0
    fi

    # The repositories' own tests expect executables in <repo>/build, so the
    # standard build folder is used (CI always starts from a fresh clone).
    local configure=(cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++)
    if [[ -f "$dir/CMakePresets.json" ]]; then
        configure=(cmake --preset clang)
    fi

    if ! (cd "$dir" && run "${configure[@]}"); then
        show_log_tail
        record "$name" FAIL "CMake configure failed"
        return 1
    fi
    if ! (cd "$dir" && run cmake --build build); then
        show_log_tail
        record "$name" FAIL "build failed"
        return 1
    fi

    local total benchmarks
    total="$(cd "$dir" && ctest --test-dir build -N 2>/dev/null | sed -n 's/^Total Tests: //p')"
    benchmarks="$(cd "$dir" && ctest --test-dir build -N -R "$BENCHMARK_PATTERN" 2>/dev/null | sed -n 's/^Total Tests: //p')"
    if [[ -z "$total" || "$total" -eq 0 ]]; then
        record "$name" PASS "built (no tests defined)"
        return 0
    fi
    if ! (cd "$dir" && run ctest --test-dir build --output-on-failure --timeout 300 \
        -E "$BENCHMARK_PATTERN" -LE "$BENCHMARK_PATTERN"); then
        show_log_tail
        record "$name" FAIL "tests failed (see $name.log)"
        return 1
    fi
    local note=""
    [[ "${benchmarks:-0}" -gt 0 ]] && note=", $benchmarks benchmark(s) skipped"
    record "$name" PASS "built and passed $((total - ${benchmarks:-0})) test(s)$note"
}

failures=0
for repo in "${REPOS[@]}"; do
    test_repo "$repo" || failures=$((failures + 1))
done

echo
echo "==> Summary"
for i in "${!NAMES[@]}"; do
    printf '  %-4s  %-32s %s\n' "${RESULTS[$i]}" "${NAMES[$i]}" "${DETAILS[$i]}"
done
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "### Course repositories ($(uname -s))"
        echo
        echo "| Result | Repository | Details |"
        echo "| --- | --- | --- |"
        for i in "${!NAMES[@]}"; do
            echo "| ${RESULTS[$i]} | ${NAMES[$i]} | ${DETAILS[$i]} |"
        done
    } >> "$GITHUB_STEP_SUMMARY"
fi

echo
echo "Logs: $LOG_DIR"
if [[ $failures -gt 0 ]]; then
    echo "$failures repository(ies) failed."
    exit 1
fi
echo "All repositories built and passed their tests."
