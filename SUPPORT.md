# Support

## Where to get help

Open an issue in this repository and use the bug report
template:

https://github.com/ZacharyEpic/lego-controller-fix-easy/issues

Include the game title and Steam app ID, your Proton or
GE-Proton version, your controller model and how it is
connected (wired or Bluetooth), the output of
`lego-controller-fix --version`, and the output of the two
read-only runs `lego-controller-fix --detect-only` and
`lego-controller-fix --discover-only`.

For installing, applying, and removing the fix, see the
[Install](README.md#install) section of the README.

## What is supported

- TT-engine LEGO games under Steam and Proton: the titles in
  the tool's built-in table, starting with LEGO City
  Undercover (578330). Rows in the table are marked confirmed
  or same-engine in lego-controller-fix.sh; same-engine rows
  are expected to behave the same but have had less direct
  testing.
- Prefixes outside Steam: `lego-controller-fix --all-prefixes`
  covers every Wine prefix on the machine, which is the route
  for Bottles, Lutris, and Heroic setups.
- Removing what the fix wrote: see "Remove the fix and
  uninstall" in the README.

## What is not supported

- Non-LEGO games. The double-controller bug exists in other
  games, but this project's table and testing are LEGO titles.
- LEGO games running on Windows. The same failure is
  documented there, but this tool writes through Wine and
  Proton.
- A title that has never been launched under Proton has no
  Wine prefix yet, so the tool skips it on purpose and counts
  it at the end. Launch it once, quit, and re-run the tool
  before reporting it as missed.

There is no support email and no promised response time.
Issues are read as time allows.
