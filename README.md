# LEGO controller fix, as one package

One tool that applies the controller dedup fix to every applicable game
on a machine. If a game is not installed, or has never been run under
Proton, it is skipped silently and counted at the end, so the same
package works on any machine: it only ever touches what is actually
there. No per-game builds, no per-machine edits, nothing hardcoded to
one person's controller. What it fixes is the double controller bug:
one gamepad registering as two controllers in TT-engine LEGO games
under Wine and Proton. What it writes can also be removed again just
as cleanly; see "Remove the fix and uninstall" below.

## Install

You need a Linux machine with Steam (or Bottles, Lutris, or Heroic),
your controller, and a terminal. The tool installs nothing of its
own; it writes through the Proton or Wine binary your setup already
has.

1. Get the package: clone it with
   `git clone https://github.com/ZacharyEpic/lego-controller-fix-easy.git`
   or download the repository from GitHub and unpack it.
2. Open a terminal in the package folder and run the installer:
   `./install.sh`
   It copies the tool to `~/.local/bin/lego-controller-fix`. If the
   installer notes that `~/.local/bin` is not in your PATH, add it to
   your shell configuration, or call the tool by its full path
   (`~/.local/bin/lego-controller-fix`) everywhere below.
3. Optional, recommended on a first run: look before anything is
   written. `lego-controller-fix --detect-only` shows the Steam
   libraries, the detected controller, and the target titles;
   `lego-controller-fix --discover-only` lists every Wine prefix on
   the machine and its fix state. Both change nothing.
4. Connect the controller the way you play, then run the tool:
   `lego-controller-fix` covers the built-in LEGO title table on
   Steam. For every prefix on every layer, run
   `lego-controller-fix --all-prefixes` instead.

A game only gets a Wine prefix the first time it runs under Proton,
so a title that is installed but was never launched is skipped on
purpose. Launch it once, quit, and re-run the tool.

## The bug this fixes

Wine's DirectInput exposes a single physical gamepad **twice**: once as
an `(event)` device and once as a legacy `(js)` (joystick) device.
TT-engine LEGO games enumerate DirectInput naively and latch onto both,
so the one pad in your hands becomes two controllers. Symptoms:

- a phantom player 2 joins, or is always present;
- one controller drives **both** players at the same time;
- on-screen button prompts glitch, show the wrong device, or stop
  rendering after a while;
- control settings refuse to save (the game keeps seeing a second,
  conflicting input source);
- a pad gets forced to player 2.

This is not Linux-only: the same failure is documented on Windows,
where one Xbox pad identified two ways by the drivers gets treated as
two devices. On Linux/Proton the `(event)`/`(js)` split is the usual
way it happens.

## The fix

For each affected game's Wine prefix, the tool sets one registry value:

```
HKCU\Software\Wine\DirectInput\Joysticks
    "<Device Name> (js)" = "disabled"        (REG_SZ)
```

That hides only the duplicate legacy-js node from DirectInput. The
event node, which is the interface games should be using, is untouched,
so the controller keeps working normally everywhere else.

Writes are done with a `wine` binary directly (`reg add`), flushed
with `wineserver -w`, and then **verified by grepping the value back
out of the prefix's `user.reg`**. A write that does not verify is
reported `FAILED` and makes the tool exit nonzero. Nothing is claimed
fixed on the tool's say-so alone. Which wine binary does the writing
depends on the layer that owns the prefix; see "Beyond Steam" below.

Everything written this way can be taken back out the same way:
`--remove` deletes exactly these values again, through the same wine
binary, verified gone from `user.reg`. See "Remove the fix and
uninstall".

## Which games

Default mode covers a built-in table of TT LEGO titles. Each entry is
marked with its evidence:

- **confirmed**: the double-registration bug is publicly reported for
  that exact title (Steam discussions / ProtonDB report text, opened
  and read), e.g. LEGO City Undercover, LEGO Batman 2, LEGO Marvel
  Super Heroes, LEGO Jurassic World, LEGO Marvel Super Heroes 2, LEGO
  DC Super-Villains, The LEGO Movie Videogame.
