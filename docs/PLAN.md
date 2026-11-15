# Pocket XR for Mac: plan

Written 15 November 2026, before any Mac test. Everything marked **to prove** has to be seen working on Mike's Mac
before it is called done. The rest is either already proven in Pocket XR on Android and the Steam Deck, or comes
from Apple's documentation and open source projects (sources at the end).

## What it is

Your Mac's apps on your XR glasses, as screens held still in space while you turn your head. It is the Mac version
of Pocket XR, like the Steam Deck version: free, open source (GPL-3.0), no account, no paid tier. Same glasses, same
rules about what is sent to them.

Why it is worth doing (prior art, checked 15 November 2026):

- **XREAL's Nebula for Mac** gave a mirror plus two extended screens. Its last update was 0.8.0 in April 2024, and
  forum threads report it broken on macOS Sonoma and Sequoia.
- **VITURE's SpaceWalker for Mac** gives 1 to 3 virtual screens, but only for VITURE glasses.
- **Breezy Desktop** is Linux only.

No maintained Mac app works across glasses brands with screens held in space and 3D side by side. That is the
opening. Public text must say so plainly, without claiming people asked for it.

## How it works

```
 Mac apps live on 1-3 virtual displays (CGVirtualDisplay)
        │  macOS treats them as real monitors: windows, full screen, Mission Control all work
        ▼
 ScreenCaptureKit, one stream per virtual display (IOSurface frames, cursor included)
        ▼
 Metal renderer, full screen on the glasses' own display, one frame per glasses refresh
        │  each virtual display is a panel in space, around the head
        │  3D side by side when the glasses are at 3840x1080
        ▲
 Head tracking from the glasses (TCP 52998 on the Aura and One family)
```

**Input needs no tricks.** The real Mac cursor moves onto a virtual display like onto any monitor, so clicks,
scrolling, dragging and typing reach the apps natively. The captured picture includes the cursor, so you see it in
the glasses. No Accessibility permission and no synthetic events in the first version.

**The glasses' own display** shows only Pocket XR's view. A borderless window covers it above the menu bar, ignores
the mouse, and the virtual displays are placed so the cursor goes from the Mac's screen to the virtual displays,
not onto the glasses' screen.

## Glasses

| Glasses | Head tracking on Mac | 3D side by side | Notes |
| --- | --- | --- | --- |
| XREAL Aura | TCP 169.254.2.1:52998, **to prove** | Pocket XR asks for it (10274, proven on Android and the Deck) | Mike's glasses: the first target |
| XREAL One, One Pro, One Pro+, 1S | Same stream, **to prove** | Glasses' own menu, or the same command | Follow mode, Stabilizer off, as on Android |
| XREAL Air, Air 2, Air 2 Pro, Air 2 Ultra | USB HID (IOHIDManager), phase 2 | Glasses' own button | May need Input Monitoring permission, **to prove** |
| VITURE Beast | USB HID, phase 2 | Glasses' menu | |
| Other glasses | None: panels shown flat | No | |

What is sent to the glasses is exactly what the Deck sends, from the same allow list: 2D and 3D, Ultrawide, screen
size, Spatial Anchor, follow and the canvas recentre. Never 10079 (EDID), never 10325 to 10328 (firmware), never a
guessed id. The Air and VITURE get only their motion stream's start and stop.

## The network link (the biggest unknown)

macOS has its own CDC NCM driver, and the glasses are a composite USB device, which macOS's ECM driver reportedly no
longer handles, so expect the NCM link (169.254.2.x) and not the ECM one (169.254.1.x). The glasses hand out
169.254.2.10 by DHCP on Linux. **To prove on the Mac:**

1. A new network interface (enN) appears when the glasses are plugged in (`ifconfig`, System Settings, Network).
2. It gets a 169.254.2.x address, from the glasses or self-assigned.
3. `nc 169.254.2.1 52998 | xxd | head` shows frames starting `28 36`.

Several interfaces can be on 169.254/16 at once (the glasses' two links, plus Wi-Fi's self-assigned address), and
Apple's QA1357 says link-local is only active on the primary interface. So Pocket XR does not trust the routing
table. It finds the interface that has a 169.254.2.x address (getifaddrs) and binds its sockets to it with
`IP_BOUND_IF`. If no interface has one, it tries a plain connect, then 169.254.1.1.

## Virtual displays

