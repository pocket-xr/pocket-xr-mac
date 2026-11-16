# Pocket XR for Mac

Your Mac's apps on your XR glasses, as screens held still in space while you turn your head.

It is the Mac version of [Pocket XR](https://github.com/pocket-xr/pocket-xr), the free and open source spatial desktop
for Android phones, and of [Pocket XR for Steam Deck](https://github.com/pocket-xr/pocket-xr-deck). Same glasses,
same rules, no account and no paid tier.

> **Not released yet.** Version 0.2 runs on an Intel MacBook Air (macOS 14) with the XREAL Aura: two screens, 3D and
> head tracking were seen working there on 16 November 2026. Everything else below is written but not yet tried in
> glasses, and no other glasses have been tried on a Mac at all.
## How it works

Pocket XR adds 1 to 3 screens to your Mac, to the right of its own screen. Move the pointer off the right edge and
it is on them: drag apps there, click and type as usual. In your glasses, those screens float in front of you and
stay put as you turn your head. With glasses that do 3D side by side, they sit at a real depth.

## Build

On a Mac with macOS 14 or newer and Xcode (or its command line tools):

```bash
scripts/make-cert.sh
```

That makes a signing certificate for testing, once, so macOS remembers Pocket XR's Screen Recording permission
between builds. Then:

```bash
scripts/core-check.sh
```

```bash
scripts/make-app.sh
```

On a Mac with only the command line tools, where `swift build` stops at "Invalid manifest", build without SwiftPM:

```bash
scripts/make-app.sh direct
```
```bash
open "build/Pocket XR.app"
```

The first time, macOS asks to allow Screen Recording: allow it in System Settings, Privacy & Security, Screen
Recording, then open Pocket XR again.

Check the glasses and head tracking on their own, in Terminal:

```bash
"build/Pocket XR.app/Contents/MacOS/PocketXR" --usb
```

```bash
"build/Pocket XR.app/Contents/MacOS/PocketXR" --imu-test
```

## Use

Pocket XR lives in the menu bar, under the glasses icon. A two minute tour opens the first time and stays in the menu.

- **Recentre**, **Steady mode**, **3D side by side**.
- **Layout**: side by side, main + side, stacked or theater. **Bigger**, **Smaller**, **Nearer**, **Further**, **More
  curve**, **Less curve**.
- **Tracking**: Body Anchor (screens stay in the room) or Smooth Follow (they drift back in front of you), or off.
- **Screens**: 1, 2 or 3.
- **Settings…**: a live picture of your Space, presets, eye distance, brightness, the glow around the screen you look
  at and its colour, edge fade, head scroll, pointer follows head, the tracking readings, a Glasses report, settings
  saved to and restored from a file, open at login.
- **Tour of Pocket XR**, **Send logs to Mike** and **Quit and put the glasses back**.

Every control has a key that works in any app, all with Control-Option: R recentre, S Steady mode, = and - size,
] and [ distance, . and , curve, L next layout, D 3D, P pointer to the screen you look at.

Left on the phone, because a Mac has its own: the app launcher, window gestures, hand tracking, game controllers,
PC VR and Pocket mode.

To see every tour step and settings pane as pictures, without glasses:

```bash
"build/Pocket XR.app/Contents/MacOS/PocketXR" --render-ui ~/Desktop/pocket-xr-pictures
```
## Glasses

| Glasses | Head tracking | 3D side by side |
| --- | --- | --- |
| XREAL Aura | Yes, seen working | Yes, Pocket XR turns it on, seen working |
| XREAL One, One Pro, One Pro+, 1S | Written, not tried on a Mac | Written, not tried on a Mac |
| XREAL Air family, VITURE | Experimental switch in Settings, not tried on a Mac | From the glasses' own menu |

Settings on the glasses themselves, as on Android:

**Steady mode**, where the glasses hold the picture still themselves, is written for the Aura and the One series as on
Android. It was seen working with the Aura on a Mac on 16 November 2026; the One series has not been tried on a Mac.

- **XREAL Aura:** nothing to do.
- **XREAL One series:** use **Follow** mode and turn **Stabilizer off** in the glasses' menu.

## What it sends to the glasses

Pocket XR reads the glasses' motion. On the Aura and the One series it also sends the settings Pocket XR on Android
has already proven: 2D and 3D, Ultrawide, screen size, Spatial Anchor and follow mode. It never sends a firmware
command or a guessed one.

## Licence

GPL-3.0, as Pocket XR. Pocket XR is a community project, not made by or affiliated with XREAL or VITURE.
