# Pocket XR for Mac 0.5.3

- **The first XREAL Air's display is found.** macOS names the Air's display just "Air", with no maker's name.
  Pocket XR looked only for names with XREAL, VITURE and the like in them, so it never took the Air's display for the
  glasses: head tracking ran, but nothing was drawn in them. Now:
  - a screen named "Air", "Air 2", "Air 2 Pro" or "Air 2 Ultra" is the glasses' display while Air-family glasses are
    plugged in over USB, so a monitor that happens to be called "Air" is not taken otherwise;
  - the Mac's built-in screen is never taken for the glasses;
  - Pocket mode no longer covers the Air with a black window.

  The Air 2 names are assumed from the model names; untested. **Not yet tried with an Air**: if your glasses still
  show nothing, send a glasses report and use **Send logs to Mike** in the menu.

Everything else is as in 0.5.2.

## Thanks

- **Dmitriy**, for the logs from his XREAL Air on a MacBook Air that showed this.

## Install

Download `PocketXR-Mac-0.5.3.zip`, unzip it and move **Pocket XR** to Applications. One app for Intel and Apple
Silicon, signed with a Developer ID and notarised by Apple.

Pocket XR is a community project, not made by or affiliated with XREAL or VITURE.
