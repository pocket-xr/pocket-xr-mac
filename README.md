# Pocket XR for Mac

Your Mac's apps on your XR glasses, as screens held still in space while you turn your head.

It is the Mac version of [Pocket XR](https://github.com/pocket-xr/pocket-xr), the free and open source spatial desktop
for Android phones, and of [Pocket XR for Steam Deck](https://github.com/pocket-xr/pocket-xr-deck). Same glasses,
same rules, no account and no paid tier.

> **Not released yet.** This is the first build, made from the plan in [docs/PLAN.md](docs/PLAN.md) and not yet run
> on a Mac. Everything below is how it is meant to work.

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
swift test
```

```bash
scripts/make-app.sh
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

Pocket XR lives in the menu bar:

- **Recentre**, also Control-Option-R from any app.
- **Bigger**, **Smaller**, **Nearer**, **Further**.
- **3D side by side**, on by default on glasses that can do it.
- **Screens**: 1, 2 or 3.
- **Send logs to Mike** and **Quit and put the glasses back**.

## Glasses

| Glasses | Head tracking | 3D side by side |
| --- | --- | --- |
| XREAL Aura | Yes | Yes, Pocket XR turns it on |
| XREAL One, One Pro, One Pro+, 1S | Yes | Yes |
| XREAL Air family, VITURE | Not yet: the screens are shown flat | From the glasses' own menu |

Settings on the glasses themselves, as on Android:

- **XREAL Aura:** nothing to do.
- **XREAL One series:** use **Follow** mode and turn **Stabilizer off** in the glasses' menu.

## What it sends to the glasses

Pocket XR reads the glasses' motion. On the Aura and the One series it also sends the settings Pocket XR on Android
has already proven: 2D and 3D, Ultrawide, screen size, Spatial Anchor and follow mode. It never sends a firmware
command or a guessed one.

## Licence

GPL-3.0, as Pocket XR. Pocket XR is a community project, not made by or affiliated with XREAL or VITURE.
