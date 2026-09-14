#!/usr/bin/env bash
#
# setup-dvc.sh - install and configure DVC with a shared cache.
#
# Run from the root of your git repository. Idempotent: re-running verifies and
# corrects settings rather than failing.
#
#   1. Verify it is running from a git repository root
#   2. Install DVC (pipx, then pip --user)
#   3. Run 'dvc init' if needed
#   4. Point the cache at the shared location and pick the best link type
#   5. Optionally configure a remote for 'dvc push' / 'dvc pull'
#   6. Install git hooks, including the post-merge/post-rewrite ones DVC omits
#   7. Install a 'dvcadd' shell wrapper (works around treeverse/dvc#10780)
#   8. Prove what 'dvc add' actually produces, with a real add against the cache
#
# Usage:
#   ./setup-dvc.sh --cache-dir /mnt/lab/dvc-cache
#   ./setup-dvc.sh --cache-dir /mnt/lab/dvc-cache --remote ssh://backup/dvc
#   ./setup-dvc.sh --cache-dir '' --remote s3://bucket/dvc   # repo-local cache
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults and argument parsing
# ----------------------------------------------------------------------------

CACHE_DIR="/mnt/lab/dvc-cache"
REMOTE_URL=""
REMOTE_NAME="storage"
CACHE_GROUP=""
ALLOW_COPY=0
SKIP_INSTALL=0
NEED_PATH_LINE=0

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cache-dir)   CACHE_DIR="${2:-}"; shift 2 ;;
        --remote)      REMOTE_URL="${2:-}"; shift 2 ;;
        --remote-name) REMOTE_NAME="${2:-}"; shift 2 ;;
        --group)       CACHE_GROUP="${2:-}"; shift 2 ;;
        --allow-copy)  ALLOW_COPY=1; shift ;;
        --skip-install) SKIP_INSTALL=1; shift ;;
        -h|--help)     usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m';  C_GRAY=$'\033[90m';  C_OFF=$'\033[0m'
else
    C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_GRAY=''; C_OFF=''
fi

WARNINGS=()

step() { printf '\n%s==> %s%s\n' "$C_CYAN" "$1" "$C_OFF"; }
ok()   { printf '    %s[ok]   %s%s\n' "$C_GREEN" "$1" "$C_OFF"; }
info() { printf '    %s[info] %s%s\n' "$C_GRAY" "$1" "$C_OFF"; }
warn() { printf '    %s[warn] %s%s\n' "$C_YELLOW" "$1" "$C_OFF"; WARNINGS+=("$1"); }
fail() { printf '    %s[fail] %s%s\n' "$C_RED" "$1" "$C_OFF"; }

have() { command -v "$1" >/dev/null 2>&1; }

# dvc_config [--local] KEY VALUE - set only if different, report which happened.
dvc_config() {
    local scope=() where=""
    if [[ "${1:-}" == "--local" ]]; then scope=(--local); where=" [local]"; shift; fi
    local key="$1" value="$2" current
    current="$(dvc config "${scope[@]}" "$key" 2>/dev/null || true)"
    if [[ "$current" == "$value" ]]; then
        ok "$key = $value$where (already set)"
        return 1
    fi
    dvc config "${scope[@]}" "$key" "$value"
    ok "$key = $value$where"
    return 0
}

# ----------------------------------------------------------------------------
# 1. Sanity checks
# ----------------------------------------------------------------------------

step 'Checking environment'

if [[ ! -d .git ]]; then
    fail 'No .git directory here. Run this script from the root of your repository.'
    exit 1
fi
REPO_ROOT="$(pwd -P)"
ok "Repository root: $REPO_ROOT"

if ! have git; then
    fail 'git was not found on PATH.'
    exit 1
fi
ok "git $(git --version | sed 's/^git version //')"

# ----------------------------------------------------------------------------
# 2. Install DVC
# ----------------------------------------------------------------------------

STANDALONE_HINT='Alternatively install a self-contained build, which bundles its own Python:
    https://dvc.org/doc/install/linux
Then re-run this script with --skip-install.'

if (( SKIP_INSTALL )); then
    step 'Skipping DVC installation (--skip-install)'
else
    step 'Installing DVC'

    if have dvc; then
        info 'DVC already present - leaving it as it is'
        info 'Upgrade separately with "pipx upgrade dvc", your package manager, or the standalone build'
    else
        # A python on PATH is not necessarily a working python. Importing a
        # stdlib module is a far better test than --version.
        PYTHON=""
        PYVER=""
        for candidate in python3 python; do
            have "$candidate" || continue
            if ! ver="$("$candidate" -c \
                'import encodings,sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' \
                2>/dev/null)"; then
                info "$candidate is present but not usable - skipping"
                continue
            fi
            # DVC needs 3.9+. No upper bound: a missing wheel shows up as a
            # clear install failure rather than something to pre-empt.
            if [[ "$(printf '%s\n3.9\n' "$ver" | sort -V | head -1)" != "3.9" ]]; then
                info "$candidate is Python $ver - too old for DVC (needs 3.9+)"
                continue
            fi
            PYTHON="$candidate"; PYVER="$ver"; break
        done

        if [[ -z "$PYTHON" ]]; then
            fail "No usable Python 3.9 or newer was found."
            printf '%s\n' "$STANDALONE_HINT"
            exit 1
        fi
        ok "Using $PYTHON (Python $PYVER)"

        # pipx itself runs on some interpreter, which may be the broken one.
        PIPX_OK=0
        if have pipx && pipx --version >/dev/null 2>&1; then
            PIPX_OK=1
        elif have pipx; then
            warn 'pipx is on PATH but does not run - falling back to pip'
        fi

        if (( PIPX_OK )); then
            info 'Installing via pipx (isolated environment - preferred)'
            pipx install dvc
        else
            info 'Installing via pip --user'
            "$PYTHON" -m pip install --user --upgrade dvc
        fi

        # pip --user puts console scripts in ~/.local/bin, which is often not
        # on PATH. Ubuntu's ~/.profile adds it, but only at login and only if
        # the directory already existed then - which it did not, until now.
        export PATH="$HOME/.local/bin:$PATH"
        NEED_PATH_LINE=1
    fi
fi

if ! have dvc; then
    export PATH="$HOME/.local/bin:$PATH"
    if ! have dvc; then
        fail 'DVC is installed but not on PATH. Run:'
        printf '    echo %s >> ~/.bashrc && source ~/.bashrc\n' \
               "'export PATH=\"\$HOME/.local/bin:\$PATH\"'"
        printf '  then re-run this script with --skip-install.\n'
        exit 1
    fi
fi

if ! DVC_VERSION="$(dvc --version 2>&1)"; then
    fail "'dvc' is on PATH but will not run:"
    printf '%s\n' "$DVC_VERSION"
    printf '%s\n' "$STANDALONE_HINT"
    exit 1
fi
ok "dvc $DVC_VERSION"

# ----------------------------------------------------------------------------
# 3. dvc init
# ----------------------------------------------------------------------------

step 'Initialising DVC in this repository'

if [[ -f .dvc/config ]]; then
    ok '.dvc already exists - leaving it alone'
else
    dvc init >/dev/null
    ok 'Created .dvc/ - remember to commit it'
fi

# ----------------------------------------------------------------------------
# 4. Cache
# ----------------------------------------------------------------------------

SHARED_CACHE=0
[[ -n "$CACHE_DIR" ]] && SHARED_CACHE=1

if (( ! SHARED_CACHE )); then
    step 'Configuring cache (repo-local)'
    CACHE_DIR="$REPO_ROOT/.dvc/cache"
    mkdir -p "$CACHE_DIR"
    ok 'Cache stays at .dvc/cache - hardlinks and reflinks will work'
else
    step "Configuring shared cache at $CACHE_DIR"

    if [[ ! -d "$CACHE_DIR" ]]; then
        mkdir -p "$CACHE_DIR" || { fail "Cannot create $CACHE_DIR"; exit 1; }
        ok "Created $CACHE_DIR"
    else
        ok "$CACHE_DIR exists"
    fi

    probe="$CACHE_DIR/.dvc-write-probe-$$"
    if : > "$probe" 2>/dev/null; then
        rm -f "$probe"
        ok 'Cache directory is writable'
    else
        fail "Cannot write to $CACHE_DIR - check permissions."
        exit 1
    fi

    # cache.dir goes in .dvc/config.local, which is gitignored. The committed
    # .dvc/config must stay platform-neutral: Windows needs a UNC path and
    # Linux needs a mount point, and one string cannot be both.
    dvc_config --local cache.dir "$CACHE_DIR" || true

    if [[ -f "$REPO_ROOT/.dvc/config" ]] && grep -Eq '^[[:space:]]*dir[[:space:]]*=' "$REPO_ROOT/.dvc/config"; then
        warn 'The committed .dvc/config sets cache.dir. Remove it so other platforms are not overridden:  dvc config --unset cache.dir'
    fi

    # Unlike Windows, POSIX permissions actually matter here. 'shared group'
    # makes DVC create cache files group-writable; the setgid bit makes new
    # entries inherit the directory's group.
    dvc_config cache.shared group || true

    if [[ -n "$CACHE_GROUP" ]]; then
        if chgrp -R "$CACHE_GROUP" "$CACHE_DIR" 2>/dev/null; then
            chmod -R g+rwXs "$CACHE_DIR" 2>/dev/null || true
            ok "Cache group set to $CACHE_GROUP with setgid"
        else
            warn "Could not chgrp $CACHE_DIR to $CACHE_GROUP - ask an admin to do it"
        fi
    else
        info 'No --group given. For a multi-user cache, run:'
        info "    sudo chgrp -R <labgroup> $CACHE_DIR && sudo chmod -R g+rwXs $CACHE_DIR"
    fi

    # Detect network filesystems, where DVC's default lock misbehaves.
    fstype="$(stat -f -c %T "$CACHE_DIR" 2>/dev/null || echo unknown)"
    ok "Cache filesystem: $fstype"
    case "$fstype" in
        nfs*|smb*|cifs*|fuseblk|autofs)
            dvc_config core.hardlink_lock true || true
            info 'Network filesystem detected - enabled core.hardlink_lock'
            ;;
    esac
fi

# --- Decide the link type -----------------------------------------------------
# reflink:  copy-on-write, safe to edit, same filesystem only (btrfs, XFS, ZFS)
# hardlink: same filesystem only, shares the inode
# symlink:  works across filesystems, and is the only type that leaves the
#           bytes on the server rather than materialising them locally
# copy:     always works, uses the space twice
#
# DVC makes hardlinked and symlinked files read-only automatically. Use
# 'dvc unprotect <path>' before editing one in place.

# Compare device IDs rather than paths - a bind mount or symlinked path can
# make two different-looking paths live on the same filesystem, and vice versa.
dev_of() { stat -c %d "$1" 2>/dev/null || echo "?"; }
same_fs=0
[[ "$(dev_of "$CACHE_DIR")" == "$(dev_of "$REPO_ROOT")" ]] && same_fs=1

# Symlink creation needs no privilege on Linux, but check anyway: a read-only
# or exotic filesystem can still refuse.
can_symlink=0
tmpd="$(mktemp -d)"
if ln -s "$tmpd" "$tmpd.link" 2>/dev/null; then
    can_symlink=1
    rm -f "$tmpd.link"
fi
rmdir "$tmpd" 2>/dev/null || true

if (( SHARED_CACHE )); then
    if (( can_symlink )); then
        LINK_TYPE="symlink,copy"
        ok 'Symlinks work - workspace files will point at the cache, using no local disk'
    else
        LINK_TYPE="copy"
        msg='Symlink creation failed, so DVC would copy every file into the workspace.
A shared cache saves nothing in that state. Check that the workspace filesystem
is writable and supports symlinks.'
        if (( ALLOW_COPY )); then
            warn "$msg"
        else
            fail "$msg"
            info 'Re-run with --allow-copy to proceed anyway, or with --cache-dir "" for a repo-local cache plus a remote.'
            exit 1
        fi
    fi
elif (( same_fs )); then
    LINK_TYPE="reflink,hardlink,symlink,copy"
    ok 'Cache is on the same filesystem as the repo - reflinks or hardlinks will be used'
else
    LINK_TYPE="symlink,copy"
    ok 'Cache is on a different filesystem - symlinks will be used'
fi

link_changed=0
dvc_config cache.type "$LINK_TYPE" && link_changed=1

# Auto-stage .dvc files so they are not forgotten at commit time.
dvc_config core.autostage true || true

if (( link_changed )) && compgen -G "*.dvc" >/dev/null 2>&1; then
    info 'Link type changed - relinking existing data from cache'
    dvc checkout --relink >/dev/null 2>&1 || true
fi

# ----------------------------------------------------------------------------
# 5. Remote
# ----------------------------------------------------------------------------

step 'Configuring remote storage'

HAVE_REMOTE=0
if [[ -z "$REMOTE_URL" ]]; then
    if (( SHARED_CACHE )); then
        info 'No --remote given. Not required with a shared cache - colleagues get data by checkout, not pull.'
        warn "The cache at $CACHE_DIR is now the only copy of your data. Confirm it is backed up."
    else
        warn 'No --remote given. With a repo-local cache your data exists only on this machine.'
    fi
else
    # Create local-path remotes up front; DVC will not do it for you.
    if [[ "$REMOTE_URL" != *://* ]]; then
        mkdir -p "$REMOTE_URL"
        if [[ "$(readlink -f "$REMOTE_URL")" == "$(readlink -f "$CACHE_DIR")" ]]; then
            warn 'Remote and cache point at the same directory. Use separate paths, or push becomes a no-op.'
        fi
    fi
    dvc remote add --default --force "$REMOTE_NAME" "$REMOTE_URL"
    ok "Default remote '$REMOTE_NAME' -> $REMOTE_URL"
    HAVE_REMOTE=1
fi

# ----------------------------------------------------------------------------
# 6. Git hooks
# ----------------------------------------------------------------------------

step 'Installing git hooks'

# 'dvc install' adds post-checkout, pre-commit and pre-push, with no way to
# select. It refuses to overwrite, so a re-run reports "already exists".
if ! hook_out="$(dvc install 2>&1)"; then
    if [[ "$hook_out" == *"already exists"* ]]; then
        ok 'Hooks were already installed'
    else
        warn "dvc install failed: $hook_out"
    fi
fi

HOOKS_DIR="$(git rev-parse --git-path hooks 2>/dev/null || echo .git/hooks)"
[[ "$HOOKS_DIR" != /* ]] && HOOKS_DIR="$REPO_ROOT/$HOOKS_DIR"
mkdir -p "$HOOKS_DIR"

# DVC omits two hooks that matter: 'git pull' fast-forwards via a merge
# (post-merge), and 'git pull --rebase' rewrites history (post-rewrite).
# Neither fires post-checkout, so pulled data would not appear until the next
# branch switch.
for hook in post-merge post-rewrite; do
    path="$HOOKS_DIR/$hook"
    if [[ -e "$path" ]]; then
        if grep -q 'dvc[[:space:]]\+checkout' "$path" 2>/dev/null; then
            ok "$hook hook already present"
        else
            warn "An existing $hook hook was left alone. Add 'dvc checkout' to it manually."
        fi
        continue
    fi
    printf '#!/bin/sh\nexec dvc checkout\n' > "$path"
    chmod +x "$path"
    ok "$hook hook installed (keeps 'git pull' in sync)"
done

# With a shared cache and no remote there is nothing to push, and a failing
# pre-push hook aborts 'git push'.
if (( HAVE_REMOTE )); then
    ok 'post-checkout, pre-commit and pre-push hooks in place'
else
    pre_push="$HOOKS_DIR/pre-push"
    if [[ -e "$pre_push" ]]; then
        # Current DVC writes 'dvc git-hook pre-push'; older wrote 'dvc push'.
        if grep -Eq 'dvc[[:space:]]+(git-hook[[:space:]]+pre-push|push)' "$pre_push"; then
            rm -f "$pre_push"
            ok 'post-checkout and pre-commit hooks in place'
            info 'pre-push hook removed - no remote configured, so there is nothing to push'
        else
            warn "An existing pre-push hook at $pre_push was left alone because it is not DVC's."
        fi
    fi
fi

# ----------------------------------------------------------------------------
# 7. .gitignore hygiene
# ----------------------------------------------------------------------------

step 'Checking .gitignore'

added=()
for line in '/.dvc/cache' '/.dvc/tmp' '/.dvc/config.local'; do
    if ! grep -qxF "$line" .gitignore 2>/dev/null; then
        added+=("$line")
    fi
done
if (( ${#added[@]} )); then
    { printf '\n# DVC\n'; printf '%s\n' "${added[@]}"; } >> .gitignore
    ok "Added to .gitignore: ${added[*]}"
else
    ok 'Already covers the DVC local files'
fi

# ----------------------------------------------------------------------------
# 7b. 'dvcadd' wrapper
# ----------------------------------------------------------------------------

# DVC 3.59+ regressed: 'dvc add' leaves workspace files as copies instead of
# relinking them from the cache (treeverse/dvc#10780). Until that is fixed,
# every add needs a follow-up 'dvc checkout --relink'.
# Remove this section once upstream fixes the regression.

step "Installing 'dvcadd' wrapper"

MARKER='# >>> dvcadd (DVC #10780 workaround) >>>'
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
read -r -d '' WRAPPER <<EOF || true

$MARKER
dvcadd() {
    dvc add "\$@" && dvc checkout --relink
}
# <<< dvcadd <<<
EOF

installed_to=()
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -e "$rc" ]] || continue

    # Without this, a pip --user install leaves 'dvc' off PATH in new shells.
    if (( NEED_PATH_LINE )) && ! grep -qF '.local/bin' "$rc"; then
        printf '\n# Added by setup-dvc.sh: pip --user installs console scripts here\n%s\n' \
            "$PATH_LINE" >> "$rc"
        ok "Added ~/.local/bin to PATH in $rc"
    fi

    if grep -qF "$MARKER" "$rc"; then
        ok "$(basename "$rc") already has dvcadd"
    else
        printf '%s\n' "$WRAPPER" >> "$rc"
        installed_to+=("$rc")
        ok "Added dvcadd to $rc"
    fi
done
if (( ${#installed_to[@]} == 0 )) && [[ ! -e "$HOME/.bashrc" && ! -e "$HOME/.zshrc" ]]; then
    warn 'Found neither ~/.bashrc nor ~/.zshrc - add the dvcadd function to your shell rc manually.'
fi
info "Use 'dvcadd <path>' instead of 'dvc add <path>'. Open a new shell first."

# ----------------------------------------------------------------------------
# 8. Verify
# ----------------------------------------------------------------------------

step 'Verifying setup'
dvc doctor || true

# The config says what we asked for; this shows what we got. A real add against
# the real cache path is the only way to know whether the workspace file ends
# up as a link or a full copy.
step 'Testing what dvc add actually produces'

PROBE_DIR="$REPO_ROOT/dvc-linktest-$$"
PROBE_FILE="$PROBE_DIR/sample.bin"
GITIGNORE_BACKUP="$(mktemp)"
[[ -f .gitignore ]] && cp .gitignore "$GITIGNORE_BACKUP"

cleanup_probe() {
    [[ -e "$PROBE_FILE.dvc" ]] && { dvc remove "$PROBE_FILE.dvc" >/dev/null 2>&1 || true; }
    rm -f "$PROBE_FILE.dvc"
    if [[ -d "$PROBE_DIR" ]]; then
        dvc unprotect "$PROBE_FILE" >/dev/null 2>&1 || true
        chmod -R u+w "$PROBE_DIR" 2>/dev/null || true
        rm -rf "$PROBE_DIR"
    fi
    if [[ -s "$GITIGNORE_BACKUP" ]]; then
        cp "$GITIGNORE_BACKUP" .gitignore
    elif [[ -f .gitignore ]] && [[ ! -s "$GITIGNORE_BACKUP" ]]; then
        rm -f .gitignore
    fi
    rm -f "$GITIGNORE_BACKUP"
    git reset -q -- "$PROBE_FILE.dvc" >/dev/null 2>&1 || true
    info 'Probe files cleaned up'
}
trap cleanup_probe EXIT

mkdir -p "$PROBE_DIR"
head -c 8388608 /dev/urandom > "$PROBE_FILE"

if dvc add "$PROBE_FILE" >/dev/null 2>&1; then
    # dvc add currently leaves copies behind, so relink before inspecting.
    dvc checkout --relink >/dev/null 2>&1 || true

    if [[ -L "$PROBE_FILE" ]]; then
        ok "Workspace file is a symlink -> $(readlink "$PROBE_FILE")"
        ok 'Confirmed: data stays in the shared cache, workstation holds no copy'
    elif [[ "$(stat -c %h "$PROBE_FILE")" -gt 1 ]]; then
        ok "Workspace file is a hardlink or reflink (link count $(stat -c %h "$PROBE_FILE"))"
    elif [[ ! -w "$PROBE_FILE" ]]; then
        ok 'Workspace file is read-only, so DVC linked it (likely a reflink)'
    else
        warn 'Workspace file is a full copy - linking did not take effect. Check cache.type and the cache filesystem.'
    fi
else
    warn 'Link test could not complete - dvc add failed'
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------

printf '\n%s--- Resulting configuration ---%s\n' "$C_CYAN" "$C_OFF"
dvc config --list || true

if (( ${#WARNINGS[@]} )); then
    printf '\n%s--- Warnings ---%s\n' "$C_YELLOW" "$C_OFF"
    for w in "${WARNINGS[@]}"; do printf '  %s* %s%s\n' "$C_YELLOW" "$w" "$C_OFF"; done
fi

cat <<EOF

--- Next steps ---

  1. Commit the DVC configuration:
       git add .dvc .gitignore
       git commit -m "Set up DVC"

  2. Start tracking your data (this moves it into the cache, so the first run
     can take a while):
       dvcadd data/raw
       git commit -m "Track raw data"

  3. Tell colleagues to run, after cloning:
       ./setup-dvc.sh --cache-dir '$CACHE_DIR'
       dvc checkout
$( ((HAVE_REMOTE)) && printf '
  4. Push a second copy to the remote:
       dvc push
' )
Notes:
  * Use 'dvcadd <path>', not 'dvc add <path>'. DVC 3.59+ leaves workspace files
    as copies instead of relinking them (treeverse/dvc#10780); the wrapper runs
    'dvc checkout --relink' afterwards. Open a new shell to pick it up.
  * Colleagues run 'dvc checkout', not 'dvc pull'. The shared cache already
    holds the data; checkout just creates the links. The hooks do this
    automatically on checkout, merge and rebase.
  * Tracked files are read-only. Use 'dvc unprotect <path>' before editing one
    in place, then re-add it.
  * Cache: $CACHE_DIR
  * Nobody should run 'dvc gc'. It deletes cache objects it cannot see a
    reference to, and it cannot see other people's repos.
  * Set umask 002 in your shell rc so new cache files stay group-writable.
  * Reads go over the network if the cache is a network mount. A single project
    can override with:  dvc config --local cache.dir .dvc/cache
  * 'dvc add' on a directory of very many small files is slow. Archive first if
    you have tens of thousands.

EOF
