<#
.SYNOPSIS
    Installs and configures DVC in the current repository, using a shared cache.

.DESCRIPTION
    Run from the root of your git repository. The script is idempotent - running it
    again on an already-configured repo will verify and correct settings rather than
    fail.

    It will:
      1. Verify it is running from a git repository root
      2. Install DVC (via pipx if available, otherwise pip --user)
      3. Run 'dvc init' if needed
      4. Point the cache at the shared location and choose the best link type
         available for your volume layout
      5. Optionally configure a remote for 'dvc push' / 'dvc pull'
      6. Install git hooks so 'git checkout' keeps data in sync
      7. Report the resulting configuration

.PARAMETER CacheDir
    Shared cache location - the point of this setup. Workspace files become
    symlinks into it, so workstations hold no copies of the data. Defaults to
    E:\data. Pass an empty string to use a repo-local cache instead.

.PARAMETER RemoteUrl
    Optional remote for dvc push/pull. Not needed for collaboration when the
    cache is shared; useful as a second copy if the cache is not backed up.

.PARAMETER AllowCopy
    Proceed even if symlinks are unavailable and DVC would fall back to copying
    every file into each workspace. Off by default, because that silently
    defeats the purpose of a shared cache.

.PARAMETER RemoteName
    Name for the remote. Defaults to 'storage'.

.PARAMETER SkipInstall
    Skip the DVC installation step and only configure the repo.

.EXAMPLE
    .\Setup-Dvc.ps1

.EXAMPLE
    .\Setup-Dvc.ps1 -RemoteUrl '\\fileserver\lab\dvc-store'

.EXAMPLE
    .\Setup-Dvc.ps1 -CacheDir 'E:\data' -RemoteUrl 'E:\dvc-store' -SkipInstall
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$CacheDir  = 'E:\data',
    [string]$RemoteUrl = '',
    [string]$RemoteName = 'storage',
    [switch]$AllowCopy,
    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------

$script:Warnings = New-Object System.Collections.Generic.List[string]

