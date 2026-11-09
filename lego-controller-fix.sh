#!/usr/bin/env bash
# lego-controller-fix.sh
#
# One package that applies the LEGO controller dedup fix to every
# applicable game on this machine. Games that are not installed, or have
# never been run under Proton, are skipped silently. That is by design:
# if you do not have the game, it just does not do that one.
#
# The bug: Wine DirectInput exposes one physical gamepad twice, as an
# "(event)" device and as a "(js)" device. TT-engine LEGO games latch
# onto both, so one pad becomes two players: phantom player 2, a single
# controller driving both characters, button prompts that break or stop
# rendering, and control settings that will not save. The same bug is
# documented on Windows, where one pad gets enumerated two ways by the
# drivers.
#
# The fix, per game prefix: one registry value under
#   HKCU\Software\Wine\DirectInput\Joysticks
#   "<Device Name> (js)" = "disabled"   (REG_SZ)
# which hides only the duplicate legacy-js node. The event node, the one
# games should use, stays fully working.
#
# Device names are NOT hardcoded. Input devices are read from
# /proc/bus/input/devices and classified as gamepad-class by name:
#   1. any interface of that name carries a js handler (js0, js1, ...),
#      the classic joystick node; OR
#   2. the name has an absolute-axis (EV_ABS) interface, but no mouse
#      handler and no relative-axis interface under the same name.
# Rule 2 exists because real gamepad hardware does not always bind a
# js node: a popular wireless headset dongle that enumerates as a
# gamepad-class, event-only device binds no js node at all (a system
# can have no js node anywhere), yet games still treat it as a
# controller. Rule 2's
# exclusions keep the false positives out: gaming mice and keyboards
# also expose absolute-axis interfaces, but always alongside a mouse
# handler or relative axes under the same name, while a pad has
# neither. Detection unions both rules and de-duplicates by name, and
# the disable entry is generated for every detected name, so the same
# package works on a machine whose pad is a headset dongle, an Xbox
# pad, or anything else.
#
# Safety properties:
#   - Idempotent: a prefix that already carries every value is reported
#     ALREADY and left untouched.
#   - A game that is currently running is reported SKIPPED-RUNNING and
#     never written. Running detection checks process command lines AND
#     process environments (WINEPREFIX= / STEAM_COMPAT_DATA_PATH=),
#     because command lines alone have been seen to miss live games.
#   - Writes go through a Proton/GE-Proton wine binary (protontricks is
#     deliberately not used; it hands off to winetricks and fails on
#     some machines), are flushed with wineserver -w, and are verified
#     by grepping the value back out of the prefix's user.reg.
#
# Usage:
#   lego-controller-fix.sh                 fix the built-in LEGO table
#   lego-controller-fix.sh --all-prefixes  fix every Proton prefix + ~/.wine
#   lego-controller-fix.sh --detect-only   show what would be targeted, change nothing
#   lego-controller-fix.sh --help
#
# Exit status: 0 normally, including "nothing to do" cases (no Steam,
# no gamepad, no target prefixes). Nonzero only when a write was
# attempted but could not be verified in user.reg afterwards.

set -u
export WINEDEBUG=-all

REG_KEY='HKCU\Software\Wine\DirectInput\Joysticks'

# ---------------------------------------------------------------------------
# Built-in title table (default mode)
#
# One row per title: appid | title | source
#   source "confirmed"   = public reports of the double-registration bug
#                          for this exact title (Steam discussions /
#                          ProtonDB report text, opened and read).
#   source "same-engine" = no title-specific report found; covered
#                          because it runs the same TT engine and input
#                          stack as the confirmed titles.
#
# Standing maintenance policy: when a new title is found to be affected,
# it gets added here as ONE new row and the tool is re-run. When a title
# already listed develops a controller problem, that gets investigated
# before any fix is claimed for it. See README.md, "Maintaining the
# title list".
# ---------------------------------------------------------------------------
LEGO_TITLES=(
    "578330|LEGO City Undercover|confirmed"
    "213330|LEGO Batman 2: DC Super Heroes|confirmed"
    "249130|LEGO Marvel Super Heroes|confirmed"
    "352400|LEGO Jurassic World|confirmed"
    "647830|LEGO Marvel Super Heroes 2|confirmed"
    "829110|LEGO DC Super-Villains|confirmed"
    "267530|The LEGO Movie Videogame|confirmed"
    "21000|LEGO Batman: The Videogame|same-engine"
    "313690|LEGO Batman 3: Beyond Gotham|same-engine"
    "405310|LEGO Marvel's Avengers|same-engine"
    "881320|The LEGO Movie 2 Videogame|same-engine"
    "818320|LEGO The Incredibles|same-engine"
)

