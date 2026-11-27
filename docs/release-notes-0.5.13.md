# Pocket XR for Mac 0.5.13

- **No screen inside a screen.** With the XREAL 1S on an Apple Silicon Mac, one floating screen could show Pocket
  XR's own picture of the glasses, so it showed itself inside itself, smaller and smaller without end. Pocket XR now
  leaves its glasses picture out of every screen, and takes any floating screen that macOS has set to mirror another
  display out of mirroring.

**Not yet tried:** this with the XREAL 1S or any glasses. It compiled on an Intel Mac and the core checks pass. If a
screen still shows itself, please use **Send logs to Mike** in the menu: the log now says when a screen was mirrored.

A change to the number of Screens takes effect the next time Pocket XR starts.

Everything else is as in 0.5.12.

## Thanks

- **Accurate_Citron_774**, for reporting the screen inside a screen with the XREAL 1S on an M4 Pro MacBook Pro.

## Install

Download `PocketXR-Mac-0.5.13.zip`, unzip it and move **Pocket XR** to Applications. One app for Intel and Apple
Silicon, signed with a Developer ID and notarised by Apple.

Pocket XR is a community project, not made by or affiliated with XREAL or VITURE.