- **same-engine**: no title-specific report found; covered because the
  game runs the same TT engine and input stack, e.g. LEGO Batman 1 and
  3, LEGO Marvel's Avengers, The LEGO Movie 2 Videogame, LEGO The
  Incredibles.

`--all-prefixes` ignores the table and treats **every** Wine prefix
on the machine, on every layer it can discover (next section), for
cases where the doubling shows up outside LEGO.

## Beyond Steam: compatibility layers

A game that misbehaves on one Proton version may be moved to another
Windows compatibility layer, and the fix has to follow it. The tool
therefore discovers prefixes beyond Steam compatdata:

- **Steam**: every `steamapps/compatdata/*/pfx` in every library.
- **Bottles**: bottles under `~/.local/share/bottles/bottles/`,
  including the Flatpak data dir
  (`~/.var/app/com.usebottles.bottles/data/bottles/bottles/`). Bottles
  template prefixes are not game prefixes and are never touched.
- **Lutris**: prefixes named by game configs in
  `~/.config/lutris/games/*.yml` (they can live anywhere), plus
  anything prefix-shaped under `~/.local/share/lutris/`.
- **Heroic**: prefixes under `~/Games/Heroic/`, including named
  prefix folders and game folders with spaces in their names.
- **Plain Wine**: `~/.wine`, plus the Wine project's own Flatpak
  prefix (`~/.var/app/org.winehq.Wine/data/wine`).
- **Anything prefix-shaped** in the bounded generic roots above and in
  `~/.local/share/wineprefixes/`: a directory counts as a prefix when
  it contains both `user.reg` and `drive_c`.

Each discovered prefix gets a **layer label from the best evidence
available**: Steam layout, then Lutris game configs, then the owning
app's install location. When the evidence does not decide it, the
label is `unknown`. Labels are reported, never guessed into facts.

**Writes use the owning layer's own wine binary** when one is
installed: Bottles runners (`~/.local/share/bottles/runners/`), Lutris
runners (`~/.local/share/lutris/runners/wine/`), Heroic tools
(`~/.config/heroic/tools/`, Wine and Proton builds). The fallback
chain is GE-Proton, then any Proton, then system wine, and the
wineserver used always sits next to the chosen wine. Registry write
and verify-by-grep work exactly as in the Steam case.

Two extra modes serve the layer world:

- `--prefix <path>` applies the fix to one explicitly named prefix,
  with the best wine binary for its layer. The path is validated
  first: a directory without `user.reg` (or without `drive_c`) is
  rejected with an error and exit 2. Use it for a prefix that lives
  outside every scanned root.
- `--discover-only` lists every prefix found on the machine, its
  layer, whether it is running, whether the fix is already present,
  and which wine binary a write would use. It changes nothing.

`--remove` is not a mode of its own. It flips any applying mode
(the default title table, `--all-prefixes`, `--prefix`) from writing
the values to deleting them, and it turns `--detect-only` and
`--discover-only` into removal previews.

Honest limits: discovery only looks in the roots listed above plus
Lutris config paths; a prefix somewhere else is invisible until you
point `--prefix` at it. A layer label can be wrong when a prefix was
moved by hand after its app created it. Neither mode invents
coverage it did not find.

The `LEGO_FIX_DEVICES` environment variable (comma or semicolon
separated device names) replaces controller auto-detection when set.
It exists for testing, and for writing entries for a pad that is not
connected right now.

## How device detection works

Nothing about your controller is baked into the package. At run time
the tool reads `/proc/bus/input/devices` and classifies devices as
gamepad-class by name, using two rules:

1. any interface of that name carries a `js` handler (`js0`, `js1`,
   ...), the classic joystick node; or
2. the name has an absolute-axis (`EV_ABS`) interface, but **no** mouse
   handler and **no** relative-axis interface under the same name.

Rule 2 exists because real gamepad hardware does not always bind a
`js` node. A popular wireless headset dongle that enumerates as a
gamepad-class, event-only device binds no `js` node at all (there may
be no `js` node anywhere on such a system), yet games treat the
dongle as a controller. Rule 2's exclusions are what keep it
honest: gaming mice and keyboards also expose absolute-axis
interfaces, but always alongside a mouse handler or relative axes
under the same name, and a pad has neither. Detection was validated
against a full real-world device list: it returns exactly the
gamepad-class dongle, and none of the mice or keyboards also present.

