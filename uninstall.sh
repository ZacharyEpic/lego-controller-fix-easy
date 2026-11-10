#!/usr/bin/env bash
# uninstall.sh: remove the installed LEGO controller dedup fix tool.
#
# What it does: one thing. It deletes ~/.local/bin/lego-controller-fix,
# the copy install.sh put there. Nothing else is removed: the package
# files in this folder stay where they are, and this script does NOT
# undo the registry changes the tool wrote into your game prefixes.
#
# To undo those registry changes as well, run this BEFORE uninstalling:
#   lego-controller-fix --remove --all-prefixes
# (--remove on its own only covers the built-in LEGO title table; see
# the tool's --help.) Already uninstalled the tool first? Re-run
# install.sh, run the --remove command above, then uninstall again.

set -eu

log() { printf 'uninstall: %s\n' "$*"; }
die() { printf 'uninstall: error: %s\n' "$*" >&2; exit 1; }

TARGET="$HOME/.local/bin/lego-controller-fix"

if [ -d "$TARGET" ]; then
    die "$TARGET is a directory, not the installed tool; refusing to remove it"
fi

if [ -f "$TARGET" ]; then
    rm -f "$TARGET"
    log "removed: ~/.local/bin/lego-controller-fix"
else
    log "not installed: ~/.local/bin/lego-controller-fix does not exist; nothing to do"
fi

log "note: this does not undo the fix in your game prefixes."
log "to remove the applied registry changes, run (before uninstalling):"
log "  lego-controller-fix --remove --all-prefixes"
log "already uninstalled? re-run install.sh first, then the command above."