function Write-Step   { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok     { param([string]$m) Write-Host "    [ok]   $m" -ForegroundColor Green }
function Write-Info   { param([string]$m) Write-Host "    [info] $m" -ForegroundColor Gray }
function Write-Warn   {
    param([string]$m)
    Write-Host "    [warn] $m" -ForegroundColor Yellow
    $script:Warnings.Add($m)
}
function Write-Fail   { param([string]$m) Write-Host "    [fail] $m" -ForegroundColor Red }

function Test-Cmd {
    param([Parameter(Mandatory)][string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Update-PathFromEnvironment {
    # pip/pipx put shims in a directory that may not be on PATH in this session.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Invoke-Dvc {
    <#
        Runs dvc and throws on a non-zero exit code. Output is passed through
        unless -Capture is given, in which case it is returned as a string.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Capture,
        [switch]$AllowFailure
    )
    # $ErrorActionPreference = 'Stop' promotes anything a native command writes
    # to stderr into a terminating error, which hides the real exit code and
    # aborts before callers can inspect the output. Relax it for the call only.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Capture) {
            $out = & dvc @Arguments 2>&1 | Out-String
        } else {
            & dvc @Arguments 2>&1 | ForEach-Object { "$_" }
            $out = ''
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "dvc $($Arguments -join ' ') failed with exit code $LASTEXITCODE`n$out"
    }
    return $out.Trim()
}

function Set-DvcConfig {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $current = Invoke-Dvc -Arguments @('config', $Key) -Capture -AllowFailure
    if ($current -eq $Value) {
        Write-Ok "$Key = $Value (already set)"
        return $false
    }
    Invoke-Dvc -Arguments @('config', $Key, $Value) | Out-Null
    Write-Ok "$Key = $Value"
    return $true
}

# ----------------------------------------------------------------------------
# 1. Sanity checks
# ----------------------------------------------------------------------------

Write-Step 'Checking environment'

if (-not (Test-Path -LiteralPath '.git')) {
    Write-Fail 'No .git directory here. Run this script from the root of your repository.'
    exit 1
}
$repoRoot = (Get-Location).ProviderPath
Write-Ok "Repository root: $repoRoot"

if (-not (Test-Cmd 'git')) {
    Write-Fail 'git was not found on PATH. Install Git for Windows first.'
    exit 1
}
Write-Ok "git $((& git --version) -replace '^git version ','')"

# ----------------------------------------------------------------------------
# 2. Install DVC
# ----------------------------------------------------------------------------

if ($SkipInstall) {
    Write-Step 'Skipping DVC installation (-SkipInstall)'
} else {
    Write-Step 'Installing DVC'

    $standaloneHint = @'
Easiest fix: install the self-contained DVC installer, which bundles its own
Python and ignores whatever is on your PATH:

    https://dvc.org/doc/install/windows

Then reopen your terminal and re-run this script with -SkipInstall.
'@

    if (Test-Cmd 'dvc') {
        Write-Info 'DVC already present - leaving it as it is'
        Write-Info 'Upgrade separately with "pipx upgrade dvc", conda, or the standalone installer'
    } else {
        # A Python on PATH is not necessarily a working Python. Anaconda installs
        # in particular can be left half-removed, at which point the interpreter
        # starts but cannot find its own stdlib ("No module named 'encodings'").
        # Importing a stdlib module is a much better test than --version.
        function Test-PythonUsable {
            param([Parameter(Mandatory)][string]$Exe)
            try {
                $out = & $Exe -c "import encodings, sys; print(sys.version_info[0], sys.version_info[1])" 2>&1 | Out-String
            } catch {
                return $null
            }
            if ($LASTEXITCODE -ne 0) { return $null }
            if ($out -notmatch '(\d+)\s+(\d+)') { return $null }
            return [version]("$($Matches[1]).$($Matches[2])")
        }

        $python = $null
        $pyVersion = $null
        foreach ($candidate in @('py', 'python', 'python3')) {
            if (-not (Test-Cmd $candidate)) { continue }
            $v = Test-PythonUsable -Exe $candidate
            if (-not $v) {
                Write-Info "$candidate is present but not usable - skipping"
                continue
            }
            # DVC needs 3.9+. No upper bound: new releases sometimes lack
            # wheels for DVC's compiled dependencies, but that shows up as an
            # install failure with a clear message, not something to pre-empt.
            if ($v -lt [version]'3.9') {
                Write-Info "$candidate is Python $v - too old for DVC (needs 3.9+)"
                continue
            }
            $python = $candidate; $pyVersion = $v; break
        }

        if (-not $python) {
            Write-Fail "No usable Python 3.9 or newer was found.`n`n$standaloneHint"
            exit 1
        }
        Write-Ok "Using $python (Python $pyVersion)"

        # pipx is preferred, but pipx itself runs on some interpreter, and that
        # interpreter may be the broken one. Verify before trusting it.
        $pipxOk = $false
        if (Test-Cmd 'pipx') {
            & pipx --version 2>&1 | Out-Null
            $pipxOk = ($LASTEXITCODE -eq 0)
            if (-not $pipxOk) {
                Write-Warn 'pipx is on PATH but does not run - its interpreter is probably broken. Falling back to pip.'
            }
        }

        # pip and pipx write progress and warnings to stderr; with
        # ErrorActionPreference = 'Stop' that would abort a successful install.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            if ($pipxOk) {
                Write-Info 'Installing via pipx (isolated environment - preferred)'
                & pipx install dvc 2>&1 | ForEach-Object { "$_" }
            } else {
                Write-Info 'Installing via pip --user'
                & $python -m pip install --user --upgrade dvc 2>&1 | ForEach-Object { "$_" }
            }
        } finally {
            $ErrorActionPreference = $prevEap
        }

        if ($LASTEXITCODE -ne 0) {
            Write-Fail "DVC installation failed.`n`n$standaloneHint"
            exit 1
        }
        Update-PathFromEnvironment
    }
}