For each detected device name the tool generates the
`"<name> (js)" = "disabled"` entry. On your machine the detected names
will be whatever pads you actually have connected.

Consequence: run the tool with the controller connected the way you
play. A pad that is not connected at run time produces no entry, which
is the correct no-op, and re-running later with it connected adds just
that entry.

## Safety behavior

- **Idempotent.** Prefixes that already carry every value report
  `ALREADY` and are not written. Re-run as often as you like.
- **Running games are skipped.** If a game's processes are live, the
  prefix reports `SKIPPED-RUNNING` and is never written. Detection
  checks process command lines *and* process environments
  (`WINEPREFIX=`, `STEAM_COMPAT_DATA_PATH=`), because command lines
  alone have been observed missing games that were definitely running.
- **Absent games are silent.** A table entry with no prefix on any
  Steam library (not installed, or installed but never launched under
  Proton, so no prefix exists yet) prints nothing and is counted in the
  final summary line as "not present".
- **Read-only modes change nothing.** `--detect-only` and
  `--discover-only` never invoke a wine binary and never write; the
  running check and the skip rule apply to prefixes on every layer,
  not just Steam's.
- **Removal is the exact inverse.** `--remove` deletes only the
  `"<name> (js)" = "disabled"` values for the devices detected at
  removal time, through the same per-layer wine binary, and verifies
  each value is gone from `user.reg` before reporting `REMOVED`.
  Running games are skipped for removal exactly as for applying, and
  values belonging to devices that are not connected at removal time
  are left in place, the mirror of applying never writing them.

## Usage

```sh
./install.sh                    # installs ~/.local/bin/lego-controller-fix
./uninstall.sh                  # removes ~/.local/bin/lego-controller-fix

lego-controller-fix             # fix the built-in LEGO table (Steam prefixes)
lego-controller-fix --all-prefixes   # fix every discovered prefix, all layers
lego-controller-fix --prefix <path>  # fix one explicitly named prefix
lego-controller-fix --detect-only    # libraries, devices, targets; changes nothing
lego-controller-fix --discover-only  # every prefix, its layer and fix state;
                                     # changes nothing
lego-controller-fix --remove             # undo the fix, built-in LEGO table
lego-controller-fix --remove --all-prefixes  # undo the fix, every prefix
lego-controller-fix --remove --prefix <path> # undo the fix, one named prefix
lego-controller-fix --version            # print the tool version
```

Steam libraries are discovered from the standard Steam roots plus every
`path` in `steamapps/libraryfolders.vdf`, so extra library drives are
picked up automatically.

**Re-run after new games.** A Proton prefix only exists after a game
has been launched once. When you install or first-launch another LEGO
title, run `lego-controller-fix` once more; it will fix just the new
one and report the rest `ALREADY`.

## Update

There is no separate updater; updating is installing again:

1. Download or pull the new version of this package.
2. Run `./install.sh` from the new copy. It overwrites
   `~/.local/bin/lego-controller-fix` with the newer tool; there is
   nothing to uninstall first.
3. Re-run `lego-controller-fix` (or `--all-prefixes` for every
   layer). The tool is idempotent, so the re-run only covers whatever
   the new version adds, such as a new title in the table; prefixes
   that were already fixed report `ALREADY` and are untouched.

Registry entries written by an older version stay valid, so an update
never needs the fix removed first. `lego-controller-fix --version`
prints the version you currently have installed, in `YYYY.MM.DD.N`
form; that is the string bug reports should name.

## Remove the fix and uninstall

These are two separate things, and the order matters:

1. **Remove the fix from your game prefixes**, while the tool is
   still installed:
   - `lego-controller-fix --remove` covers the built-in LEGO title
     table prefixes.
   - `lego-controller-fix --remove --all-prefixes` covers every
     discovered prefix on every layer.
   - `lego-controller-fix --remove --prefix <path>` covers one named
     prefix.

   Removal deletes exactly the `"<Device Name> (js)" = "disabled"`
   values the tool wrote, for the devices detected at removal time,
   and verifies each one is gone from `user.reg`. Connect the
   controller first, the same as when applying. A running game's
   prefix is skipped. To preview what would be removed without
   changing anything, combine it with a read-only mode, for example
   `lego-controller-fix --remove --discover-only`.