CGVirtualDisplay is private CoreGraphics API, used by DeskPad (MIT), BetterDisplay and others since macOS 13.
Pocket XR declares the four classes it needs in its own header (`Sources/CVirtualDisplay`) and keeps every use in
one file (`VirtualDisplays.swift`), so a macOS change breaks one place.

- 1 to 3 displays, each 1920x1080 at 60 Hz, HiDPI off by default (the glasses' pixels are about 1920x1080 per eye,
  so HiDPI would only cost speed). A "Sharper text" option can turn HiDPI on later.
- Created once per session, never added or removed while running: Apple bug FB17797423 makes a new capture stream
  pick the wrong display after a virtual display is reconnected, and careless create/destroy can corrupt the display
  id pool.
- Placed to the right of the Mac's main screen, in a row, with CGConfigureDisplayOrigin. The glasses' own display is
  moved below the row, out of the cursor's way.
- When Pocket XR quits or the glasses are unplugged, the windows on the virtual displays go back to the main screen
  by themselves (macOS moves windows off a display that goes away).

Because the API is private, the app cannot go on the Mac App Store. It ships as a notarized download (Developer ID),
like DeskPad and BetterDisplay.

## Capture

ScreenCaptureKit (macOS 14+), one SCStream per virtual display:

- SCContentFilter for that display, `showsCursor = true`, BGRA, `queueDepth = 4`,
  `minimumFrameInterval = 1/60 s`, the display's full size.
- Each frame's IOSurface becomes a Metal texture with no copy (`makeTexture(descriptor:iosurface:plane:)`); the
  renderer always takes the newest.
- Content at 60 fps is fine: the head turn is what has to be smooth, and that is drawn at the glasses' own rate.
- **Screen Recording permission.** Asked the first time. Since macOS 15, apps that capture without Apple's picker are
  asked to confirm again about once a month. Pocket XR says so in its first-run text, so it is not a surprise.
  Permission is tied to the app's signature: a build signed the same way each time keeps it.

## Rendering

- A borderless NSWindow on the glasses' NSScreen, at the shielding window level, `ignoresMouseEvents`, with a
  CAMetalLayer at the screen's pixel size.
- Paced by the glasses' own display link (`NSScreen.displayLink`, macOS 14), so it runs at whatever the glasses run
  (60, 90 or 120 Hz).
- The head pose is read just before each frame. Panels are textured quads on an arc at 1.4 m, each facing the head,
  1920x1080 panels 40 degrees wide by default (Pocket XR's default window), 2 degrees apart.
- 3D side by side when the screen is at least three times as wide as tall (3840x1080): each half gets its own eye,
  6.4 cm apart. Otherwise one picture.
- The view's vertical field is 38 degrees per eye, the Deck's number for the Aura. A size setting scales it.
- Edge fade, Pocket XR's "Soft": a fade to black at each eye's edges, so panels don't end at a hard line.

## Head tracking

The Deck's HeadFusion, ported as it is (it has been tuned on Mike's Aura):

- Gyro integration, tilt pulled toward gravity (KP 1.0), axes per model (Aura x right, y up, z back; One family y and
  z flipped).
- Gyro bias learnt only from two seconds of real stillness (four quiet half seconds, mean under 1 deg/s on the Aura,
  spread under 0.6 deg/s). The first stillness in the first 5 s also recentres.
- Recentre brings the middle of the panels in front of the head.

## The glasses' settings (Aura)

The Deck's SettingsControl, ported: on the control link (TCP 52999, heartbeat every 50 ms), for "window in space":

1. Read 2D/3D, Spatial Anchor, size, Ultrawide (Ultrawide last).
2. Spatial Anchor off, then Ultrawide off, each set at least 3 s apart and read back.
3. Follow mode if the glasses are in hover (up to 3 tries a link).
4. 3D side by side, asked twice at most a plug-in, 3 s after a follow.
5. On quit: put back only what Pocket XR changed, then wait 2 s.

Steady mode (the Aura holds the picture in 6DoF) follows in phase 2, again as on the Deck.

## The app

A menu bar app (no Dock icon), Pocket XR's look ("Light on glass"):

- **Status:** glasses name, head tracking state, glasses picture size and fps.
- **Recentre** (also Control-Option-R from anywhere), **Screens 1 / 2 / 3**, **Smaller / Bigger**,
  **Nearer / Further**, **3D side by side** on or off, **Send logs to Mike**, **Quit**.