if (-not (Test-Cmd 'dvc')) {
    Update-PathFromEnvironment
    if (-not (Test-Cmd 'dvc')) {
        Write-Fail @'
DVC is installed but not on PATH in this session.
Close and reopen your terminal, then re-run with -SkipInstall.
'@
        exit 1
    }
}

# Confirm dvc actually runs; a shim can exist while its interpreter is broken.
$dvcVersion = Invoke-Dvc -Arguments @('--version') -Capture -AllowFailure
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($dvcVersion)) {
    Write-Fail @"
'dvc' is on PATH but will not run:
$dvcVersion

This usually means its Python interpreter is broken. Install the standalone
build from https://dvc.org/doc/install/windows and re-run with -SkipInstall.
"@
    exit 1
}
Write-Ok "dvc $dvcVersion"

# ----------------------------------------------------------------------------
# 3. dvc init
# ----------------------------------------------------------------------------

Write-Step 'Initialising DVC in this repository'

if (Test-Path -LiteralPath '.dvc\config') {
    Write-Ok '.dvc already exists - leaving it alone'
} else {
    Invoke-Dvc -Arguments @('init') | Out-Null
    Write-Ok 'Created .dvc/ - remember to commit it'
}

# ----------------------------------------------------------------------------
# 4. Shared cache
# ----------------------------------------------------------------------------

$repoRootDrive = [System.IO.Path]::GetPathRoot($repoRoot)
$sharedCache = -not [string]::IsNullOrWhiteSpace($CacheDir)