MODE="lego"
case "${1:-}" in
    "") ;;
    --all-prefixes) MODE="all" ;;
    --detect-only) MODE="detect" ;;
    -h|--help)
        sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    *) echo "error: unknown argument '$1' (try --help)" >&2; exit 2 ;;
esac

log() { printf '%s\n' "$*"; }

# ------------------------------------------------------------ Steam roots ---
# Echo one deduplicated root per line. A root counts if it has steamapps.
steam_roots() {
    local c
    for c in \
        "$HOME/.local/share/Steam" \
        "$HOME/.steam/root" \
        "$HOME/.steam/steam" \
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
        [ -d "$c/steamapps" ] || continue
        realpath -m "$c" 2>/dev/null || printf '%s\n' "$c"
    done | awk '!seen[$0]++'
}

# ------------------------------------------------------------ libraries -----
# Echo one deduplicated library dir per line: every Steam root plus every
# "path" entry in each root's steamapps/libraryfolders.vdf.
steam_libraries() {
    local roots root vdf p
    roots="$(steam_roots)"
    [ -n "$roots" ] || return 0
    {
        printf '%s\n' "$roots"
        while IFS= read -r root; do
            vdf="$root/steamapps/libraryfolders.vdf"
            [ -f "$vdf" ] || continue
            grep '"path"' "$vdf" 2>/dev/null \
                | sed -E 's/.*"path"[[:space:]]*"([^"]*)".*/\1/'
        done <<< "$roots"
    } | while IFS= read -r p; do
            [ -n "$p" ] && [ -d "$p/steamapps" ] && { realpath -m "$p" 2>/dev/null || printf '%s\n' "$p"; }
          done | awk '!seen[$0]++'
}

# ------------------------------------------------------------ devices -------
# Echo gamepad-class device names, one per line. Classification (see
# header): a name counts when any of its interfaces carries a js
# handler, or when it has an EV_ABS interface but no mouse handler and
# no REL axes under the same name. EV_ABS is bit 3 of the B: EV= value,
# i.e. the low hex digit is 8..f.
detect_devices() {
    awk '
        /^N: Name=/ {
            name = $0
            sub(/^N: Name="/, "", name); sub(/"$/, "", name)
        }
        /^H: Handlers=/ {
            if (name == "") next
            if ($0 ~ /(^|[[:space:]])js[0-9]+([[:space:]]|$)/) js[name] = 1
            if ($0 ~ /(^|[[:space:]])mouse[0-9]+([[:space:]]|$)/) mouse[name] = 1
        }
        /^B: EV=/ {
            if (name == "") next
            ev = $0; sub(/^B: EV=/, "", ev)
            if (substr(ev, length(ev), 1) ~ /[89a-fA-F]/) abs[name] = 1
        }
        /^B: REL=/ { if (name != "") rel[name] = 1 }
        /^$/ { name = "" }
        END {
            for (n in js) print n
            for (n in abs) if (!(n in mouse) && !(n in rel)) print n
        }
    ' /proc/bus/input/devices 2>/dev/null | sort -u
}

# ------------------------------------------------------------ wine binary ---
# Prefer a GE-Proton build from compatibilitytools.d (the route proven
# to work for direct prefix writes), then any compat tool, then any
# Proton under steamapps/common, then system wine. Echo "<wine>|<srv>".
find_wine() {
    local -a cands=()
    local d
    shopt -s nullglob
    for d in "$HOME"/.local/share/Steam/compatibilitytools.d/GE-Proton*/; do
        [ -x "${d}files/bin/wine" ] && cands+=("${d}files/bin/wine")
    done
    for d in "$HOME"/.local/share/Steam/compatibilitytools.d/*/; do
        [ -x "${d}files/bin/wine" ] && cands+=("${d}files/bin/wine")
    done
    shopt -u nullglob
    if [ "${#cands[@]}" -gt 0 ]; then
        # newest GE-Proton / compat tool by version sort wins
        printf '%s\n' "${cands[@]}" | sort -Vu | tail -n 1
        return 0
    fi
    local lib
    while IFS= read -r lib; do
        shopt -s nullglob
        for d in "$lib"/steamapps/common/Proton*/; do
            if [ -x "${d}files/bin/wine" ]; then
                printf '%s\n' "${d}files/bin/wine"
                shopt -u nullglob
                return 0
            fi
        done
        shopt -u nullglob
    done <<< "$(steam_libraries)"
    command -v wine 2>/dev/null
}

