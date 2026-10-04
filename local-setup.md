# Setting Up a Local IB9JHO Environment for C++ Programming

This guide sets up everything you need to write, build and test C++ for IB9JHO on your own computer: **Git**, the **Clang** compiler, **CMake**, **Ninja** and **Visual Studio Code** with the course extensions.

A setup script does all of this for you. It installs whatever is missing, tests every tool as it goes and finishes by building a small C++20 program, so when it reports success you know your environment works.

## 1. Run the setup script

Pick your operating system and copy the commands into a terminal. The script is safe to run more than once: anything already installed is checked, not reinstalled.

### Windows

Open **PowerShell** (Start menu, type *PowerShell*, press Enter; administrator mode is not needed) and run:

```powershell
cd $HOME
irm https://raw.githubusercontent.com/IB9JHO-2026-2027/IB9JHO-environment-setup/main/scripts/setup-windows.ps1 -OutFile setup-windows.ps1
powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1
```

Windows will ask for permission (a *User Account Control* prompt) when an installer needs it; click **Yes**. Installing the Visual Studio Build Tools can take 10-30 minutes.

### macOS

Open **Terminal** (Finder > Applications > Utilities > Terminal) and run:

```bash
cd ~
curl -fsSL https://raw.githubusercontent.com/IB9JHO-2026-2027/IB9JHO-environment-setup/main/scripts/setup-macos.sh -o setup-macos.sh
bash setup-macos.sh
```

Enter your Mac login password when asked (nothing appears as you type). Your account must be an administrator account.

### Linux

Open a terminal and run:

```bash
cd ~
curl -fsSL https://raw.githubusercontent.com/IB9JHO-2026-2027/IB9JHO-environment-setup/main/scripts/setup-linux.sh -o setup-linux.sh
bash setup-linux.sh
```

Ubuntu, Debian, Fedora, Arch and openSUSE are supported. If `curl` is not installed, use `wget -O setup-linux.sh <url>` instead. On **WSL**, run the Linux script inside WSL and the Windows script on Windows (VS Code itself lives on Windows).

### When it finishes

The script ends with a summary like this:

```
==> Summary
  PASS  Git                          git 2.47.1 works (/usr/bin/git).
  PASS  Clang C++ compiler           clang++ 18.1.3 compiles and runs C++20 code.
  PASS  CMake                        cmake 3.31.2 (/usr/bin/cmake).
  ...
Your IB9JHO environment is ready.
```

