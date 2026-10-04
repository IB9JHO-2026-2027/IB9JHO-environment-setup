<#
.SYNOPSIS
    IB9JHO C++ development environment setup and diagnostics for Windows.

.DESCRIPTION
    Installs and verifies every tool needed to build IB9JHO coursework with
    Clang, CMake and Ninja in Visual Studio Code:

      1. Pre-flight checks        (Windows version, architecture, disk, network)
      2. WinGet package manager   (built into Windows 10 and 11)
      3. Git
      4. Visual Studio Build Tools (MSVC libraries, linker and Windows SDK,
                                   which Clang needs on Windows)
      5. LLVM / Clang C++ compiler
      6. CMake
      7. Ninja
      8. Visual Studio Code       (plus the IB9JHO extensions)
      9. End-to-end test          (configure, build, run and test a CMake project)

    Every step is followed by a test that proves the tool works, and every
    failure is reported with specific advice. All commands and their full
    output are written to a timestamped log file so that an instructor can see
    exactly where and why the setup failed.

    Tools that are installed but missing from PATH are added to the user PATH
    automatically, so that VS Code and CMake find them without any settings
    files. Debugging needs no extra tools on Windows: the C/C++ extension
    includes the Visual Studio debugger.

.PARAMETER CheckOnly
    Diagnose only; do not install or change anything.

.PARAMETER SkipVSCode
    Skip Visual Studio Code and its extensions.

.PARAMETER Project
    Additionally configure and build the CMake project in this folder using its
    "clang" preset.

.PARAMETER LogFile
    Write the log to this file instead of the default location.

.PARAMETER Yes
    Never prompt; assume "yes" for every question.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1 -CheckOnly -Project C:\code\my-assignment

.NOTES
    Exit status: 0 when every required check passed (warnings are allowed),
    1 when at least one required check failed.
    Compatible with Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$SkipVSCode,
    [string]$Project = '',
    [string]$LogFile = '',
    [switch]$Yes
)

$ScriptName = 'IB9JHO environment setup (Windows)'
$ScriptVersion = '1.0.0'
$MinCMakeVersion = [version]'3.21'
# The MSVC standard library shipped with current Visual Studio releases only
# accepts recent Clang versions (older ones fail with error STL1000).
$MinClangMajor = 19
$MinFreeDiskGB = 10
$VSCodeExtensions = @(
    'ms-vscode.cpptools',
    'ms-vscode.cpptools-extension-pack',
    'ms-vscode.cmake-tools',
    'brobeson.ctest-lab',
    'github.vscode-github-actions'
)

# WinGet exit codes that mean the package is already present or up to date.
$WingetOkCodes = @(
    0,
    -1978335189, # 0x8A15002B: no applicable update / already up to date
    -1978335135, # 0x8A150061: package already installed
    -1978335215  # 0x8A150011: installer reports another version already installed
)
# WinGet and installer exit codes that mean success but a restart is pending.
$RebootCodes = @(3010, 1641, -1978334967) # -1978334967 = 0x8A150109

$ProgramFilesX86 = ${env:ProgramFiles(x86)}
$VsWhere = Join-Path $ProgramFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
$VsInstaller = Join-Path $ProgramFilesX86 'Microsoft Visual Studio\Installer\setup.exe'