- Settings are kept in UserDefaults.
- The log goes to `~/Library/Logs/Pocket XR/pocket-xr.log`, with a size limit. Send logs makes a zip in Downloads
  with emails, Wi-Fi names and IP addresses other than the glasses' own taken out, and opens an email to Mike.

## Permissions

| What | Why | When asked |
| --- | --- | --- |
| Screen Recording | ScreenCaptureKit, to see the virtual displays | First start, then about monthly (macOS 15+) |
| Local Network | Maybe, for the glasses' link-local link. **To prove** | First connect, if macOS asks |
| Input Monitoring | Maybe, for the Air's HID motion stream (phase 2). **To prove** | First Air plug-in |

No Accessibility permission in version 0.1.

## Build and ship

- Swift package, macOS 14 or newer, Apple Silicon and Intel. `swift build -c release` then `scripts/make-app.sh`
  makes `Pocket XR.app` (Info.plist, icon, signature).
- For testing, the app is signed with a local certificate made once (`scripts/make-cert.sh`), so Screen Recording
  permission survives rebuilds. Ad hoc signing would ask again after every build.
- For release: Developer ID signing and notarization (needs Mike's Apple Developer account, $99 a year), a .dmg on
  GitHub releases in a new `pocket-xr/pocket-xr-mac` repository. No App Store (private API).

## Test plan on Mike's Mac

Step by step, each one proven before the next:

1. **Build:** `swift build`, `swift test` (core: framing, fusion, control wire, layout).
2. **The link:** plug in the Aura. `ifconfig` shows the new interface and its address; the `nc` line above shows
   frames. If not, this is the first thing to solve, before anything else.
3. **Head tracking alone:** `PocketXR --imu-test` prints the head's yaw and pitch 10 times a second. Turn your head:
   the numbers follow, and stay still when you do.
4. **Virtual displays:** start the app. System Settings, Displays shows 2 new displays to the right. Drag a window
   onto one.
5. **Capture and render:** the glasses show the panels, with the window you dragged and the cursor on it. Turning
   your head leaves them in place.
6. **3D:** the glasses switch to 3840x1080 and the panels sit at a depth.
7. **Quit:** the glasses go back to 2D, Spatial Anchor as it was, the windows come back to the Mac's screen.
8. **Unplug and replug** while running, and Recentre, Bigger, Nearer.

## Phase 2 and later

- Air family and VITURE head tracking over HID (ported from the Deck's hidimu.py).
- Steady mode in 6DoF on the Aura (Ultrawide, largest size, Spatial Anchor), as on the Deck.
- Single app windows as their own panels (ScreenCaptureKit window capture), with the click mapping that needs.
- Look at a panel to move the cursor there; head-aimed pointer (CGWarpMouseCursorPosition).
- Curved panels, layouts shared with Android and the Deck, languages, PC VR.

## Risks

| Risk | What happens then |
| --- | --- |
| The glasses' network does not come up on macOS | No head tracking: panels shown flat until solved. The first thing tested. |
| macOS 26 changed CGVirtualDisplay | One file to fix; worst case, extend the Mac's desktop onto the glasses as a plain display |
| Capture slower than 60 fps | Fewer panels, or smaller ones |
| The glasses' display not offered at 3840x1080 on the Mac | 2D only, as with VITURE on Mac today |

## Sources

- DeskPad (MIT), virtual displays: https://github.com/Stengo/DeskPad
- ScreenCaptureKit: https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos,
  https://developer.apple.com/videos/play/wwdc2022/10155/
- Virtual display capture bug: https://developer.apple.com/forums/thread/786829
- Monthly permission prompts: https://tidbits.com/2024/08/19/apple-reduces-excessive-sequoia-permission-requests-shifts-to-monthly
- Link-local on macOS: https://developer.apple.com/library/mac/qa/qa1357/_index.html,
  https://developer.apple.com/forums/thread/707183
- XREAL One and Aura stream (MIT): https://github.com/0xcaff/xr-tools, https://github.com/SamiMitwalli/One-Pro-IMU-Retriever-Demo
- The glasses' USB network on Linux: https://github.com/kevindurb/xreal-linux
- Air family over HID (MIT): https://github.com/badicsalex/ar-drivers-rs
- Nebula for Mac's state: https://community.xreal.com/t/for-quite-some-time-nebula-for-mac-isn-t-working-let-s-go-open-source/6612
- VITURE SpaceWalker: https://www.viture.com/en-US/academy/spacewalker/desktop
- 3D mode on the One series: https://tutorials.xreal.com/docs/glasses/one-series/osd/3d-mode/