2. **Uninstall the tool**: run `./uninstall.sh` from the package
   folder. It deletes `~/.local/bin/lego-controller-fix` and nothing
   else. It does not undo registry changes, which is why step 1 comes
   first. If you uninstalled first by mistake, re-run `./install.sh`,
   do step 1, then uninstall again.

## Maintaining the title list

The title table is a single clearly commented block near the top of
`lego-controller-fix.sh`, one row per title:

```
"appid|Game title|source"
```

The standing policy:

- **A new title is found to be affected** by the double-registration
  bug (a real report: phantom player 2, one pad driving both players,
  the pad seen as two devices): it gets added to the build as one new
  row, `confirmed` when there is a title-specific report, `same-engine`
  when it is covered on engine grounds. Then re-run the tool and
  confirm the new title reports `FIXED` (or `ALREADY`) with the value
  verified in its `user.reg`. One line is the whole change; there are
  no per-game builds to regenerate.
- **A title already covered develops a controller problem:** that gets
  investigated first, report by report, before any fix is claimed. New
  symptoms in a covered title are not automatically this bug (see the
  next section: there is a second, separate failure class in these
  games), and the table is only extended on evidence, not on the first
  complaint.

## What this does NOT fix

There is a **second, separate controller failure class** in these
games, and this package does not address it, because no registry toggle
for it is known:

- the game latches onto the wrong primary USB device at launch and
  ignores the pad entirely (reported for LEGO Batman 3);
- a controller that dies or disconnects mid-game is never re-acquired;
  only a restart brings it back (reported for LEGO Batman 2);
- the pad is locked out if the keyboard was touched first at the
  press-a-button screen, and pausing or minimizing can break all input
  until a restart (reported for LEGO Marvel Super Heroes 2 and
  Batman 3).

Those are launch-time device selection and hot-plug behavior inside
the game engine, not double enumeration, so hiding the `(js)` node
neither causes nor cures them. They are listed here so nobody mistakes
"the fix is applied" for "every controller problem in these games is
solved".

## Feedback and bug reports

Report problems, and suggest titles or controllers that should be
covered, in GitHub Issues on this repository:
https://github.com/ZacharyEpic/lego-controller-fix-easy/issues

What is known not to work, and what has not been verified yet, is
listed plainly in [KNOWN-ISSUES.md](KNOWN-ISSUES.md). Read it
before relying on the fix on a setup unlike the one it was tested
on.

A useful report includes:

- your distro (for example Arch, Ubuntu, Fedora) and how Steam or
  the launcher is installed (native package or Flatpak);
- the Proton or compatibility layer version the game runs on (for
  example Proton 9.0 or GE-Proton 10), or the Bottles, Lutris, or
  Heroic runner when the game is not on Steam;
- the game title, plus its Steam appid if you know it;
- the controller model and how it connects (USB, Bluetooth, or a
  wireless dongle);
- the output of `lego-controller-fix --version`;
- the output of `lego-controller-fix --detect-only`, pasted in full
  (add `--discover-only` output when the game is not a Steam title);
- what the tool reported for your game (`FIXED`, `ALREADY`,
  `SKIPPED-RUNNING`, `FAILED`, `REMOVED`, or nothing at all) and what
  the game still does wrong afterwards.

The `--detect-only` output includes your Steam library paths and your
controller's device name. Read it over before posting if that
concerns you.

## Notes

- This package supersedes the one-machine ad-hoc script
  `wine-dedup-js.sh` (hardcoded to a single device name, single Steam
  root). That file can be left in place; this package is the maintained
  version.
- Exit status is 0 for every "nothing to do" outcome: no Steam found,
  no gamepad connected, no target prefixes, everything already fixed.
  It is nonzero only when a write or a delete was attempted and
  failed verification. (Before 2026.11.09.2 a prefix could print
  FAILED and the tool still exited 0; the contract above is the one
  that build enforces.)