if (-not $LogFile) {
    $LogFile = Join-Path $HOME ("ib9jho-setup-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
try {
    $logDirectory = Split-Path -Parent $LogFile
    if ($logDirectory -and -not (Test-Path $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }
    Set-Content -Path $LogFile -Value '' -Encoding UTF8
}
catch {
    Write-Host "error: cannot write log file '$LogFile'; use -LogFile to choose another location" -ForegroundColor Red
    exit 2
}

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ib9jho-setup-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

$script:Results = New-Object System.Collections.Generic.List[object]
$script:Advice = New-Object System.Collections.Generic.List[string]
$script:CurrentStep = ''
$script:LastOutput = @()
$script:RestartRequired = $false

# ----------------------------------------------------------------------------
# Logging and result tracking
# ----------------------------------------------------------------------------

function Write-SetupLog {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Write-Info {
    param([string]$Message)
    Write-Host "  $Message"
    Write-SetupLog "INFO  $Message"
}

function Start-Step {
    param([string]$Title)
    $script:CurrentStep = $Title
    Write-Host ''
    Write-Host "==> $Title" -ForegroundColor Cyan
    Write-SetupLog ('=' * 64)
    Write-SetupLog "STEP  $Title"
    Write-SetupLog ('=' * 64)
}

# Record the outcome of the current step. Status is PASS, WARN, FAIL or SKIP.
function Add-Result {
    param([ValidateSet('PASS', 'WARN', 'FAIL', 'SKIP')][string]$Status, [string]$Detail)
    $colour = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
    Write-Host '  [' -NoNewline
    Write-Host $Status -ForegroundColor $colour -NoNewline
    Write-Host "] $Detail"
    Write-SetupLog "$Status  $($script:CurrentStep): $Detail"
    $script:Results.Add([pscustomobject]@{ Step = $script:CurrentStep; Status = $Status; Detail = $Detail })
}

# Return $true when the current step has already recorded a result.
function Test-StepHasResult {
    return ($script:Results.Count -gt 0 -and $script:Results[$script:Results.Count - 1].Step -eq $script:CurrentStep)
}

# Register a piece of advice for the summary, attributed to the current step.
function Add-Advice {
    param([string]$Text)
    $script:Advice.Add("[$($script:CurrentStep)] $Text")
    Write-SetupLog "ADVICE $Text"
}

# Run a native command, streaming its combined output to the log file. The
# output is also kept in $script:LastOutput for inspection. Returns the exit code.
function Invoke-Logged {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        # Also echo the output to the console (used for long installs, so the
        # student can see that something is happening).
        [switch]$Echo
    )
    Write-SetupLog ('$ "{0}" {1}' -f $FilePath, ($ArgumentList -join ' '))
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $captured = New-Object System.Collections.Generic.List[string]
    $exitCode = 0
    try {
        & $FilePath @ArgumentList 2>&1 | ForEach-Object {
            # Windows PowerShell 5.1 wraps each stderr line of a native command
            # in an ErrorRecord; recover the original text (blank lines would
            # otherwise appear as "System.Management.Automation.RemoteException").
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $line = if ($_.TargetObject -is [string]) { $_.TargetObject } else { $_.Exception.Message }
                if ($line -eq 'System.Management.Automation.RemoteException') { $line = '' }
            }
            else {
                $line = "$_"
            }
            $captured.Add($line)
            Add-Content -Path $LogFile -Value $line -Encoding UTF8
            if ($Echo -and $line.Trim() -and $line -notmatch '^[\s\-\\|/]+$') {
                Write-Host "    $line" -ForegroundColor DarkGray
            }
        }
        $exitCode = $LASTEXITCODE
    }
    catch {
        $captured.Add("$_")
        Add-Content -Path $LogFile -Value "$_" -Encoding UTF8
        $exitCode = -1
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($null -eq $exitCode) { $exitCode = 0 }
    $script:LastOutput = $captured.ToArray()
    Write-SetupLog "[exit status $exitCode]"
    return $exitCode
}

# Return $true when the most recent command's output matches the pattern.
function Test-LastOutput {
    param([string]$Pattern)
    return [bool]($script:LastOutput | Where-Object { $_ -match $Pattern } | Select-Object -First 1)
}

# Show the last lines of the most recent command's output on the console, so
# that the student sees the actual error without opening the log.
function Show-LastOutput {
    param([int]$Lines = 15)
    $tail = @($script:LastOutput | Where-Object { $_.Trim() } | Select-Object -Last $Lines)
    if ($tail.Count -eq 0) { return }
    Write-Host "  --- last $Lines lines of output ---" -ForegroundColor Yellow
    foreach ($line in $tail) { Write-Host "  | $line" }
    Write-Host '  --------------------------------' -ForegroundColor Yellow
}

# Extract the first dotted version number (e.g. 3.28.3) from text.
function Get-VersionFromText {
    param([string]$Text)
    if ($Text -match '(\d+\.\d+(\.\d+)?)') { return [version]$Matches[1] }
    return $null
}

function Confirm-Action {
    param([string]$Question)
    if ($Yes -or -not [Environment]::UserInteractive) { return $true }
    try {
        $reply = Read-Host "  $Question [Y/n]"
    }
    catch {
        return $true
    }
    return ([string]::IsNullOrWhiteSpace($reply) -or $reply -match '^[Yy]')
}

# Record every copy of each relevant tool on PATH; invaluable when diagnosing
# "wrong tool picked up" problems remotely.
function Write-ToolInventory {
    foreach ($tool in @('git', 'clang', 'clang++', 'cl', 'gcc', 'g++', 'cmake', 'ninja', 'code')) {
        $found = @(Get-Command $tool -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
        Write-SetupLog ("where {0}: {1}" -f $tool, ($found -join '; '))
    }
}

# ----------------------------------------------------------------------------
# PATH handling
# ----------------------------------------------------------------------------

# Rebuild this session's PATH from the registry so that tools installed during
# this run are found without opening a new terminal.
function Update-SessionPath {
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($source in @(
            [Environment]::GetEnvironmentVariable('Path', 'Machine'),
            [Environment]::GetEnvironmentVariable('Path', 'User'),
            $env:Path)) {
        if (-not $source) { continue }
        foreach ($entry in $source.Split(';')) {
            $trimmed = $entry.Trim()
            if ($trimmed -and -not $entries.Contains($trimmed)) { $entries.Add($trimmed) }
        }
    }
    $env:Path = $entries -join ';'
}

# Append a folder to the user's PATH permanently (preserving unexpanded
# %VARIABLES% in the existing value) and to the current session.
function Add-UserPath {
    param([string]$Directory)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $current = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $parts = @($current.Split(';') | Where-Object { $_ })
        if ($parts -notcontains $Directory) {
            $newValue = (@($parts) + $Directory) -join ';'
            $key.SetValue('Path', $newValue, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            Write-SetupLog "Added to user PATH: $Directory"
        }
    }
    finally {
        $key.Close()
    }
    # Setting (and removing) a user variable through .NET broadcasts the
    # WM_SETTINGCHANGE message, so newly started programs see the new PATH.
    [Environment]::SetEnvironmentVariable('IB9JHO_SETUP_REFRESH', '1', 'User')
    [Environment]::SetEnvironmentVariable('IB9JHO_SETUP_REFRESH', $null, 'User')
    if (($env:Path.Split(';')) -notcontains $Directory) { $env:Path = "$env:Path;$Directory" }
}

# Find a command on PATH. If it is missing but present in one of the known
# install folders, add that folder to the user PATH (or advise in check-only
# mode). Returns the full path of the command, or $null.
function Resolve-Tool {
    param([string]$Name, [string[]]$Candidates = @())
    Update-SessionPath
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }

    foreach ($directory in $Candidates) {
        if (-not $directory) { continue }
        foreach ($extension in @('.exe', '.cmd', '.bat', '')) {
            $path = Join-Path $directory ($Name + $extension)
            if (Test-Path $path -PathType Leaf) {
                if ($CheckOnly) {
                    Add-Result WARN "$Name is installed in '$directory' but that folder is not on PATH."
                    Add-Advice "Add '$directory' to your PATH (Start > 'Edit environment variables for your account' > Path > New), or re-run this script without -CheckOnly to do it automatically."
                    $env:Path = "$env:Path;$directory"
                }
                else {
                    Write-Info "Adding '$directory' to your user PATH."
                    Add-UserPath $directory
                }
                return $path
            }
        }
    }
    return $null
}

# Report tools that resolve to MSYS2, MinGW, Cygwin or Strawberry Perl copies,
# which shadow the IB9JHO tool chain and produce confusing errors.
function Test-ShadowingTool {
    param([string]$Name, [string]$Path)
    if ($Path -match '(?i)(msys|mingw|cygwin|strawberry)') {
        Add-Result WARN "$Name resolves to '$Path', which is not the IB9JHO tool chain."
        Add-Advice "Move the MSYS2/MinGW/Cygwin folder below the IB9JHO tools in your PATH, or remove it (Start > 'Edit environment variables for your account'), then open a new terminal."
    }
}

# ----------------------------------------------------------------------------
# WinGet helpers
# ----------------------------------------------------------------------------

$script:WingetPath = $null
$script:WingetInstallAdvised = $false

# Install a package with WinGet unless in check-only mode. Returns $true on
# success (including "already installed").
function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Override = '',
        [switch]$Upgrade
    )
    if ($CheckOnly) {
        Write-Info "Check-only mode: not installing $Id."
        return $false
    }
    if (-not $script:WingetPath) {
        Write-Info "WinGet is unavailable; cannot install $Id."
        return $false
    }
    $verb = if ($Upgrade) { 'upgrade' } else { 'install' }
    $arguments = @($verb, '--id', $Id, '--exact', '--source', 'winget',
        '--accept-package-agreements', '--accept-source-agreements', '--silent')
    if ($Override) { $arguments += @('--override', $Override) }

    Write-Info "Installing $Id with WinGet (a Windows permission prompt may appear)."
    Write-Info 'Large installers can run for 10-20 minutes with little or no progress shown; leave this window open.'
    $code = Invoke-Logged $script:WingetPath $arguments -Echo
    if ($RebootCodes -contains $code) {
        $script:RestartRequired = $true
        Write-Info "$Id was installed; Windows needs a restart to finish."
        return $true
    }
    if ($WingetOkCodes -contains $code) {
        Update-SessionPath
        return $true
    }

    Show-LastOutput
    if (-not $script:WingetInstallAdvised) {
        $script:WingetInstallAdvised = $true
        if (Test-LastOutput '(?i)cancel|1602|denied|0x80070005') {
            Add-Advice "An installation was cancelled or refused administrator rights. Re-run the script and click 'Yes' when Windows asks for permission."
        }
        elseif (Test-LastOutput '(?i)no package found|0x8a150014') {
            Add-Advice "WinGet could not find '$Id'. Run 'winget source reset --force' in an administrator terminal, then retry."
        }
        elseif (Test-LastOutput '(?i)internet|network|0x80072ee7|0x80072efd|download') {
            Add-Advice "A download failed. Check your internet connection and any proxy or firewall, then retry."
        }
        else {
            Add-Advice "WinGet failed to install '$Id' (exit code $code). The full installer output is in the log."
        }
    }
    return $false
}

# ----------------------------------------------------------------------------
# Step 1: pre-flight checks
# ----------------------------------------------------------------------------

$script:IsAdmin = $false
$script:Arch = 'x64'

function Invoke-PreflightStep {
    Start-Step 'Pre-flight checks'

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $build = [Environment]::OSVersion.Version.Build
    $script:Arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $script:IsAdmin = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    Write-Info ("System: {0} (build {1}), {2}" -f $(if ($os) { $os.Caption } else { 'Windows' }), $build, $script:Arch)
    Write-Info ("User: {0}, administrator: {1}" -f $env:USERNAME, $script:IsAdmin)
    Write-Info ("PowerShell {0}, execution policy {1}" -f $PSVersionTable.PSVersion, (Get-ExecutionPolicy))
    Write-Info ("Script: {0} {1}{2}" -f $ScriptName, $ScriptVersion, $(if ($CheckOnly) { ' (check-only mode)' } else { '' }))
    Write-SetupLog "PATH=$env:Path"
    foreach ($name in @('CC', 'CXX', 'CMAKE_GENERATOR', 'CMAKE_MAKE_PROGRAM', 'INCLUDE', 'LIB', 'VCINSTALLDIR', 'HTTP_PROXY', 'HTTPS_PROXY')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { Write-SetupLog "$name=$value" }
    }
    Write-ToolInventory
    Invoke-Logged 'netsh' @('winhttp', 'show', 'proxy') | Out-Null

    if ($build -lt 17763) {
        Add-Result FAIL "Windows build $build is too old; Windows 10 version 1809 (build 17763) or newer is required."
        Add-Advice 'Update Windows (Settings > Windows Update) before continuing.'
        return $false
    }
    if ($script:Arch -eq 'ARM64') {
        Add-Result WARN 'This is an ARM64 (e.g. Snapdragon) PC. The tools support it, but it is less tested.'
        Add-Advice 'If something fails on this ARM64 PC, send the log to your instructor; a GitHub Codespace is a reliable fallback.'
    }

    # Paths with spaces or non-ASCII characters break some build tools.
    if ($HOME -match '[^\x20-\x7E]') {
        Add-Result WARN "Your user folder '$HOME' contains non-ASCII characters, which some build tools cannot handle."
        Add-Advice 'Keep your coursework in a folder with a plain ASCII path such as C:\code\ib9jho.'
    }
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ($documents -match '(?i)onedrive') {
        Add-Advice "Your Documents folder is synchronised by OneDrive ($documents). Clone course repositories into a folder outside OneDrive, such as C:\code\ib9jho, to avoid locked files and sync conflicts."
    }

    $drive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($drive -and $drive.Free) {
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
        if ($freeGB -lt $MinFreeDiskGB) {
            Add-Result WARN "Only $freeGB GB free on $($env:SystemDrive); at least $MinFreeDiskGB GB is recommended."
            Add-Advice 'Free up disk space; the Visual Studio Build Tools alone need about 6 GB.'
        }
        else {
            Write-Info "Free disk space on $($env:SystemDrive): $freeGB GB"
        }
    }

    if (-not $CheckOnly) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri 'https://github.com' -UseBasicParsing -Method Get -TimeoutSec 20 | Out-Null
            Write-Info 'Network: github.com is reachable.'
        }
        catch {
            Write-SetupLog "Network check failed: $_"
            Add-Result WARN "Cannot reach https://github.com ($($_.Exception.Message)); installs and cloning may fail."
            Add-Advice 'Check your internet connection. On university or corporate networks, make sure the proxy is configured (Settings > Network & internet > Proxy).'
        }
        if (-not $script:IsAdmin) {
            Write-Info 'Not running as administrator: Windows will ask for permission when an installer needs it.'
        }
    }

    if (-not (Test-StepHasResult)) { Add-Result PASS 'Pre-flight checks completed.' }
    return $true
}