if (-not $sharedCache) {
    Write-Step 'Configuring cache (repo-local)'
    $CacheDir  = Join-Path $repoRoot '.dvc\cache'
    $cacheRoot = $repoRootDrive
    Write-Ok "Cache stays at .dvc\cache on $repoRootDrive - hardlinks will work"
} else {
    Write-Step "Configuring shared cache at $CacheDir"

    $cacheRoot = [System.IO.Path]::GetPathRoot($CacheDir)

    if (-not (Test-Path -LiteralPath $cacheRoot)) {
        Write-Fail "Drive $cacheRoot is not available. Connect it and re-run."
        exit 1
    }

    if (-not (Test-Path -LiteralPath $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
        Write-Ok "Created $CacheDir"
    } else {
        Write-Ok "$CacheDir exists"
    }

    # Write a probe file to confirm we can actually write there.
    try {
        $probe = Join-Path $CacheDir ('.dvc-write-probe-' + [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $probe -Value 'probe' -NoNewline
        Remove-Item -LiteralPath $probe -Force
        Write-Ok 'Cache directory is writable'
    } catch {
        Write-Fail "Cannot write to $CacheDir - check permissions. $($_.Exception.Message)"
        exit 1
    }

    Set-DvcConfig -Key 'cache.dir' -Value $CacheDir | Out-Null

    # exFAT/FAT32 support neither links nor permissions - DVC silently copies.
    $fsType = $null
    try {
        $fsInfo = & fsutil fsinfo volumeinfo $cacheRoot 2>&1 | Out-String
        if ($fsInfo -match 'File System Name\s*:\s*(\S+)') { $fsType = $Matches[1] }
    } catch { }
    if ($fsType) {
        if ($fsType -match 'NTFS') {
            Write-Ok "Cache volume is $fsType"
        } else {
            Write-Warn "Cache volume is $fsType, which supports no links. DVC will copy regardless of cache.type. Reformat as NTFS."
        }
    }

    if ($CacheDir.StartsWith('\\')) {
        # Network project directories need a different lock implementation.
        Set-DvcConfig -Key 'core.hardlink_lock' -Value 'true' | Out-Null

        # Symlinks to network targets also need SeBackupPrivilege.
        $priv = & whoami /priv 2>&1 | Out-String
        if ($priv -notmatch 'SeBackupPrivilege') {
            Write-Warn 'SeBackupPrivilege is absent from this token. Symlinks pointing at network locations may fail; grant it alongside SeCreateSymbolicLinkPrivilege.'
        }

        # Local-to-remote symlink evaluation must be enabled on the client.
        try {
            $eval = & fsutil behavior query SymlinkEvaluation 2>&1 | Out-String
            if ($eval -match 'Local to remote symbolic links are disabled') {
                Write-Warn 'Local-to-remote symlink evaluation is disabled. Enable with: fsutil behavior set SymlinkEvaluation L2R:1'
            } else {
                Write-Ok 'Local-to-remote symlink evaluation is enabled'
            }
        } catch { }
    }
}

# --- Decide the link type -----------------------------------------------------
# reflink:  not supported on NTFS - never useful here
# hardlink: same volume only, NTFS caps at 1024 links per file
# symlink:  works across volumes, but creation needs Developer Mode or admin
# copy:     always works, uses twice the disk
#
# DVC automatically makes hardlinked/symlinked files read-only to protect the
# cache from in-place edits. Use 'dvc unprotect <path>' if you must modify one.
# (There is no cache.protected option to set - that became automatic long ago.)

$sameVolume = $cacheRoot.TrimEnd('\') -ieq $repoRootDrive.TrimEnd('\')

$canSymlink = $false
try {
    $tmpTarget = Join-Path $env:TEMP ('dvc-symlink-target-' + [guid]::NewGuid().ToString('N'))
    $tmpLink   = Join-Path $env:TEMP ('dvc-symlink-link-'   + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpTarget -Force | Out-Null
    New-Item -ItemType SymbolicLink -Path $tmpLink -Target $tmpTarget -ErrorAction Stop | Out-Null
    $canSymlink = $true
    (Get-Item -LiteralPath $tmpLink -Force).Delete()
    Remove-Item -LiteralPath $tmpTarget -Recurse -Force
} catch {
    $canSymlink = $false
    if (Test-Path -LiteralPath $tmpTarget) { Remove-Item -LiteralPath $tmpTarget -Recurse -Force }
}

if ($sameVolume -and -not $sharedCache) {
    $linkType = if ($canSymlink) { 'hardlink,symlink,copy' } else { 'hardlink,copy' }
    Write-Ok "Repo and cache are both on $cacheRoot - hardlinks will be used"
} elseif ($canSymlink) {
    # Symlink first, deliberately: it is the only link type that leaves the
    # bytes on the server rather than materialising them in the workspace.
    $linkType = 'symlink,copy'
    Write-Ok 'Symlink creation works for this account - workspace files will point at the cache, using no local disk'
    if ($sameVolume) {
        Write-Info "Cache is on the same volume as the repo ($cacheRoot); hardlinks would also work but symlinks keep behaviour identical across machines."
    }
} else {
    $linkType = 'copy'
    $msg = @"
Symlink creation is not permitted for this account, so DVC would copy every
file into the workspace. A shared cache saves nothing in that state.

Fix: grant SeCreateSymbolicLinkPrivilege to this account or a group containing
it (secpol.msc > Local Policies > User Rights Assignment > Create symbolic
links), then log off and back on.
"@
    if ($AllowCopy) {
        Write-Warn $msg
    } else {
        Write-Fail $msg
        Write-Info 'Re-run with -AllowCopy to proceed anyway, or with -CacheDir "" for a repo-local cache plus a remote.'
        exit 1
    }
}

$linkChanged = Set-DvcConfig -Key 'cache.type' -Value $linkType

# Convenient: auto-stage .dvc files so you don't forget to 'git add' them.
Set-DvcConfig -Key 'core.autostage' -Value 'true' | Out-Null

if ($linkChanged -and (Get-ChildItem -Filter '*.dvc' -Recurse -File -ErrorAction SilentlyContinue)) {
    Write-Info 'Link type changed - relinking existing data from cache'
    Invoke-Dvc -Arguments @('checkout', '--relink') -AllowFailure | Out-Null
}

# ----------------------------------------------------------------------------
# 5. Remote
# ----------------------------------------------------------------------------

Write-Step 'Configuring remote storage'

if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
    Write-Info 'No -RemoteUrl given. Not required with a shared cache - colleagues get data by checkout, not pull.'
    Write-Warn "The cache at $CacheDir is now the only copy of your data. Confirm it is included in IT's backups."
    $haveRemote = $false
} else {
    # Create local/UNC remote directories up front; DVC will not do it for you.
    if ($RemoteUrl -notmatch '^[a-z0-9]+://') {
        if (-not (Test-Path -LiteralPath $RemoteUrl)) {
            New-Item -ItemType Directory -Path $RemoteUrl -Force | Out-Null
            Write-Ok "Created $RemoteUrl"
        }
        if ($RemoteUrl.TrimEnd('\') -ieq $CacheDir.TrimEnd('\')) {
            Write-Warn 'Remote and cache point at the same directory. Use separate paths, or push becomes a no-op copy onto itself.'
        }
    }
    Invoke-Dvc -Arguments @('remote', 'add', '--default', '--force', $RemoteName, $RemoteUrl) | Out-Null
    Write-Ok "Default remote '$RemoteName' -> $RemoteUrl"
    $haveRemote = $true
}

# ----------------------------------------------------------------------------
# 6. Git hooks
# ----------------------------------------------------------------------------

Write-Step 'Installing git hooks'

# 'dvc install' adds all three, with no way to select:
#   post-checkout -> dvc checkout   (data follows branch switches)
#   pre-commit    -> dvc status     (warns about unsynced data)
#   pre-push      -> dvc push       (stops you pushing pointers with no content)
# With a shared cache and no remote there is nothing to push, and a failing
# pre-push hook aborts 'git push'. So install all three, then remove pre-push.

$hookOut = Invoke-Dvc -Arguments @('install') -Capture -AllowFailure
if ($LASTEXITCODE -ne 0) {
    if ($hookOut -match 'already exists') {
        # Re-run on a repo that already has the hooks. Nothing to do.
        Write-Ok 'Hooks were already installed'
    } else {
        Write-Warn "dvc install failed: $hookOut"
    }
}

# DVC installs post-checkout, pre-commit and pre-push only. That leaves a gap:
# 'git pull' fast-forwards via a merge (post-merge), and 'git pull --rebase'
# rewrites history (post-rewrite). Neither fires post-checkout, so pulled data
# would not appear until the next branch switch. Add those two hooks ourselves.

$hooksDirAll = (& git rev-parse --git-path hooks 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($hooksDirAll)) {
    $hooksDirAll = Join-Path $repoRoot '.git\hooks'
}
$hooksDirAll = $hooksDirAll.Trim()
# git returns a path relative to the repo root. .NET file APIs resolve relative
# paths against the process working directory, not PowerShell's location, so
# make it absolute before using it.
if (-not [IO.Path]::IsPathRooted($hooksDirAll)) {
    $hooksDirAll = Join-Path $repoRoot $hooksDirAll
}
$hooksDirAll = $hooksDirAll -replace '/', '\'
if (-not (Test-Path -LiteralPath $hooksDirAll)) {
    New-Item -ItemType Directory -Path $hooksDirAll -Force | Out-Null
}

foreach ($hookName in @('post-merge', 'post-rewrite')) {
    $hookPath = Join-Path $hooksDirAll $hookName
    if (Test-Path -LiteralPath $hookPath) {
        $existingBody = Get-Content -LiteralPath $hookPath -Raw -ErrorAction SilentlyContinue
        if ($existingBody -match 'dvc\s+checkout') {
            Write-Ok "$hookName hook already present"
        } else {
            Write-Warn "An existing $hookName hook was left alone. Add 'dvc checkout' to it manually."
        }
        continue
    }
    # LF endings, no BOM: git runs these through sh, which chokes on CRLF.
    [IO.File]::WriteAllText($hookPath, "#!/bin/sh`nexec dvc checkout`n",
                            (New-Object Text.UTF8Encoding $false))
    Write-Ok "$hookName hook installed (keeps 'git pull' in sync)"
}

if ($haveRemote) {
    Write-Ok 'post-checkout, pre-commit and pre-push hooks installed'
} else {
    # core.hooksPath may relocate the hooks directory, so ask git where it is.
    $prePush = Join-Path $hooksDirAll 'pre-push'

    if (Test-Path -LiteralPath $prePush) {
        # Only remove it if it is DVC's, never someone else's pre-push hook.
        $body = Get-Content -LiteralPath $prePush -Raw -ErrorAction SilentlyContinue
        # DVC writes 'dvc git-hook pre-push' in current versions, and wrote
        # 'dvc push' in older ones. Accept either.
        if ($body -match 'dvc\s+(git-hook\s+pre-push|push)') {
            Remove-Item -LiteralPath $prePush -Force
            Write-Ok 'post-checkout and pre-commit hooks installed'
            Write-Info 'pre-push hook removed - no remote configured, so there is nothing to push'
        } else {
            Write-Warn "An existing pre-push hook at $prePush was left alone because it is not DVC's."
        }
    } else {
        Write-Ok 'post-checkout and pre-commit hooks installed'
    }
}

# ----------------------------------------------------------------------------
# 7. .gitignore hygiene
# ----------------------------------------------------------------------------

Write-Step 'Checking .gitignore'

$ignoreLines = @('/.dvc/cache', '/.dvc/tmp', '/.dvc/config.local')
if (Test-Path -LiteralPath '.gitignore') {
    $existing = Get-Content -LiteralPath '.gitignore'
} else {
    $existing = @()
}
$toAdd = $ignoreLines | Where-Object { $existing -notcontains $_ }
if ($toAdd) {
    Add-Content -LiteralPath '.gitignore' -Value (@('', '# DVC') + $toAdd)
    Write-Ok "Added to .gitignore: $($toAdd -join ', ')"
} else {
    Write-Ok 'Already covers the DVC local files'
}

# ----------------------------------------------------------------------------
# 7b. 'dvcadd' wrapper
# ----------------------------------------------------------------------------

# DVC 3.59+ regressed: 'dvc add' leaves workspace files as copies instead of
# relinking them from the cache (treeverse/dvc#10780). Until that is fixed,
# every add needs a follow-up 'dvc checkout --relink'. These wrappers do both.
# Remove this section once upstream fixes the regression.

Write-Step "Installing 'dvcadd' wrapper"

$marker = '# >>> dvcadd (DVC #10780 workaround) >>>'
$endMarker = '# <<< dvcadd <<<'

# --- PowerShell profile ---
try {
    $profilePath = $PROFILE.CurrentUserAllHosts
    $profileDir  = Split-Path -Parent $profilePath
    if (-not (Test-Path -LiteralPath $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    $profileBody = if (Test-Path -LiteralPath $profilePath) {
        Get-Content -LiteralPath $profilePath -Raw
    } else { '' }

    if ($profileBody -match [regex]::Escape($marker)) {
        Write-Ok "PowerShell profile already has dvcadd ($profilePath)"
    } else {
        $block = @"

$marker
function dvcadd {
    dvc add @args
    if (`$LASTEXITCODE -eq 0) { dvc checkout --relink }
}
$endMarker
"@
        Add-Content -LiteralPath $profilePath -Value $block
        Write-Ok "Added dvcadd to $profilePath"
    }
} catch {
    Write-Warn "Could not update the PowerShell profile: $($_.Exception.Message)"
}

# --- cmd.exe via AutoRun doskey macros ---
# HKCU\Software\Microsoft\Command Processor\AutoRun runs on every cmd start.
try {
    $macroFile = Join-Path $env:LOCALAPPDATA 'dvc-macros.doskey'
    Set-Content -LiteralPath $macroFile -Encoding ASCII -Value @(
        'dvcadd=dvc add $* $T dvc checkout --relink'
    )
    Write-Ok "Wrote doskey macro to $macroFile"

    $cmdKey = 'HKCU:\Software\Microsoft\Command Processor'
    if (-not (Test-Path -LiteralPath $cmdKey)) {
        New-Item -Path $cmdKey -Force | Out-Null
    }
    $autoRunCmd = "doskey /macrofile=`"$macroFile`""
    $props = Get-ItemProperty -LiteralPath $cmdKey -ErrorAction SilentlyContinue
    $existingAutoRun = $null
    if ($props -and ($props.PSObject.Properties.Name -contains 'AutoRun')) {
        $existingAutoRun = $props.AutoRun
    }

    if ([string]::IsNullOrWhiteSpace($existingAutoRun)) {
        Set-ItemProperty -LiteralPath $cmdKey -Name AutoRun -Value $autoRunCmd
        Write-Ok 'Registered cmd AutoRun to load the macro'
    } elseif ($existingAutoRun -like "*$macroFile*") {
        Write-Ok 'cmd AutoRun already loads the macro'
    } else {
        # Chain onto whatever is already there rather than clobbering it.
        Set-ItemProperty -LiteralPath $cmdKey -Name AutoRun -Value "$existingAutoRun & $autoRunCmd"
        Write-Ok 'Appended the macro to the existing cmd AutoRun'
    }
} catch {
    Write-Warn "Could not set up the cmd macro: $($_.Exception.Message)"
}

Write-Info "Use 'dvcadd <path>' instead of 'dvc add <path>'. Open a new shell first."

# ----------------------------------------------------------------------------
# 8. Verify
# ----------------------------------------------------------------------------

Write-Step 'Verifying setup'
Invoke-Dvc -Arguments @('doctor') -AllowFailure

# End-to-end probe: the config says what we asked for, this shows what we got.
# A real 'dvc add' against the real cache path is the only way to know whether
# the workspace file ends up as a link or a full copy.
Write-Step 'Testing what dvc add actually produces'

$probeDir  = Join-Path $repoRoot ('dvc-linktest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$probeFile = Join-Path $probeDir 'sample.bin'
$gitignorePath = Join-Path $repoRoot '.gitignore'

# dvc add appends an ignore entry for the probe. Snapshot .gitignore so it can
# be restored afterwards - 'git checkout' cannot do this when the file is
# untracked, which is the case in a fresh repo.
$gitignoreBefore = if (Test-Path -LiteralPath $gitignorePath) {
    Get-Content -LiteralPath $gitignorePath -Raw
} else { $null }

try {
    New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
    # 8 MB of random bytes - big enough that a copy is measurable.
    $bytes = New-Object byte[] (8MB)
    (New-Object Random).NextBytes($bytes)
    [IO.File]::WriteAllBytes($probeFile, $bytes)

    Invoke-Dvc -Arguments @('add', $probeFile) -Capture | Out-Null
    # dvc add currently leaves copies behind (treeverse/dvc#10780), so relink
    # before inspecting - this mirrors what the dvcadd wrapper does.
    Invoke-Dvc -Arguments @('checkout', '--relink') -Capture -AllowFailure | Out-Null

    $item = Get-Item -LiteralPath $probeFile -Force
    $isLink = $item.Attributes -band [IO.FileAttributes]::ReparsePoint
    $isReadOnly = $item.Attributes -band [IO.FileAttributes]::ReadOnly

    if ($isLink) {
        $target = (Get-Item -LiteralPath $probeFile -Force).Target
        Write-Ok "Workspace file is a symlink -> $target"
        Write-Ok 'Confirmed: data stays in the shared cache, workstation holds no copy'
    } elseif ($isReadOnly) {
        Write-Ok 'Workspace file is a hardlink (read-only, same volume as cache)'
    } else {
        Write-Warn 'Workspace file is a full copy - linking did not take effect. Check cache.type and the cache volume filesystem.'
    }
} catch {
    Write-Warn "Link test could not complete: $($_.Exception.Message)"
} finally {
    # Clean up: remove the .dvc pointer, unprotect, and delete the probe.
    $probeDvc = "$probeFile.dvc"
    if (Test-Path -LiteralPath $probeDvc) {
        Invoke-Dvc -Arguments @('remove', $probeDvc) -AllowFailure -Capture | Out-Null
        Remove-Item -LiteralPath $probeDvc -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $probeDir) {
        Invoke-Dvc -Arguments @('unprotect', $probeFile) -AllowFailure -Capture | Out-Null
        Get-ChildItem -LiteralPath $probeDir -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Attributes = 'Normal' }
        Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $gitignoreBefore) {
        Set-Content -LiteralPath $gitignorePath -Value $gitignoreBefore -NoNewline
    } elseif (Test-Path -LiteralPath $gitignorePath) {
        Remove-Item -LiteralPath $gitignorePath -Force -ErrorAction SilentlyContinue
    }
    # core.autostage may have staged the probe's pointer file; unstage just it.
    & git reset -q -- $probeDvc 2>&1 | Out-Null
    Write-Info 'Probe files cleaned up'
}

Write-Host "`n--- Resulting configuration ---" -ForegroundColor Cyan
Invoke-Dvc -Arguments @('config', '--list') -AllowFailure

if ($script:Warnings.Count -gt 0) {
    Write-Host "`n--- Warnings ---" -ForegroundColor Yellow
    foreach ($w in $script:Warnings) { Write-Host "  * $w" -ForegroundColor Yellow }
}

Write-Host @"

--- Next steps ---

  1. Commit the DVC configuration:
       git add .dvc .gitignore
       git commit -m "Set up DVC"

  2. Start tracking your data (this moves it into the cache, so it can take a
     while the first time):
       dvc add data\raw
       git commit -m "Track raw data"
$(if ($haveRemote) { "
  3. Push the data to the remote:
       dvc push
" })
  3. Tell colleagues to run, after cloning:
       .\Setup-Dvc.ps1 -CacheDir '$CacheDir'
       dvc checkout
$(if ($haveRemote) { "
  4. Push a second copy to the remote:
       dvc push
" })
Notes:
  * Use 'dvcadd <path>', not 'dvc add <path>'. DVC 3.59+ leaves workspace files
    as copies instead of relinking them (treeverse/dvc#10780); the wrapper runs
    'dvc checkout --relink' afterwards. Open a new shell to pick it up.
  * Colleagues run 'dvc checkout', not 'dvc pull'. The shared cache already
    holds the data; checkout just creates the symlinks. The post-checkout hook
    does this automatically on branch switches.
  * Tracked files are read-only. Use 'dvc unprotect <path>' before editing one
    in place, then re-add it.
  * Cache: $CacheDir - this is the only copy of your data. Confirm it is
    backed up, and that the lab group has modify rights on it with inheritance.
  * Nobody should run 'dvc gc'. It deletes cache objects it cannot see a
    reference to, and it cannot see other people's repos. One careless gc
    destroys data other clones still depend on.
  * Reads go over the network, so analysis is slower than local disk. A single
    project can override with:  dvc config --local cache.dir .dvc\cache
  * Every user needs SeCreateSymbolicLinkPrivilege. Ask IT to grant it to a lab
    group via Group Policy; a direct grant survives UAC token filtering.
  * 'dvc add' on a directory of very many small files is slow. Archive first if
    you have tens of thousands.

"@ -ForegroundColor White
