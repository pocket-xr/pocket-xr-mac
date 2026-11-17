# Pocket XR for Mac 0.3.0

Your Mac's apps on your XR glasses, as screens floating in front of you that stay put as you turn your head. Free and
open source (GPL-3.0), no account, no paid tier. The Mac version of Pocket XR, with the Android, Steam Deck and
Windows versions.

**A first version.** It has been used with one pair of glasses on one Mac: the **XREAL Aura on an Intel MacBook Air
running macOS 14** (16 and 17 November 2026). Nothing else has been tried yet, including Apple Silicon Macs. If you try
it with other glasses or another Mac, please use **Send logs to Mike** in the menu, whether it works or not.

## What you need

- macOS 14 Sonoma or newer. One app for Intel and Apple Silicon.
- A USB-C port that carries video (any Thunderbolt or USB-C port on a recent Mac).

## Install

1. Download `PocketXR-Mac-0.3.0.zip`, open it, and move **Pocket XR** to Applications.
2. Plug your glasses in and open Pocket XR. It lives in the menu bar, under a pair of glasses.
3. Allow **Screen Recording** when macOS asks (System Settings, Privacy & Security, Screen Recording), then open
   Pocket XR again. A short tour opens the first time.

## What is in it

- 1 to 3 floating screens beside your Mac's own screen; move the pointer off its edge to reach them.
- Held still by head tracking; 3D side by side; Body Anchor and Smooth Follow; Recentre.
- Layouts (side by side, main + side, stacked, theater), size, distance, curve; drag the screens in the control
  panel; saved arrangements.
- Steady mode on the XREAL Aura (the glasses hold the picture themselves).
- Keyboard shortcuts in any app (Control-Option and a key), all changeable in Settings.
- A launcher for your apps, Pocket mode, a game controller as a remote, and hand tracking with the glasses' camera or
  the Mac's own.

## Not yet

- Glasses other than the XREAL Aura: the XREAL One series, Air family and VITURE are written for but not tried on a
  Mac.
- Apple Silicon Macs: the app is built for them but not tried on one.

## What it sends to the glasses

Pocket XR reads the glasses' motion. On the Aura and the One series it also sends the settings Pocket XR on Android has
already proven: 2D and 3D, Ultrawide, screen size, Spatial Anchor and follow mode, and puts them back when it quits.
It never sends a firmware command or a guessed one.

Pocket XR is a community project, not made by or affiliated with XREAL or VITURE.