# ----------------------------------------------------------------------------
# Step 2: WinGet
# ----------------------------------------------------------------------------

function Invoke-WingetStep {
    Start-Step 'WinGet package manager'

    $winget = Resolve-Tool 'winget' @("$env:LOCALAPPDATA\Microsoft\WindowsApps")
    if (-not $winget -and -not $CheckOnly) {
        # Registering App Installer fixes WinGet on many freshly set-up PCs.
        Write-Info 'WinGet was not found; trying to register the App Installer package.'
        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
        }
        catch {
            Write-SetupLog "App Installer registration failed: $_"
        }
        $winget = Resolve-Tool 'winget' @("$env:LOCALAPPDATA\Microsoft\WindowsApps")
    }
    if (-not $winget) {
        Add-Result FAIL 'WinGet (the Windows Package Manager) is not available.'
        Add-Advice "Install or update 'App Installer' from the Microsoft Store (https://apps.microsoft.com/detail/9NBLGGH4NNS1), then re-run this script. On managed university PCs, ask IT or use a GitHub Codespace."
        return
    }
    if ((Invoke-Logged $winget @('--version')) -ne 0) {
        Show-LastOutput
        Add-Result FAIL "WinGet is installed ($winget) but does not run."
        Add-Advice "Update 'App Installer' from the Microsoft Store, then re-run this script."
        return
    }
    $script:WingetPath = $winget
    Add-Result PASS "WinGet $($script:LastOutput | Select-Object -First 1) ($winget)."
}