WINE_BIN=""
WINESERVER_BIN=""
if [ "$MODE" != "detect" ]; then
    WINE_BIN="$(find_wine || true)"
    if [ -n "$WINE_BIN" ]; then
        ws="$(dirname "$WINE_BIN")/wineserver"
        [ -x "$ws" ] && WINESERVER_BIN="$ws" || WINESERVER_BIN="$(command -v wineserver || true)"
    fi
fi

# ------------------------------------------------- running-process snapshot -
# Snapshot cmdlines and environments once, up front, so running checks
# are consistent across all prefixes.
SNAP_CMD="$(mktemp)"; SNAP_ENV="$(mktemp)"
trap 'rm -f "$SNAP_CMD" "$SNAP_ENV"' EXIT
for f in /proc/[0-9]*/cmdline; do tr '\0' ' ' < "$f" 2>/dev/null; echo; done > "$SNAP_CMD" 2>/dev/null
for f in /proc/[0-9]*/environ; do tr '\0' '\n' < "$f" 2>/dev/null; done > "$SNAP_ENV" 2>/dev/null

# $1 = pfx path, $2 = appid ("" for non-compatdata prefixes)
prefix_active() {
    local pfx="$1" appid="${2:-}"
    if grep -qF "$pfx" "$SNAP_CMD" || grep -qF "WINEPREFIX=$pfx" "$SNAP_ENV"; then
        return 0
    fi
    if [ -n "$appid" ]; then
        if grep -qF "compatdata/$appid/" "$SNAP_CMD" || grep -qF "compatdata/$appid" "$SNAP_ENV"; then
            return 0
        fi
        if [ "$appid" != "0" ] && grep -qF "AppId=$appid" "$SNAP_CMD"; then
            return 0
        fi
    fi
    return 1
}

# -------------------------------------------- values for all detected pads -
# DEVICES fills from detect_devices; per-device helpers follow.
DEVICES=()
while IFS= read -r d; do [ -n "$d" ] && DEVICES+=("$d"); done <<< "$(detect_devices)"

value_present() { # $1 = user.reg path, $2 = device name
    [ -f "$1" ] && grep -qF "\"$2 (js)\"=\"disabled\"" "$1"
}

# Missing devices for a prefix: echoes one name per line.
missing_devices() { # $1 = pfx path
    local dev
    for dev in "${DEVICES[@]}"; do
        value_present "$1/user.reg" "$dev" || printf '%s\n' "$dev"
    done
}

HAD_FAILURE=0

# $1 = label, $2 = pfx path, $3 = appid (may be "")
process_prefix() {
    local label="$1" pfx="$2" appid="${3:-}"

    if [ "${#DEVICES[@]}" -eq 0 ]; then
        log "$label: NO-DEVICE (no gamepad-class device detected; nothing written)"
        return 0
    fi
    local missing
    missing="$(missing_devices "$pfx")"
    if [ -z "$missing" ]; then
        log "$label: ALREADY"
        return 0
    fi
    if prefix_active "$pfx" "$appid"; then
        log "$label: SKIPPED-RUNNING"
        return 0
    fi
    if [ -z "$WINE_BIN" ]; then
        log "$label: FAILED (no wine binary found: no GE-Proton, Proton, or system wine)"
        HAD_FAILURE=1
        return 0
    fi
    local dev err rc
    while IFS= read -r dev; do
        [ -n "$dev" ] || continue
        err=$(WINEPREFIX="$pfx" timeout 120 "$WINE_BIN" reg add "$REG_KEY" \
              /v "$dev (js)" /t REG_SZ /d disabled /f 2>&1)
        rc=$?
        if [ $rc -ne 0 ]; then
            log "$label: FAILED (reg add rc=$rc for '$dev (js)': $(printf '%s' "$err" | tail -n 1))"
            HAD_FAILURE=1
            return 0
        fi
    done <<< "$missing"
    # flush the registry to disk, then verify from user.reg
    if [ -n "$WINESERVER_BIN" ]; then
        WINEPREFIX="$pfx" timeout 60 "$WINESERVER_BIN" -w >/dev/null 2>&1
    fi
    local i
    for i in $(seq 1 10); do
        if [ -z "$(missing_devices "$pfx")" ]; then
            log "$label: FIXED"
            return 0
        fi
        sleep 1
    done
    log "$label: FAILED (value not present in user.reg after write)"
    HAD_FAILURE=1
}

# ------------------------------------------------------------- detection ----
ROOTS="$(steam_roots)"
LIBS="$(steam_libraries)"

