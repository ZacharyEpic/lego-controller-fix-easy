#!/usr/bin/env bash
# lego-controller-fix.sh
#
# One package that applies the LEGO controller dedup fix to every
# applicable game on this machine. Games that are not installed, or have
# never been run, are skipped silently. That is by design: if you do not
# have the game, it just does not do that one.
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
# Layers: a game that misbehaves on one Proton version may be moved to
# another Windows compatibility layer, and the fix has to follow it.
# Beyond Steam compatdata, --all-prefixes also discovers prefixes owned
# by Bottles, Lutris, Heroic, and plain Wine installs. A directory
# counts as a prefix when it contains both user.reg and drive_c; the
# layer label for each prefix is assigned from the best evidence
# available (owning app's config files first, then install location)
# and reported as "unknown" when the evidence does not decide it.
# Writes to a prefix use the wine binary that belongs to the owning
# layer when one is installed (Bottles, Lutris, and Heroic each keep
# their own runners), falling back to GE-Proton, then any Proton, then
# system wine. The wineserver used always sits next to the chosen wine.
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
# controller. Rule 2's exclusions keep the false positives out: gaming
# mice and keyboards also expose absolute-axis interfaces, but always
# alongside a mouse handler or relative axes under the same name, while
# a pad has neither. Detection unions both rules and de-duplicates by
# name, and the disable entry is generated for every detected name, so
# the same package works on a machine whose pad is a headset dongle, an
# Xbox pad, or anything else.
#
# LEGO_FIX_DEVICES (comma or semicolon separated device names) replaces
# auto-detection when set. It exists for testing and for pads that are
# not connected at run time. Unset, detection works as described above.
#
# Safety properties:
#   - Idempotent: a prefix that already carries every value is reported
#     ALREADY and left untouched.
#   - A game that is currently running is reported SKIPPED-RUNNING and
#     never written. Running detection checks process command lines AND
#     process environments (WINEPREFIX= / STEAM_COMPAT_DATA_PATH=),
#     because command lines alone have been seen to miss live games.
#     This applies to prefixes on every layer.
#   - Writes go through a wine binary directly (protontricks is
#     deliberately not used; it hands off to winetricks and fails on
#     some machines), are flushed with wineserver -w, and are verified
#     by grepping the value back out of the prefix's user.reg.
#   - --detect-only and --discover-only change nothing at all.
#
# Usage:
#   lego-controller-fix.sh                    fix the built-in LEGO table (Steam)
#   lego-controller-fix.sh --all-prefixes     fix every discovered prefix, all layers
#   lego-controller-fix.sh --prefix <path>    fix one explicitly named prefix
#   lego-controller-fix.sh --detect-only      show LEGO/Steam targets, change nothing
#   lego-controller-fix.sh --discover-only    list every prefix, its layer and fix
#                                             state, change nothing
#   lego-controller-fix.sh --help
#
# Exit status: 0 normally, including "nothing to do" cases (no layers
# found, no gamepad, no target prefixes). 2 for usage errors, including
# a --prefix path that is not a Wine prefix. Nonzero (1) when a write
# was attempted but could not be verified in user.reg afterwards.

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
PREFIX_ARG=""
n_mode_flags=0
while [ $# -gt 0 ]; do
    case "$1" in
        --all-prefixes) MODE="all"; n_mode_flags=$((n_mode_flags+1)) ;;
        --detect-only) MODE="detect"; n_mode_flags=$((n_mode_flags+1)) ;;
        --discover-only) MODE="discover"; n_mode_flags=$((n_mode_flags+1)) ;;
        --prefix)
            MODE="prefix"; n_mode_flags=$((n_mode_flags+1))
            shift
            [ $# -gt 0 ] || { echo "error: --prefix needs a path argument" >&2; exit 2; }
            PREFIX_ARG="$1" ;;
        -h|--help)
            awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
            exit 0 ;;
        *) echo "error: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
    shift
done
if [ "$n_mode_flags" -gt 1 ]; then
    echo "error: choose only one of --all-prefixes, --prefix, --detect-only, --discover-only" >&2
    exit 2