# ----------------------------------------------------------------------------
# Step 3: Git
# ----------------------------------------------------------------------------

function Invoke-GitStep {
    Start-Step 'Git'

    $candidates = @("$env:ProgramFiles\Git\cmd", "$env:LOCALAPPDATA\Programs\Git\cmd")
    $git = Resolve-Tool 'git' $candidates
    if (-not $git) {
        Install-WingetPackage 'Git.Git' | Out-Null
        $git = Resolve-Tool 'git' $candidates
    }
    if (-not $git) {
        Add-Result FAIL 'git is not installed.'
        Add-Advice 'Install Git from https://git-scm.com/download/win (accept the default options), then re-run this script.'
        return
    }
    Test-ShadowingTool 'git' $git

    if ((Invoke-Logged $git @('--version')) -ne 0) {
        Show-LastOutput
        Add-Result FAIL "git is installed ($git) but does not run."
        Add-Advice 'Reinstall Git from https://git-scm.com/download/win.'
        return
    }
    $version = Get-VersionFromText ($script:LastOutput -join ' ')

    $repo = Join-Path $WorkDir 'git-test'
    $initCode = Invoke-Logged $git @('init', '-q', $repo)
    $commitCode = Invoke-Logged $git @('-C', $repo, '-c', 'user.name=IB9JHO Setup', '-c', 'user.email=setup@example.invalid',
        'commit', '-q', '--allow-empty', '-m', 'setup test')
    if ($initCode -ne 0 -or $commitCode -ne 0) {
        Show-LastOutput
        Add-Result FAIL "git $version is installed but could not create a test commit."
        Add-Advice "Check your Git configuration for errors with 'git config --list --show-origin'."
        return
    }
    Add-Result PASS "git $version works ($git)."

    $null = Invoke-Logged $git @('config', '--global', 'user.name')
    $hasName = [bool]($script:LastOutput -join '').Trim()
    $null = Invoke-Logged $git @('config', '--global', 'user.email')
    $hasEmail = [bool]($script:LastOutput -join '').Trim()
    if (-not ($hasName -and $hasEmail)) {
        Add-Result WARN 'Your Git name and email are not configured, so commits will fail.'
        Add-Advice 'Run: git config --global user.name "Your Name"  and  git config --global user.email "you@example.com" (use the email of your GitHub account).'
    }
}

# ----------------------------------------------------------------------------
# Step 4: Visual Studio Build Tools (MSVC + Windows SDK)
# ----------------------------------------------------------------------------