if [ "$MODE" = "detect" ]; then
    log "== lego-controller-fix --detect-only (nothing will be changed) =="
    if [ -z "$ROOTS" ]; then
        log "Steam: not found (no Steam root with a steamapps folder)"
    else
        log "Steam roots:"
        printf '%s\n' "$ROOTS" | sed 's/^/  /'
        log "Steam libraries:"
        printf '%s\n' "$LIBS" | sed 's/^/  /'
    fi
    if [ "${#DEVICES[@]}" -eq 0 ]; then
        log "Gamepad-class devices: none detected in /proc/bus/input/devices"
    else
        log "Gamepad-class devices (names as Wine sees them):"
        for d in "${DEVICES[@]}"; do log "  $d"; done
        log "Disable entries that would be written per prefix:"
        for d in "${DEVICES[@]}"; do log "  \"$d (js)\" = \"disabled\""; done
    fi
    wb="$(find_wine || true)"
    [ -n "$wb" ] && log "Wine binary for writes: $wb" || log "Wine binary for writes: NONE FOUND"
    if [ -n "$LIBS" ]; then
        log "Target LEGO titles:"
        for row in "${LEGO_TITLES[@]}"; do
            IFS='|' read -r appid title src <<< "$row"
            present=""
            while IFS= read -r lib; do
                [ -d "$lib/steamapps/compatdata/$appid/pfx" ] && present="$lib/steamapps/compatdata/$appid/pfx"
            done <<< "$LIBS"
            if [ -n "$present" ]; then
                if prefix_active "$present" "$appid"; then state="present, RUNNING"
                else state="present"; fi
                log "  $title ($appid, $src): $state"
            else
                log "  $title ($appid, $src): not present (not installed, or never run under Proton)"
            fi
        done
    fi
    exit 0
fi

# ------------------------------------------------------------- no Steam -----
if [ -z "$LIBS" ]; then
    log "No Steam installation found on this machine; nothing to do."
    exit 0
fi

if [ "${#DEVICES[@]}" -eq 0 ]; then
    log "No gamepad-class device detected in /proc/bus/input/devices."
    log "Plug in (or connect) the controller you play with, then re-run."
    exit 0
fi
log "Devices: $(printf '%s; ' "${DEVICES[@]}" | sed 's/; $//')"
[ -n "$WINE_BIN" ] && log "Wine: $WINE_BIN" || log "Wine: none found (prefixes needing a write will FAIL)"

n_fixed=0; n_already=0; n_skipped=0; n_absent=0

tally() { # $1 = full output line
    case "$1" in
        *": FIXED") n_fixed=$((n_fixed+1)) ;;
        *": ALREADY") n_already=$((n_already+1)) ;;
        *": SKIPPED-RUNNING") n_skipped=$((n_skipped+1)) ;;
    esac
}

run_and_tally() { # runs process_prefix, tees its line, tallies it
    local out
    out="$(process_prefix "$@")"
    log "$out"
    tally "$out"
}

if [ "$MODE" = "lego" ]; then
    for row in "${LEGO_TITLES[@]}"; do
        IFS='|' read -r appid title src <<< "$row"
        found=0
        while IFS= read -r lib; do
            pfx="$lib/steamapps/compatdata/$appid/pfx"
            [ -d "$pfx" ] || continue
            found=1
            run_and_tally "$title ($appid)" "$pfx" "$appid"
        done <<< "$LIBS"
        [ "$found" -eq 0 ] && n_absent=$((n_absent+1))
    done
    log "Summary: $n_fixed fixed, $n_already already, $n_skipped skipped (running), $n_absent not present."
else
    # --all-prefixes: every compatdata prefix in every library, plus ~/.wine
    shopt -s nullglob
    seen_any=0
    while IFS= read -r lib; do
        for appdir in "$lib"/steamapps/compatdata/*/; do
            appid="$(basename "$appdir")"
            pfx="${appdir}pfx"
            [ -d "$pfx" ] || continue
            seen_any=1
            run_and_tally "APPID $appid" "$pfx" "$appid"
        done
    done <<< "$LIBS"
    if [ -d "$HOME/.wine" ]; then
        seen_any=1
        run_and_tally "HOME-WINE (~/.wine)" "$HOME/.wine" ""
    fi
    shopt -u nullglob
    [ "$seen_any" -eq 0 ] && log "No Proton prefixes found in any library."
    log "Summary: $n_fixed fixed, $n_already already, $n_skipped skipped (running)."
fi

[ "$HAD_FAILURE" -eq 0 ] || exit 1
exit 0
