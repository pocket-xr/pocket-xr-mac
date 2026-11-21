# Pocket XR for Mac

Your Mac's apps on your XR glasses, as screens held still in space while you turn your head.

It is the Mac version of [Pocket XR](https://github.com/pocket-xr/pocket-xr), the free and open source spatial desktop
for Android phones, and of [Pocket XR for Steam Deck](https://github.com/pocket-xr/pocket-xr-deck). Same glasses,
same rules, no account and no paid tier.

> **A first version.** Pocket XR for Mac 0.3 has been used with one pair of glasses on one Mac: the **XREAL Aura on an
> Intel MacBook Air (macOS 14)**. There it showed one to three screens, 3D, head tracking, Steady mode, the control
> panel, saved arrangements, the launcher, Pocket mode, a game controller, and hand tracking with the Aura's camera and
> with the Mac's own. No other glasses and no Apple Silicon Mac have been tried. If you try it, please use **Send logs
> to Mike** in the menu, whether it works or not.

## Download

1. Download `PocketXR-Mac-0.5.4.zip` from [Releases](https://github.com/pocket-xr/pocket-xr-mac/releases/latest) and
   open it. Move **Pocket XR** to Applications.
2. Plug your glasses in and open Pocket XR. It lives in the menu bar, under a pair of glasses.
3. macOS asks to allow **Screen Recording**: allow it in System Settings, Privacy & Security, Screen Recording, then
   open Pocket XR again. It is how Pocket XR shows your screens in the glasses.

Needs macOS 14 or newer. One app for Intel and Apple Silicon Macs (Apple Silicon not tried yet).

## Show this Mac on your phone

New in 0.5.0: Pocket XR on your phone can show this Mac's screens in the glasses, with no Sunshine and no separate PC
helper. Allow the phone once on the Mac, then allow Pocket XR under **Screen & System Audio Recording** and
**Accessibility** when it asks. Each phone PC screen gets its own virtual screen here, at the shape of the phone's window.
Pocket XR replaces the old **Pocket XR PC helper** app: it offers to quit it, and you can then move it and Sunshine to
the Bin. Seen working with one phone and an Intel MacBook Air; see [the release notes](docs/release-notes-0.5.0.md) for
what is untested.

**Waking this Mac from your phone** (Wake-on-LAN, new in [0.5.1](docs/release-notes-0.5.1.md)): once paired, the phone learns this Mac's network address and, when
the Mac does not answer, sends it a wake packet. macOS wakes for it only with **Wake for network access** on (System
Settings, Battery, Options; on a desktop Mac, Energy). On a MacBook that is only while it is plugged in. A MacBook with
its lid closed sleeps unless an external display is connected. Pocket XR's menu (**Show this Mac on your phone**) says
whether the setting is on; Pocket XR never changes it. Seen working with an Intel MacBook Air on its adapter, lid open:
the phone woke it, its screen came on, and the picture came about 4 s after the stream started. On battery it did not
wake. When a stream starts, Pocket XR wakes the Mac fully (the phone's packet alone wakes it with its screens off) and
keeps it awake until the stream ends. Not tried: a desktop Mac, Ethernet, or a closed lid with an external display.

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

A **control panel** on the Mac's own screen holds all of it in one place: a map of the displays (click a screen to
send the pointer there), a pad to drag the screens and pinch or scroll to resize them, saved arrangements, and one
screen more or fewer. Holding Control and Option, moving the pointer carries the screens and scrolling resizes them.

- **Launcher** (Control-Option-Space): your Mac's apps on a floating screen, with pinned apps and search as you type.
- **Pocket mode** (Control-Option-K): the Mac's own screens go black and the pointer stays on the floating screens.
- **Game controller**: a remote for the Space while the left stick is held in. Right stick moves the screens, the
  triggers resize them, the buttons recentre, change layout, switch Steady mode and open the launcher.
- **Hand tracking** (Control-Option-H): point and pinch, seen by the glasses' camera, or by the Mac's camera turned
  to face you (an air trackpad). A pinch clicks once Pocket XR is allowed under Accessibility. On a 2018 MacBook Air
  it finds a hand three or four times a second with the Aura's camera.

Every control has a key that works in any app, all with Control-Option: R recentre, S Steady mode, = and - size,
] and [ distance, . and , curve, L next layout, D 3D, P pointer to the screen you look at, Space the launcher,
K Pocket mode, H hand tracking. Any of them can be changed in Settings, Shortcuts (for keys another app
already uses).

Left on the phone: window gestures on a trackpad drawn on the phone, the on-screen gamepad and game keys, and PC VR.

To see every tour step and settings pane as pictures, without glasses:

```bash
"build/Pocket XR.app/Contents/MacOS/PocketXR" --render-ui ~/Desktop/pocket-xr-pictures
```
## Glasses

| Glasses | Head tracking | 3D side by side |
| --- | --- | --- |
| XREAL Aura | Yes, seen working | Yes, Pocket XR turns it on, seen working |
| XREAL One, One Pro, One Pro+, 1S | Written, not tried on a Mac | Written, not tried on a Mac |
| XREAL Air, Air 2, Air 2 Pro, Air 2 Ultra, VITURE | Experimental switch in Settings, not tried on a Mac by the project | From the glasses' own menu |
| XBX A01, XBX A01+ | Experimental switch in Settings (the Air's stream on HID interface 1), untested | From the glasses' own menu |

USB HID head tracking (the Air family, the XBX and VITURE) is off until **Head tracking for XREAL Air and VITURE
(USB HID)** is turned on in Settings. macOS may also want Pocket XR allowed under Privacy & Security, **Input
Monitoring**. If no head tracking comes, the glasses report (control panel) says why: the HID device it looked for,
whether it opened, whether the start was taken, and Input Monitoring.

Settings on the glasses themselves, as on Android:

**Steady mode**, where the glasses hold the picture still themselves, is written for the Aura and the One series as on
Android. It was seen working with the Aura on a Mac on 16 November 2026; the One series has not been tried on a Mac.
Pocket XR remembers whether you left Steady mode on and turns it back on when the glasses connect, and the control
panel's **Screen gap** sets the space between screens in Steady mode.

- **XREAL Aura:** nothing to do.
- **XREAL One series:** use **Follow** mode and turn **Stabilizer off** in the glasses' menu.

## What it sends to the glasses

Pocket XR reads the glasses' motion. On the Aura and the One series it also sends the settings Pocket XR on Android
has already proven: 2D and 3D, Ultrawide, screen size, Spatial Anchor and follow mode. It never sends a firmware
command or a guessed one.

## Thanks

People whose reports led to fixes:

- **BlackSniper7** (Reddit): the XBX A01+ glasses report that led to XBX A01 and A01+ head tracking (0.5.0, 0.5.2).
- **Pierre Zammit**: testing the Steam Deck version with his XBX A01+ and sending logs, which led to the XBX's controller
  heartbeat (0.5.2).
- **MiaRabbitFan** (Reddit): the XREAL Air glasses report (0 reports a second) that led to the Air's start command
  fix and the clearer head tracking line in the Glasses report (0.5.0).
- **Dmitriy**: logs from his XREAL Air on a MacBook Air, which showed Pocket XR never found the Air's display, named
  just "Air" by macOS (0.5.3), and the idea for Readability (0.5.4).

## Licence

GPL-3.0, as Pocket XR. Pocket XR is a community project, not made by or affiliated with XREAL or VITURE.

The part that lets your phone show this Mac's screens (`Sources/PocketXR/Host*.swift`, `Sources/CHostNet`) speaks
the same protocol as Moonlight, and is compatible with Moonlight clients. It is ported in part from LizardByte's
Sunshine and ClassicOldSong's Apollo (both GPL-3.0), through Pocket XR for Windows' host. It also uses two pieces of
moonlight-common-c, each with its own MIT licence beside its source: ENet by Lee Salzman (`Sources/CHostNet/enet/LICENSE`)
and nanors by Joseph Calderon (`Sources/CHostNet/nanors/LICENSE`).