# The component providing the MSVC libraries and linker for this machine.
function Get-VcToolsComponent {
    if ($script:Arch -eq 'ARM64') { return 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' }
    return 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
}

# Return the installation path of a Visual Studio instance with the C++ tools.
function Get-VcToolsInstance {
    if (-not (Test-Path $VsWhere)) { return $null }
    $null = Invoke-Logged $VsWhere @('-products', '*', '-latest', '-requires', (Get-VcToolsComponent), '-property', 'installationPath')
    return ($script:LastOutput | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
}

# Return the newest Windows SDK version that has both headers and libraries.
function Get-WindowsSdkVersion {
    $root = Join-Path $ProgramFilesX86 'Windows Kits\10'
    $libArch = if ($script:Arch -eq 'ARM64') { 'arm64' } else { 'x64' }
    if (-not (Test-Path "$root\Include")) { return $null }
    $versions = Get-ChildItem "$root\Include" -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            (Test-Path (Join-Path $_.FullName 'um\Windows.h')) -and
            (Test-Path (Join-Path $root "Lib\$($_.Name)\um\$libArch\kernel32.lib"))
        } |
        Sort-Object { [version]$_.Name } -Descending
    if ($versions) { return @($versions)[0].Name }
    return $null
}

# Add the C++ workload (with its recommended components, which include the
# Windows SDK) to an existing Visual Studio installation. Needs elevation, so
# Windows shows a permission prompt.
function Invoke-VsInstallerModify {
    param([string]$InstallPath)
    # Name the product and channel explicitly; without them the installer can
    # fail to locate its channel feed ("Didn't find any channel feed").
    $null = Invoke-Logged $VsWhere @('-products', '*', '-path', $InstallPath, '-property', 'productId')
    $productId = ($script:LastOutput | Where-Object { $_ } | Select-Object -First 1)
    $null = Invoke-Logged $VsWhere @('-products', '*', '-path', $InstallPath, '-property', 'channelId')
    $channelId = ($script:LastOutput | Where-Object { $_ } | Select-Object -First 1)

    $arguments = @('modify', '--installPath', "`"$InstallPath`"")
    if ($productId -and $channelId) { $arguments += @('--productId', $productId, '--channelId', $channelId) }
    # The SDK is named explicitly: an existing workload's recommended
    # components are not re-added by --includeRecommended.
    $arguments += @('--add', 'Microsoft.VisualStudio.Workload.VCTools', '--add', (Get-VcToolsComponent),
        '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.26100',
        '--includeRecommended', '--quiet', '--norestart', '--nocache')
    Write-SetupLog ('$ "{0}" {1}' -f $VsInstaller, ($arguments -join ' '))
    $started = Get-Date
    try {
        $process = Start-Process -FilePath $VsInstaller -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        Write-SetupLog "[exit status $($process.ExitCode)]"
        if ($RebootCodes -contains $process.ExitCode) { $script:RestartRequired = $true }
        elseif ($process.ExitCode -ne 0) {
            Write-Info "The Visual Studio Installer exited with code $($process.ExitCode)."
            # Copy the end of the installer's own log into ours for diagnosis.
            $installerLog = Get-ChildItem $env:TEMP -Filter 'dd_*.log' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $started } | Sort-Object LastWriteTime | Select-Object -Last 1
            if ($installerLog) {
                Write-SetupLog "---- last 40 lines of $($installerLog.FullName) ----"
                Get-Content $installerLog.FullName -Tail 40 | ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding UTF8 }
            }
        }
    }
    catch {
        Write-SetupLog "Visual Studio Installer failed to start: $_"
        Add-Advice 'The Visual Studio Installer could not be started with administrator rights. Re-run the script and click Yes on the permission prompt (or ask an administrator to run it).'
    }
}

$script:BuildToolsOk = $false

function Invoke-BuildToolsStep {
    Start-Step 'Visual Studio Build Tools (MSVC and Windows SDK)'

    $instance = Get-VcToolsInstance
    $sdk = Get-WindowsSdkVersion
    if ((-not $instance -or -not $sdk) -and -not $CheckOnly) {
        $anyInstance = $null
        if (Test-Path $VsWhere) {
            $null = Invoke-Logged $VsWhere @('-products', '*', '-latest', '-property', 'installationPath')
            $anyInstance = $script:LastOutput | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
        }
        if ($anyInstance -and (Test-Path $VsInstaller)) {
            # Visual Studio is present but lacks the C++ tools or the Windows
            # SDK: modify it rather than installing a second copy.
            $missing = @()
            if (-not $instance) { $missing += 'the C++ build tools' }
            if (-not $sdk) { $missing += 'the Windows SDK' }
            Write-Info "Adding $($missing -join ' and ') to the existing Visual Studio at '$anyInstance' (a permission prompt will appear; this can take 10-20 minutes)."
            Invoke-VsInstallerModify $anyInstance
        }
        else {
            Write-Info 'Installing the Visual Studio Build Tools with the C++ workload (about 6 GB; this can take 10-30 minutes).'
            $override = "--wait --quiet --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --add $(Get-VcToolsComponent) --includeRecommended"
            Install-WingetPackage 'Microsoft.VisualStudio.2022.BuildTools' -Override $override | Out-Null
        }
        $instance = Get-VcToolsInstance
        $sdk = Get-WindowsSdkVersion
        if ($instance -and -not $sdk) {
            # Fall back to the standalone SDK if the installer did not add one
            # (it can exit successfully without changing anything).
            Write-SetupLog 'The Visual Studio Installer did not provide a Windows SDK; falling back to the standalone SDK.'
            Write-Info 'The Visual Studio Installer did not add the Windows SDK; installing the standalone SDK instead.'
            Install-WingetPackage 'Microsoft.WindowsSDK.10.0.26100' | Out-Null
            $sdk = Get-WindowsSdkVersion
        }
    }

    if (-not $instance) {
        Add-Result FAIL 'No Visual Studio installation with the C++ build tools (MSVC) was found.'
        Add-Advice 'Clang on Windows needs the MSVC libraries and linker. Open the Visual Studio Installer (or download the Build Tools from https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022), choose Modify and tick "Desktop development with C++".'
        return
    }
    Write-Info "MSVC tools found in: $instance"

    $msvcRoot = Join-Path $instance 'VC\Tools\MSVC'
    $hostDir = if ($script:Arch -eq 'ARM64') { 'Hostarm64\arm64' } else { 'Hostx64\x64' }
    $linker = Get-ChildItem $msvcRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName "bin\$hostDir\link.exe" } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $linker) {
        Add-Result FAIL "The MSVC linker (link.exe) is missing from '$msvcRoot'."
        Add-Advice 'The C++ tools are incomplete. In the Visual Studio Installer choose Modify, then Repair (or untick and re-tick "Desktop development with C++").'
        return
    }

    if (-not $sdk) {
        Add-Result FAIL 'No complete Windows 10/11 SDK was found (Windows.h and kernel32.lib), so Clang cannot compile or link anything.'
        Add-Advice 'Install the Windows SDK: re-run this script without -CheckOnly and accept the permission prompt, or in the Visual Studio Installer choose Modify > Individual components and tick the latest "Windows 11 SDK". Running "winget install --id Microsoft.WindowsSDK.10.0.26100" also works.'
        return
    }
    $msvcVersion = if ($linker -match 'MSVC\\([^\\]+)\\') { $Matches[1] } else { 'unknown version' }
    $script:BuildToolsOk = $true
    Add-Result PASS "MSVC $msvcVersion and Windows SDK $sdk are installed."
}

# ----------------------------------------------------------------------------
# Step 5: LLVM / Clang
# ----------------------------------------------------------------------------

# Write a small C++20 program that exercises the language features and the
# standard library headers used early in the course.
function Write-CppTestProgram {
    param([string]$Path)
    $source = @'
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
'@
    Set-Content -Path $Path -Value $source -Encoding ASCII
}

$script:CompilerOk = $false

function Invoke-CompilerStep {
    Start-Step 'LLVM / Clang C++ compiler'

    $candidates = @("$env:ProgramFiles\LLVM\bin")
    $clang = Resolve-Tool 'clang++' $candidates
    if (-not $clang) {
        Install-WingetPackage 'LLVM.LLVM' | Out-Null
        $clang = Resolve-Tool 'clang++' $candidates
    }
    if (-not $clang) {
        Add-Result FAIL 'clang++ is not installed.'
        Add-Advice 'Install LLVM from https://github.com/llvm/llvm-project/releases (the LLVM-*-win64.exe installer) and tick "Add LLVM to the system PATH".'
        return
    }
    Test-ShadowingTool 'clang++' $clang

    $null = Invoke-Logged $clang @('--version')
    $version = Get-VersionFromText ($script:LastOutput | Select-Object -First 1)
    Write-Info "Found clang++ $version at $clang"
    if ($version -and $version.Major -lt $MinClangMajor -and -not $CheckOnly -and $clang -like "$env:ProgramFiles\LLVM\*") {
        Write-Info "Clang $version is older than $MinClangMajor; upgrading LLVM."
        Install-WingetPackage 'LLVM.LLVM' -Upgrade | Out-Null
        $null = Invoke-Logged $clang @('--version')
        $version = Get-VersionFromText ($script:LastOutput | Select-Object -First 1)
    }

    $source = Join-Path $WorkDir 'compiler-test.cpp'
    $binary = Join-Path $WorkDir 'compiler-test.exe'
    Write-CppTestProgram $source
    if ((Invoke-Logged $clang @('-std=c++20', '-Wall', '-Wextra', '-o', $binary, $source)) -ne 0) {
        Show-LastOutput
        Add-Result FAIL "clang++ $version could not compile a C++20 test program."
        if (-not $script:BuildToolsOk) {
            Add-Advice 'This is caused by the Visual Studio Build Tools problem reported above (Clang uses their headers and libraries). Fix that step first.'
        }
        elseif (Test-LastOutput 'STL1000|Unexpected compiler version') {
            Add-Advice "Clang $version is too old for the installed MSVC standard library. Upgrade LLVM with: winget upgrade --id LLVM.LLVM"
        }
        elseif (Test-LastOutput "(?i)unable to find a Visual Studio|'[a-z_./]+(\.h)?' file not found") {
            Add-Advice 'Clang cannot find the MSVC headers. Make sure the Visual Studio Build Tools step passed ("Desktop development with C++").'
        }
        elseif (Test-LastOutput '(?i)(kernel32|msvcrt|libcmt|oldnames|ucrt)[a-z]*\.lib|LNK1104|cannot open file') {
            Add-Advice 'The linker cannot find the Windows SDK or MSVC libraries. In the Visual Studio Installer choose Modify and make sure "Desktop development with C++" and a Windows SDK are ticked.'
        }
        else {
            Add-Advice 'Read the compiler error above and send the log file to your instructor.'
        }
        return
    }
    if ((Invoke-Logged $binary @()) -ne 0) {
        Show-LastOutput
        Add-Result FAIL 'The test program compiled but did not run correctly.'
        Add-Advice 'Antivirus software may be blocking newly built programs. Add an exclusion for your coursework folder, or send the log to your instructor.'
        return
    }
    if ($version -and $version.Major -lt $MinClangMajor) {
        $script:CompilerOk = $true
        Add-Result WARN "clang++ $version works, but version $MinClangMajor or newer is recommended."
        Add-Advice 'Upgrade LLVM with: winget upgrade --id LLVM.LLVM'
    }
    else {
        $script:CompilerOk = $true
        Add-Result PASS "clang++ $version compiles and runs C++20 code ($clang)."
    }
}

# ----------------------------------------------------------------------------
# Steps 6 and 7: CMake and Ninja
# ----------------------------------------------------------------------------

function Invoke-CMakeStep {
    Start-Step 'CMake'

    $candidates = @("$env:ProgramFiles\CMake\bin")
    $cmake = Resolve-Tool 'cmake' $candidates
    if (-not $cmake) {
        Install-WingetPackage 'Kitware.CMake' | Out-Null
        $cmake = Resolve-Tool 'cmake' $candidates
    }
    if (-not $cmake) {
        Add-Result FAIL 'cmake is not installed.'
        Add-Advice 'Install CMake from https://cmake.org/download/ (Windows x64 Installer) and choose "Add CMake to the PATH".'
        return
    }
    Test-ShadowingTool 'cmake' $cmake

    if ((Invoke-Logged $cmake @('--version')) -ne 0) {
        Show-LastOutput
        Add-Result FAIL "cmake is installed ($cmake) but does not run."
        Add-Advice 'Reinstall CMake: winget install --id Kitware.CMake --force'
        return
    }
    $version = Get-VersionFromText ($script:LastOutput | Select-Object -First 1)
    if ($version -and $version -ge $MinCMakeVersion) {
        Add-Result PASS "cmake $version ($cmake)."
    }
    else {
        Add-Result FAIL "cmake $version is too old; version $MinCMakeVersion or newer is required for CMake presets."
        Add-Advice 'Upgrade CMake with: winget upgrade --id Kitware.CMake'
    }
}

function Invoke-NinjaStep {
    Start-Step 'Ninja build system'

    $candidates = @("$env:LOCALAPPDATA\Microsoft\WinGet\Links", "$env:ProgramFiles\WinGet\Links")
    $ninja = Resolve-Tool 'ninja' $candidates
    if (-not $ninja) {
        Install-WingetPackage 'Ninja-build.Ninja' | Out-Null
        $ninja = Resolve-Tool 'ninja' $candidates
    }
    if (-not $ninja) {
        Add-Result FAIL 'ninja is not installed.'
        Add-Advice 'Download ninja-win.zip from https://github.com/ninja-build/ninja/releases, extract ninja.exe into a folder such as C:\tools\ninja and add that folder to your PATH.'
        return
    }
    Test-ShadowingTool 'ninja' $ninja
    if ((Invoke-Logged $ninja @('--version')) -eq 0) {
        Add-Result PASS "ninja $($script:LastOutput | Select-Object -First 1) ($ninja)."
    }
    else {
        Show-LastOutput
        Add-Result FAIL "ninja is installed ($ninja) but does not run."
        Add-Advice 'Reinstall Ninja: winget install --id Ninja-build.Ninja --force'
    }
}

# ----------------------------------------------------------------------------
# Step 8: Visual Studio Code and extensions
# ----------------------------------------------------------------------------

function Invoke-VSCodeStep {
    Start-Step 'Visual Studio Code'

    if ($SkipVSCode) {
        Add-Result SKIP 'Skipped (-SkipVSCode).'
        return
    }
    $candidates = @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin", "$env:ProgramFiles\Microsoft VS Code\bin")
    $code = Resolve-Tool 'code' $candidates
    if (-not $code) {
        # Add VS Code to PATH and the Explorer context menu; do not launch it.
        $override = '/VERYSILENT /NORESTART /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath'
        Install-WingetPackage 'Microsoft.VisualStudioCode' -Override $override | Out-Null
        $code = Resolve-Tool 'code' $candidates
    }
    if (-not $code) {
        Add-Result FAIL 'Visual Studio Code is not installed.'
        Add-Advice 'Install VS Code from https://code.visualstudio.com (tick "Add to PATH" during installation), then re-run this script.'
        return
    }
    if ((Invoke-Logged $code @('--version')) -ne 0) {
        Show-LastOutput
        Add-Result FAIL "VS Code is installed ($code) but its command-line launcher does not run."
        Add-Advice 'Reinstall VS Code from https://code.visualstudio.com.'
        return
    }
    Add-Result PASS "VS Code $($script:LastOutput | Select-Object -First 1) ($code)."

    Start-Step 'VS Code extensions'
    if (-not $CheckOnly) {
        foreach ($extension in $VSCodeExtensions) {
            if ((Invoke-Logged $code @('--install-extension', $extension, '--force')) -ne 0) { Show-LastOutput 5 }
        }
    }
    $null = Invoke-Logged $code @('--list-extensions')
    $installed = @($script:LastOutput | ForEach-Object { $_.Trim().ToLowerInvariant() })
    $missing = @($VSCodeExtensions | Where-Object { $installed -notcontains $_.ToLowerInvariant() })
    if ($missing.Count -eq 0) {
        Add-Result PASS "All $($VSCodeExtensions.Count) IB9JHO extensions are installed."
    }
    else {
        Add-Result FAIL "Missing extensions: $($missing -join ', ')"
        Add-Advice "Install the missing extensions from the Extensions tab in VS Code, or run 'code --install-extension <name>' for each. The marketplace must be reachable (check proxy settings)."
    }
}

# ----------------------------------------------------------------------------
# Step 9: end-to-end CMake test
# ----------------------------------------------------------------------------

# Write a minimal project with the same CMake preset that IB9JHO repositories
# use, so that this test reproduces exactly what VS Code will do.
function Write-SmokeProject {
    param([string]$Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    Write-CppTestProgram (Join-Path $Directory 'main.cpp')
    $cmakeLists = @'
cmake_minimum_required(VERSION 3.21)
project(IB9JHOSmokeTest)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_compile_options(-Wall -Wextra)

add_executable(smoke_test main.cpp)

enable_testing()
add_test(NAME smoke_test_output COMMAND smoke_test)
set_tests_properties(smoke_test_output PROPERTIES PASS_REGULAR_EXPRESSION "IB9JHO toolchain OK")
'@
    $presets = @'
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
'@
    Set-Content -Path (Join-Path $Directory 'CMakeLists.txt') -Value $cmakeLists -Encoding ASCII
    Set-Content -Path (Join-Path $Directory 'CMakePresets.json') -Value $presets -Encoding ASCII
}

# Give targeted advice for a failed CMake configure step.
function Add-ConfigureAdvice {
    if (Test-LastOutput '(?i)CMAKE_MAKE_PROGRAM is not set|Unable to find the Ninja|ninja.*not found') {
        Add-Advice "CMake cannot find Ninja. Make sure the Ninja step passed and that 'ninja --version' works in a new terminal."
    }
    elseif (Test-LastOutput '(?i)CMAKE_(CXX|C)_COMPILER.*(not found|is not a full path)|could not find compiler') {
        Add-Advice "CMake cannot find clang/clang++. Make sure the Clang step passed and that 'clang++ --version' works in a new terminal."
    }
    elseif (Test-LastOutput '(?i)is not able to compile a simple test program') {
        Add-Advice "The compiler works on its own but not through CMake; the log contains the full error. Delete the project's 'build' folder and try again."
    }
    elseif (Test-LastOutput '(?i)rc\.exe|llvm-rc|CMAKE_RC_COMPILER|mt\.exe') {
        Add-Advice 'CMake cannot find the resource compiler. Reinstall LLVM (winget install --id LLVM.LLVM --force) so that llvm-rc.exe is available.'
    }
    else {
        Add-Advice "Read the CMake output above (full output in the log). Deleting the 'build' folder and reconfiguring fixes many cache-related errors."
    }
}

function Invoke-SmokeTestStep {
    Start-Step 'End-to-end test (CMake + Ninja + Clang)'

    $missing = @('cmake', 'ninja', 'clang', 'clang++') | Where-Object {
        -not (Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue)
    }
    if ($missing) {
        Add-Result FAIL "Not run, because these tools are missing: $($missing -join ', ')."
        Add-Advice 'Fix the failed steps above first; this test needs CMake, Ninja and Clang.'
        return
    }
    if (-not $script:CompilerOk) {
        Add-Result FAIL 'Not run, because Clang cannot compile programs yet (see the compiler step above).'
        return
    }

    $directory = Join-Path $WorkDir 'smoke-project'
    Write-SmokeProject $directory
    $cmake = (Get-Command cmake -CommandType Application | Select-Object -First 1).Source
    $ctest = Join-Path (Split-Path $cmake) 'ctest.exe'

    Push-Location $directory
    try {
        if ((Invoke-Logged $cmake @('--preset', 'clang')) -ne 0) {
            Show-LastOutput 25
            Add-Result FAIL "CMake could not configure a test project with the 'clang' preset."
            Add-ConfigureAdvice
            return
        }
        if ((Invoke-Logged $cmake @('--build', '--preset', 'clang')) -ne 0) {
            Show-LastOutput 25
            Add-Result FAIL 'The test project configured but did not build.'
            Add-Advice 'Read the build errors above. If Clang works on its own (compiler step) but fails here, delete the build folder and retry.'
            return
        }
        if ((Invoke-Logged $ctest @('--preset', 'clang')) -ne 0) {
            Show-LastOutput 25
            Add-Result FAIL 'The test project built but its test (CTest) did not pass.'
            Add-Advice 'The program built but produced unexpected output; check the log for the program output.'
            return
        }
        Add-Result PASS "Configured, built and tested a C++20 project with the 'clang' preset."
    }
    finally {
        Pop-Location
    }
}

function Invoke-ProjectStep {
    if (-not $Project) { return }
    Start-Step "Project build ($Project)"

    if (-not (Test-Path (Join-Path $Project 'CMakeLists.txt'))) {
        Add-Result FAIL "No CMakeLists.txt in '$Project'."
        Add-Advice "Pass the folder that contains the repository's top-level CMakeLists.txt to -Project."
        return
    }
    $cmake = Get-Command cmake -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmake -or -not $script:CompilerOk) {
        Add-Result FAIL 'Not run, because CMake or a working Clang is missing (see the steps above).'
        return
    }
    # Build in a temporary folder so the student's own build folder (and its
    # cache) is never touched, even in check-only mode.
    $buildDir = Join-Path $WorkDir 'project-build'
    $configureArgs = @('--preset', 'clang', '-B', $buildDir)
    if (-not (Test-Path (Join-Path $Project 'CMakePresets.json'))) {
        Add-Result WARN 'The project has no CMakePresets.json; using equivalent command-line settings.'
        Add-Advice 'Copy CMakePresets.json from the IB9JHO environment-setup repository into the project so VS Code picks Clang and Ninja automatically.'
        $configureArgs = @('-S', '.', '-B', $buildDir, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Debug', '-DCMAKE_C_COMPILER=clang', '-DCMAKE_CXX_COMPILER=clang++')
    }
    Push-Location $Project
    try {
        if ((Invoke-Logged $cmake.Source $configureArgs) -ne 0) {
            Show-LastOutput 25
            Add-Result FAIL 'The project did not configure.'
            Add-ConfigureAdvice
            return
        }
        if ((Invoke-Logged $cmake.Source @('--build', $buildDir)) -ne 0) {
            Show-LastOutput 25
            Add-Result FAIL 'The project configured but did not build.'
            Add-Advice "The tool chain works (see the end-to-end test), so this is most likely an error in the project's own code; read the compiler errors above."
            return
        }
        Add-Result PASS 'The project configured and built. (Its tests were not run, as coursework tests are expected to fail until completed.)'
    }
    finally {
        Pop-Location
    }
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------

function Write-Summary {
    Write-Host ''
    Write-Host '==> Summary' -ForegroundColor Cyan
    Write-SetupLog ('=' * 64)
    Write-SetupLog 'SUMMARY'
    $failures = 0
    $warnings = 0
    foreach ($result in $script:Results) {
        $colour = switch ($result.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
        if ($result.Status -eq 'FAIL') { $failures++ }
        if ($result.Status -eq 'WARN') { $warnings++ }
        Write-Host ('  {0,-4}' -f $result.Status) -ForegroundColor $colour -NoNewline
        Write-Host ('  {0,-50} {1}' -f $result.Step, $result.Detail)
        Write-SetupLog "$($result.Status)  $($result.Step): $($result.Detail)"
    }
    if ($script:Advice.Count -gt 0) {
        Write-Host ''
        Write-Host 'What to do next:' -ForegroundColor White
        foreach ($item in $script:Advice) { Write-Host "  - $item" }
    }
    Write-SetupLog "Final PATH=$env:Path"
    Write-ToolInventory

    Write-Host ''
    Write-Host "Full log: $LogFile"
    if ($script:RestartRequired) {
        Write-Host 'Windows needs a restart to finish installing some tools. Restart, then re-run this script to confirm.' -ForegroundColor Yellow
    }
    if ($failures -eq 0) {
        $suffix = if ($warnings -gt 0) { " ($warnings warning(s) above)" } else { '' }
        Write-Host "Your IB9JHO environment is ready$suffix." -ForegroundColor Green
        Write-Host "Open a course repository in VS Code and select the 'Clang (IB9JHO)' preset when asked."
        if (-not $CheckOnly) { Write-Host 'Close and reopen any terminals and VS Code windows so they pick up the updated PATH.' }
        return 0
    }
    Write-Host "$failures check(s) failed. Follow the advice above and re-run this script." -ForegroundColor Red
    Write-Host 'If you are stuck, send the log file above to your instructor.'
    return 1
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

Write-Host "$ScriptName $ScriptVersion" -ForegroundColor White
Write-Host "Logging to $LogFile"
Write-SetupLog "$ScriptName $ScriptVersion"

$exitCode = 1
try {
    if (Invoke-PreflightStep) {
        if (-not $CheckOnly -and -not (Confirm-Action 'Install any missing IB9JHO tools now?')) {
            $CheckOnly = $true
            Write-Info 'Continuing in check-only mode.'
        }
        Invoke-WingetStep
        Invoke-GitStep
        Invoke-BuildToolsStep
        Invoke-CompilerStep
        Invoke-CMakeStep
        Invoke-NinjaStep
        Invoke-VSCodeStep
        Invoke-SmokeTestStep
        Invoke-ProjectStep
    }
    $exitCode = Write-Summary
}
catch {
    # An unexpected script error: record everything needed to diagnose it.
    Write-SetupLog "UNEXPECTED ERROR: $_"
    Write-SetupLog $_.ScriptStackTrace
    Write-Host "Unexpected error: $_" -ForegroundColor Red
    Write-Host "Please send the log file to your instructor: $LogFile"
    $exitCode = 1
}
finally {
    Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
}
exit $exitCode