fi

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
# are consistent across all prefixes. Processes carrying this tool's
# own command line are excluded: --prefix names its target on the
# command line, and counting ourselves would make every --prefix run
# look like its target was already running.
SNAP_CMD="$(mktemp)"; SNAP_ENV="$(mktemp)"
trap 'rm -f "$SNAP_CMD" "$SNAP_ENV"' EXIT
SELF_CMD="$(tr '\0' ' ' < /proc/$$/cmdline 2>/dev/null)"
for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    c="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
    [ -n "$c" ] || continue
    [ "$c" = "$SELF_CMD" ] && continue
    printf '%s\n' "$c" >> "$SNAP_CMD"
    ( tr '\0' '\n' < "$d/environ" ) 2>/dev/null >> "$SNAP_ENV"
done

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

# ------------------------------------------------------- layer discovery ----
# A directory is a Wine prefix when it holds both user.reg and drive_c.
is_prefix_dir() {
    [ -f "$1/user.reg" ] && [ -d "$1/drive_c" ]
}

# Prefix paths named by Lutris game configs. Lutris writes the prefix
# into each game's yml file; games installed through Lutris can keep
# their prefix anywhere, so these paths are discovery evidence even
# outside the generic scan roots below.
lutris_yml_prefixes() {
    local f line p
    shopt -s nullglob
    for f in "$HOME"/.config/lutris/games/*.yml \
             "$HOME"/.var/app/net.lutris.Lutris/config/lutris/games/*.yml; do
        line="$(grep -E '^[[:space:]]*prefix:' "$f" 2>/dev/null | head -n 1)"
        [ -n "$line" ] || continue
        p="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*prefix:[[:space:]]*//')"
        p="${p%\"}"; p="${p#\"}"; p="${p%\'}"; p="${p#\'}"
        p="$(printf '%s' "$p" | sed -E 's/[[:space:]]+$//')"
        case "$p" in
            "~/"*) p="$HOME/${p:2}" ;;
            '$HOME/'*) p="$HOME/${p:6}" ;;
        esac
        [ -n "$p" ] && printf '%s\n' "$p"
    done
    shopt -u nullglob
}
LUTRIS_PREFIXES="$(lutris_yml_prefixes | awk '!seen[$0]++')"

