# Known issues and unverified areas

This file lists what is known not to work, and what has not been
verified yet, for lego-controller-fix-easy. Anything not listed as
verified here should be treated as unproven, however confident the
rest of the README sounds.

## Not yet verified

- **In-game confirmation is still pending.** The fix writes one
  registry value per affected game prefix, and every write is
  verified by reading the value back out of the prefix's `user.reg`.
  A rebuilt fixture harness passes 37 of 37 checks against the
  package, covering install, apply, remove, read-only modes,
  idempotency, partial state, running-game skips, and the install
  and uninstall round trip. What has not happened yet: the
  maintainer has not confirmed the result inside LEGO City
  Undercover itself, the game this package was built around. Until
  that confirmation lands, "the value is written and verified" is
  the proven claim, and "the double controller is gone in game" is
  not.
- **Tested on one machine only.** Development and testing happened
  on a single Arch Linux machine with Steam and Proton. Other
  distributions, and Steam installed as a Flatpak, are unverified
  on real setups.
- **The other compatibility layers are unverified on real
  setups.** Bottles, Lutris, Heroic, and plain Wine prefixes are
  discovered and handled by the same code paths, and the harness
  exercises them against fake prefixes with a stub wine binary.
  Nobody has yet run the tool against a real Bottles, Lutris, or
  Heroic install and confirmed the result in a game.
- **Titles marked `same-engine` are covered on engine grounds.**
  They share the TT engine and input stack with confirmed titles,
  but no report of the double-registration bug exists for those
  exact titles. A `same-engine` title may or may not show the bug;
  the fix is harmless either way, but its benefit there is
  unproven.

## Known limits

- **A second controller failure class in these games is not
  fixed.** Launch-time device selection and hot-plug problems
  (the game latching onto the wrong device, a disconnected pad
  never being re-acquired, input breaking after a pause) are
  documented in the README section "What this does NOT fix". No
  registry toggle for them is known, and this package does not
  claim to address them.
- **Discovery only looks in known roots.** A prefix outside the
  scanned locations stays invisible until it is named with
  `--prefix`. See the README's "Honest limits" paragraph under
  "Beyond Steam".

Last updated: 2026-11-10, for release 2026.11.09.2.