- **Everything passed:** close and reopen any terminals and VS Code windows (so they see the newly installed tools), then go to [Check your environment works](README.md#check-your-environment-works).
- **Something failed:** the *What to do next* list under the summary says how to fix each problem. Fix it and run the script again.
- **Still stuck:** send the log file named at the end of the output (`ib9jho-setup-<date>-<time>.log` in your home folder) to your instructor.

### Script options

| Windows | macOS / Linux | Effect |
| --- | --- | --- |
| `-CheckOnly` | `--check-only` | Diagnose only; install and change nothing. |
| `-SkipVSCode` | `--skip-vscode` | Skip VS Code and its extensions. |
| `-Project <folder>` | `--project <folder>` | Also build the CMake project in that folder. |
| `-LogFile <file>` | `--log-file <file>` | Write the log somewhere else. |
| `-Yes` | `--yes` | Never ask questions. |

## 2. Open a project in VS Code

IB9JHO repositories contain a `CMakePresets.json` file that tells VS Code to build with Clang and Ninja. There are **no settings files to copy**.

1. Open the repository folder in VS Code (*File > Open Folder...*).
2. If VS Code asks whether you trust the authors, choose **Yes**.
3. When the CMake extension asks you to **select a configure preset**, choose **Clang (IB9JHO)**. You can change it later from the CMake tab.

If you used an earlier version of these instructions, delete any `.vscode/settings.json` you created in your course repositories: its old compiler paths can override the preset.

## What the script installs

| Tool | Windows | macOS | Linux |
| --- | --- | --- | --- |
| Package manager | WinGet (built into Windows) | Homebrew | apt / dnf / pacman / zypper |
| Git | Git for Windows | Xcode Command Line Tools | distribution package |
| C++ compiler | LLVM Clang, using the Visual Studio Build Tools' libraries and linker | Apple Clang (Xcode Command Line Tools) | Clang with the GCC standard library |
| Build tools | CMake, Ninja | CMake, Ninja | CMake, Ninja |
| Debugger | included in the VS Code C/C++ extension | LLDB | GDB |
| Editor | VS Code | VS Code | VS Code (official .deb/.rpm) |

VS Code extensions: `ms-vscode.cpptools`, `ms-vscode.cpptools-extension-pack`, `ms-vscode.cmake-tools`, `brobeson.ctest-lab` and `github.vscode-github-actions`.

After each installation the script runs a test (for example, compiling and running a C++20 program, or making a Git commit in a temporary folder). The last step configures, builds and tests a small CMake project with the same preset VS Code uses.

## Installing manually

Use these commands only if you cannot run the script. Afterwards, run the script with `--check-only` (`-CheckOnly` on Windows) to confirm everything works.

**Windows** (PowerShell):

```powershell
winget install --id Git.Git -e
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--wait --quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
winget install --id LLVM.LLVM -e
winget install --id Kitware.CMake -e
winget install --id Ninja-build.Ninja -e
winget install --id Microsoft.VisualStudioCode -e
```

Then make sure `C:\Program Files\LLVM\bin` and `C:\Program Files\CMake\bin` are on your PATH.

**macOS** (Terminal):

```bash
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install cmake ninja
brew install --cask visual-studio-code
```

**Ubuntu / Debian**:

```bash
sudo apt update
sudo apt install git clang build-essential cmake ninja-build gdb
```

Install VS Code from <https://code.visualstudio.com/download> and the extensions listed above from its Extensions tab.

## For instructors: diagnosing a failed setup

Ask the student for their log file (or run the script on their machine with `--check-only`, which changes nothing). The log is plain text:

- `STEP` lines mark the start of each stage, in the order listed in the summary.
- `$` lines are the exact commands run, followed by their complete output and an `[exit status N]` line.
- `PASS`, `WARN`, `FAIL` and `ADVICE` lines record each result and the advice shown to the student.
- An *environment snapshot* records `PATH`, compiler-related variables and every copy of each tool found on `PATH`, which exposes most "wrong tool picked up" problems.

To test a specific student repository, add `--project <folder>` (`-Project <folder>`): the script builds it with the same preset after checking the tool chain, separating tool problems from code problems.

Common problems the script recognises and explains:

| Symptom in the log | Cause | Fix |
| --- | --- | --- |
| `STL1000: Unexpected compiler version` (Windows) | LLVM is older than the MSVC standard library supports | `winget upgrade --id LLVM.LLVM` |
| `LNK1104: cannot open file 'kernel32.lib'` (Windows) | Windows SDK missing | Visual Studio Installer > Modify > tick a Windows 11 SDK |
| A tool resolves to `msys64`, `mingw` or `cygwin` (Windows) | Another tool chain earlier on `PATH` | Move or remove that `PATH` entry |
| `xcrun: error: invalid active developer path` (macOS) | Command Line Tools removed by a macOS upgrade | `xcode-select --install` |
| `You have not agreed to the Xcode license` (macOS) | Full Xcode installed but licence not accepted | `sudo xcodebuild -license accept` |
| `'iostream' file not found` (Linux) | Clang picked a GCC version whose `libstdc++` headers are missing | The script installs `libstdc++-<N>-dev` automatically; otherwise install it by hand |
| `Could not get lock /var/lib/dpkg/lock` (Linux) | The automatic updater is running | Wait or restart, then re-run |

The scripts are tested automatically on Windows, macOS (Apple Silicon and Intel) and several Linux distributions by the *Environment setup scripts* GitHub Actions workflow, which also runs monthly to catch upstream changes.