# Layer label for a prefix path, from the best evidence available:
# Steam compatdata layout, then Lutris game configs, then the owning
# app's install location (the Wine project's own Flatpak counts as
# plain Wine). "unknown" when nothing decides it; the label is
# evidence, never a guess dressed up as fact.
label_layer() {
    local p="$1"
    case "$p" in
        */steamapps/compatdata/*/pfx) printf 'steam'; return 0 ;;
    esac
    if [ -n "$LUTRIS_PREFIXES" ] && printf '%s\n' "$LUTRIS_PREFIXES" | grep -qxF -- "$p"; then
        printf 'lutris'; return 0
    fi
    case "$p" in
        "$HOME/.local/share/bottles/bottles/"*|\
        "$HOME/.var/app/com.usebottles.bottles/data/bottles/bottles/"*)
            printf 'bottles' ;;
        "$HOME/Games/Heroic/"*)
            printf 'heroic' ;;
        "$HOME/.local/share/lutris/"*)
            printf 'lutris' ;;
        "$HOME/.var/app/org.winehq.Wine/"*)
            printf 'wine' ;;
        "$HOME/.wine")
            printf 'wine' ;;
        *)
            printf 'unknown' ;;
    esac
}

# Echo "layer|path|appid" for every prefix on the machine (appid only
# for Steam compatdata prefixes). Sources: Steam libraries, ~/.wine,
# Lutris game configs, and a bounded scan of the well-known roots where
# Bottles, Lutris, and Heroic keep prefixes (including their Flatpak
# data dirs), plus the conventional ~/.local/share/wineprefixes.
# Prefixes found inside another prefix are dropped: the outer one is
# the prefix that owns them.
discover_prefixes() {
    local -a cand=()
    local lib appdir p root reg dir rp layer appid
    while IFS= read -r lib; do
        [ -n "$lib" ] || continue
        shopt -s nullglob
        for appdir in "$lib"/steamapps/compatdata/*/; do
            is_prefix_dir "${appdir}pfx" && cand+=("${appdir}pfx")
        done
        shopt -u nullglob
    done <<< "$LIBS"
    is_prefix_dir "$HOME/.wine" && cand+=("$HOME/.wine")
    while IFS= read -r p; do
        [ -n "$p" ] && is_prefix_dir "$p" && cand+=("$p")
    done <<< "$LUTRIS_PREFIXES"
    for root in \
        "$HOME/.local/share/bottles/bottles" \
        "$HOME/.var/app/com.usebottles.bottles/data/bottles/bottles" \
        "$HOME/Games" \
        "$HOME/.local/share/lutris" \
        "$HOME/.var/app/org.winehq.Wine/data" \
        "$HOME/.local/share/wineprefixes"; do
        [ -d "$root" ] || continue
        while IFS= read -r reg; do
            dir="$(dirname "$reg")"
            is_prefix_dir "$dir" && cand+=("$dir")
        done < <(find "$root" -maxdepth 6 -name user.reg -type f 2>/dev/null)
    done
    [ "${#cand[@]}" -eq 0 ] && return 0
    local -a canon=() kept=()
    while IFS= read -r rp; do
        [ -n "$rp" ] && canon+=("$rp")
    done < <(printf '%s\n' "${cand[@]}" \
             | while IFS= read -r p; do realpath -m "$p" 2>/dev/null || printf '%s\n' "$p"; done \
             | awk '!seen[$0]++')
    local c k skip
    while IFS= read -r c; do
        skip=0
        for k in ${kept[@]+"${kept[@]}"}; do
            case "$c" in "$k"/*) skip=1; break ;; esac
        done
        [ "$skip" -eq 0 ] && kept+=("$c")
    done < <(printf '%s\n' "${canon[@]}" | awk '{ print length($0), $0 }' | sort -n | cut -d' ' -f2-)
    for c in ${kept[@]+"${kept[@]}"}; do
        layer="$(label_layer "$c")"
        appid=""
        [ "$layer" = "steam" ] && appid="$(basename "$(dirname "$c")")"
        printf '%s|%s|%s\n' "$layer" "$c" "$appid"
    done
}

# --------------------------------------------------- per-layer wine choice --
# Sets RW_WINE and RW_SERVER for a layer. Preference: the wine binary
# belonging to the layer that owns the prefix (Bottles runners, Lutris
# runners, Heroic tools), then the global chain (GE-Proton, any Proton,
# system wine) computed by find_wine. The wineserver always sits next
# to the chosen wine when one is there.
declare -A LAYER_WINE=()
RW_WINE=""
RW_SERVER=""
wine_for_layer() {
    local layer="$1"
    if [ -n "${LAYER_WINE[$layer]+x}" ]; then
        RW_WINE="${LAYER_WINE[$layer]%%|*}"
        RW_SERVER="${LAYER_WINE[$layer]#*|}"
        return 0
    fi
    local w="" d
    local -a cs=()
    shopt -s nullglob
    case "$layer" in
        bottles)
            for d in "$HOME"/.local/share/bottles/runners/*/ \
                     "$HOME"/.var/app/com.usebottles.bottles/data/bottles/runners/*/; do
                [ -x "${d}bin/wine" ] && cs+=("${d}bin/wine")
            done ;;
        lutris)
            for d in "$HOME"/.local/share/lutris/runners/wine/*/ \
                     "$HOME"/.var/app/net.lutris.Lutris/data/lutris/runners/wine/*/; do
                [ -x "${d}bin/wine" ] && cs+=("${d}bin/wine")
            done ;;
        heroic)
            for d in "$HOME"/.config/heroic/tools/wine/*/ \
                     "$HOME"/.var/app/com.heroicgameslauncher.hgl/config/heroic/tools/wine/*/; do
                [ -x "${d}bin/wine" ] && cs+=("${d}bin/wine")
            done
            for d in "$HOME"/.config/heroic/tools/proton/*/ \
                     "$HOME"/.var/app/com.heroicgameslauncher.hgl/config/heroic/tools/proton/*/; do
                [ -x "${d}files/bin/wine" ] && cs+=("${d}files/bin/wine")
            done ;;
    esac
    shopt -u nullglob
    if [ "${#cs[@]}" -gt 0 ]; then
        w="$(printf '%s\n' "${cs[@]}" | sort -Vu | tail -n 1)"
    fi
    [ -z "$w" ] && w="$WINE_BIN"
    local s=""
    if [ -n "$w" ]; then
        if [ -x "$(dirname "$w")/wineserver" ]; then
            s="$(dirname "$w")/wineserver"
        elif [ "$w" = "$WINE_BIN" ]; then
            s="$WINESERVER_BIN"
        else
            s="$(command -v wineserver || true)"
        fi
    fi
    RW_WINE="$w"
    RW_SERVER="$s"
    LAYER_WINE[$layer]="$w|$s"
}

# ------------------------------------------------------------ devices -------
# DEVICES fills from LEGO_FIX_DEVICES when set, else from detect_devices.
DEVICES=()
if [ -n "${LEGO_FIX_DEVICES:-}" ]; then
    IFS=',;' read -ra _req <<< "$LEGO_FIX_DEVICES"
    for d in "${_req[@]}"; do
        d="$(printf '%s' "$d" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$d" ] && DEVICES+=("$d")
    done
else
    while IFS= read -r d; do [ -n "$d" ] && DEVICES+=("$d"); done <<< "$(detect_devices)"
fi

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

# $1 = label, $2 = pfx path, $3 = appid (may be ""), $4 = layer
process_prefix() {
    local label="$1" pfx="$2" appid="${3:-}" layer="${4:-steam}"
    wine_for_layer "$layer"
    local pw="$RW_WINE" ps="$RW_SERVER"

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
    if [ -z "$pw" ]; then
        log "$label: FAILED (no wine binary found for layer '$layer': no layer runner, GE-Proton, Proton, or system wine)"
        HAD_FAILURE=1
        return 0
    fi
    local dev err rc
    while IFS= read -r dev; do
        [ -n "$dev" ] || continue
        err=$(WINEPREFIX="$pfx" timeout 120 "$pw" reg add "$REG_KEY" \
              /v "$dev (js)" /t REG_SZ /d disabled /f 2>&1)
        rc=$?
        if [ $rc -ne 0 ]; then
            log "$label: FAILED (reg add rc=$rc for '$dev (js)': $(printf '%s' "$err" | tail -n 1))"
            HAD_FAILURE=1
            return 0
        fi
    done <<< "$missing"
    # flush the registry to disk, then verify from user.reg
    if [ -n "$ps" ]; then
        WINEPREFIX="$pfx" timeout 60 "$ps" -w >/dev/null 2>&1
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

# ----------------------------------------------------------- discover-only --
if [ "$MODE" = "discover" ]; then
    log "== lego-controller-fix --discover-only (nothing will be changed) =="
    if [ "${#DEVICES[@]}" -eq 0 ]; then
        log "Gamepad-class devices: none detected (fix state per prefix is reported against stored entries only)"
    else
        log "Gamepad-class devices: $(printf '%s; ' "${DEVICES[@]}" | sed 's/; $//')"
    fi
    disc="$(discover_prefixes)"
    if [ -z "$disc" ]; then
        log "No Wine prefixes discovered on this machine."
        exit 0
    fi
    log "Discovered prefixes:"
    n_disc=0
    while IFS='|' read -r layer pfx appid; do
        [ -n "$pfx" ] || continue
        n_disc=$((n_disc+1))
        wine_for_layer "$layer"
        if prefix_active "$pfx" "$appid"; then state="running"; else state="not running"; fi
        if [ "${#DEVICES[@]}" -gt 0 ]; then
            miss="$(missing_devices "$pfx")"
            if [ -z "$miss" ]; then fix="present"
            elif [ "$(printf '%s\n' "$miss" | grep -c .)" -eq "${#DEVICES[@]}" ]; then fix="absent"
            else fix="partial"; fi
        elif grep -qE '"[^"]+ \(js\)"="disabled"' "$pfx/user.reg" 2>/dev/null; then
            fix="entries present in user.reg (no device detected to check against)"
        else
            fix="unknown (no gamepad-class device detected)"
        fi
        log "  [$layer] $pfx"
        log "      state: $state; fix: $fix; wine: ${RW_WINE:-none found}"
    done <<< "$disc"
    log "Total: $n_disc prefix(es) discovered."
    exit 0
fi

# ------------------------------------------------------------- one prefix ---
if [ "$MODE" = "prefix" ]; then
    pfx="$(realpath -m "$PREFIX_ARG" 2>/dev/null || printf '%s' "$PREFIX_ARG")"
    if [ ! -d "$pfx" ]; then
        echo "error: '$PREFIX_ARG' is not a directory" >&2
        exit 2
    fi
    if [ ! -f "$pfx/user.reg" ]; then
        echo "error: '$pfx' is not a Wine prefix (missing user.reg)" >&2
        exit 2
    fi
    if [ ! -d "$pfx/drive_c" ]; then
        echo "error: '$pfx' is not a Wine prefix (missing drive_c)" >&2
        exit 2
    fi
    layer="$(label_layer "$pfx")"
    log "Prefix: $pfx"
    log "Layer: $layer (best evidence; see --discover-only for the full picture)"
    if [ "${#DEVICES[@]}" -eq 0 ]; then
        log "No gamepad-class device detected in /proc/bus/input/devices."
        log "Plug in (or connect) the controller you play with, then re-run."
        exit 0
    fi
    log "Devices: $(printf '%s; ' "${DEVICES[@]}" | sed 's/; $//')"
    wine_for_layer "$layer"
    log "Wine: ${RW_WINE:-none found}"
    out="$(process_prefix "PREFIX ($layer)" "$pfx" "" "$layer")"
    log "$out"
    [ "$HAD_FAILURE" -eq 0 ] || exit 1
    exit 0
fi

# ------------------------------------------------------------- fix modes ----
if [ "$MODE" = "lego" ] && [ -z "$LIBS" ]; then
    log "No Steam installation found on this machine; nothing to do."
    exit 0
fi

if [ "${#DEVICES[@]}" -eq 0 ]; then
    log "No gamepad-class device detected in /proc/bus/input/devices."
    log "Plug in (or connect) the controller you play with, then re-run."
    exit 0
fi
log "Devices: $(printf '%s; ' "${DEVICES[@]}" | sed 's/; $//')"

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
    [ -n "$WINE_BIN" ] && log "Wine: $WINE_BIN" || log "Wine: none found (prefixes needing a write will FAIL)"
    for row in "${LEGO_TITLES[@]}"; do
        IFS='|' read -r appid title src <<< "$row"
        found=0
        while IFS= read -r lib; do
            pfx="$lib/steamapps/compatdata/$appid/pfx"
            [ -d "$pfx" ] || continue
            found=1
            run_and_tally "$title ($appid)" "$pfx" "$appid" "steam"
        done <<< "$LIBS"
        [ "$found" -eq 0 ] && n_absent=$((n_absent+1))
    done
    log "Summary: $n_fixed fixed, $n_already already, $n_skipped skipped (running), $n_absent not present."
else
    # --all-prefixes: every discovered prefix on every layer
    disc="$(discover_prefixes)"
    if [ -z "$disc" ]; then
        log "No Wine prefixes discovered on this machine; nothing to do."
        exit 0
    fi
    while IFS='|' read -r layer pfx appid; do
        [ -n "$pfx" ] || continue
        case "$layer" in
            steam) label="APPID $appid" ;;
            wine) label="HOME-WINE (~/.wine)" ;;
            *) label="$(printf '%s' "$layer" | tr '[:lower:]' '[:upper:]') $(basename "$pfx")" ;;
        esac
        run_and_tally "$label" "$pfx" "$appid" "$layer"
    done <<< "$disc"
    log "Summary: $n_fixed fixed, $n_already already, $n_skipped skipped (running)."
fi

[ "$HAD_FAILURE" -eq 0 ] || exit 1
exit 0
