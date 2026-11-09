#!/usr/bin/env bash
# install.sh: install the LEGO controller dedup fix tool.
#
# What it does: one thing. It copies lego-controller-fix.sh into
# ~/.local/bin/lego-controller-fix and prints usage. There are no
# dependencies to install and nothing distro-specific about the tool
# itself (plain bash, procfs, grep/sed/awk, and whatever Proton wine
# binary the target machine already has), so this installer is the same
# on Arch, Debian, Fedora, or anything else.
#
# It does NOT run the fix. Run `lego-controller-fix` yourself after
# installing, ideally right after a new game has been launched once
# under Proton so its prefix exists.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"

log() { printf 'install: %s\n' "$*"; }
die() { printf 'install: error: %s\n' "$*" >&2; exit 1; }

[ -f "$HERE/lego-controller-fix.sh" ] || die "lego-controller-fix.sh not found next to install.sh"

mkdir -p "$HOME/.local/bin"
install -m 0755 "$HERE/lego-controller-fix.sh" "$HOME/.local/bin/lego-controller-fix"
log "installed: ~/.local/bin/lego-controller-fix"

case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) log "note: ~/.local/bin is not in your PATH; add it or call the tool by full path." ;;
esac

log "usage:"
log "  lego-controller-fix               fix the built-in LEGO title table"
log "  lego-controller-fix --all-prefixes  fix every discovered prefix, all layers"
log "  lego-controller-fix --prefix <path>  fix one explicitly named prefix"
log "  lego-controller-fix --detect-only   show what would be targeted, change nothing"
log "  lego-controller-fix --discover-only  list every prefix and its layer, change nothing"
log "re-run it after installing or first-launching another LEGO game;"
log "prefixes are only created the first time a game runs under Proton."
