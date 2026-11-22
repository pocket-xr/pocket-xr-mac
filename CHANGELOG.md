# Changelog

Earlier versions: docs/release-notes-0.3.0.md, -0.4.0.md and -0.4.1.md.

## Unreleased

- **Smooth Follow shows a whole screen.** With two screens side by side, Smooth Follow kept the middle of the row in
  front, which is the gap between them, so only half of each screen could be seen, and as the screens follow the head
  neither could be turned to (an XREAL Air, 22 Nov 2026). Now, with Head scroll off, Smooth Follow settles on the middle
  of the screen nearest where you look. Moving the pointer onto another screen brings that one in front, and so does a
  quick turn of the head past halfway to it. With one or three screens the middle screen is in front, as before.
  Body Anchor and Head scroll are unchanged. Not yet tried with glasses.

## 0.5.4

Details: [docs/release-notes-0.5.4.md](docs/release-notes-0.5.4.md).

- **Readability** (Settings, Space, Screens), for any glasses, off by default: one screen at 1440 x 810, shown 34
  degrees wide and centred, so text is larger and drawn about one screen pixel to one glasses pixel (42 pixels a
  degree, against 48 for the usual 1920 x 1080 at 40 degrees). Turning it on keeps the number of screens, the size
  and any screens moved by hand; turning it off puts exactly those back. The layout, distance, curve, Sharper text and
  the Space's place are left alone. The screen's size takes effect when Pocket XR opens again. The log has a line with
  the before and after values each time. From Dmitriy's own change (one 1440 x 810 screen at 30 degrees); 34 degrees
  here because 30 would draw text no larger than the usual screens on a Mac. Not yet tried with glasses.

## 0.5.3

Details: [docs/release-notes-0.5.3.md](docs/release-notes-0.5.3.md).

- The first XREAL Air's display is found. macOS names it just "Air", with no maker's name, so Pocket XR never took it
  for the glasses: head tracking ran, but nothing was drawn in them. A screen named "Air", "Air 2", "Air 2 Pro" or
  "Air 2 Ultra" is now the glasses' display while Air-family glasses are on USB; never the Mac's built-in screen.
  Pocket mode no longer covers it. The Air 2 names are assumed; untested. Not yet tried with an Air.

Thanks to **Dmitriy** for the logs from his XREAL Air on a MacBook Air that showed this.

## 0.5.2

Details: [docs/release-notes-0.5.2.md](docs/release-notes-0.5.2.md).

- XBX A01 and A01+ head tracking, take two: if the glasses' interface 1 stays silent for about 6 s, Pocket XR wakes
  their controller on interface 0 the way XR Gaming's driver does (a start-up handshake, then a "heartbeat" every
  100 ms), asks again, then tries interface 2, and uses whichever sends motion. The heartbeat stops with head tracking.
  The log names each HID interface tried and the first bytes each sends. Ported from Pocket XR for Steam Deck 0.6.1.
  Not yet tried with the glasses.
- USB HID head tracking diagnostic, in the glasses report and the log: the samples a second the HID reader reads,
  the steps the fusion used and dropped (with the last dropped step's time difference), the time stamps' unit, and the
  glasses frames drawn a second. "Reports a second" is now counted 4 times a second rather than on each frame drawn, so
  it no longer reads 0 just because no frame was drawn. Head tracking itself is unchanged. For an XREAL Air on a Mac
  that read 0 reports a second while its samples arrived. Not yet tried with an Air.

Thanks to **Pierre Zammit** for testing the Steam Deck version with his XBX A01+ and sending logs, and to
**BlackSniper7** (Reddit) for the XBX A01+ glasses report on the Mac, which led to these changes.

## 0.5.1

Details: [docs/release-notes-0.5.1.md](docs/release-notes-0.5.1.md).

- Waking this Mac from the phone (Wake-on-LAN): a paired phone now gets this Mac's real MAC address (of the network
  interface it reaches) instead of zeros, so it can send the wake packet it already sends to other computers. The menu
  says whether **Wake for network access** is on, and on a MacBook that it works only on the power adapter. Seen
  working on an Intel MacBook Air on its adapter, over Wi-Fi.
- A stream starting wakes the Mac fully and keeps it awake until the stream ends. Woken by the phone, macOS woke the
  Air only halfway, with its screen off, so the stream had no picture, and it went back to sleep within a minute.
- The phone's pointer now lands where it points. macOS can move Pocket XR's screen after a stream starts (here, when
  the built-in screen went back to its own size), and the pointer kept the old place: it landed 160 points to the
  left and could not reach the right edge.
- "No picture" now says why: the Mac's screens asleep, Screen Recording not allowed, or no screen offered.

## 0.5.0

Details: [docs/release-notes-0.5.0.md](docs/release-notes-0.5.0.md).

- Show this Mac on your phone with nothing else installed: Pocket XR's own host replaces Sunshine and the separate
  Pocket XR PC helper (the helper's pairing and virtual screens are built in, its allowed phones taken over).
- One permissions message for Screen & System Audio Recording and Accessibility, with a Reopen button; the phone is
  told why when the screen may not be recorded.
- Faster on Intel Macs: the newest picture only waits for the encoder, a still screen is resent about 10 times a
  second, H.264 where HEVC cannot run in low-latency mode (host time 22 ms to 17-18 ms on an Intel MacBook Air).
- "Show another computer in these glasses": for glasses plugged into this Mac, which is left out of the list.
- Head tracking: XBX A01 and A01+ (HID interface 1); the XREAL Air's start command sent as the working macOS driver
  sends it; the Glasses report says why no reports come. Untested on these glasses.

Thanks to **BlackSniper7** (Reddit) for the XBX A01+ glasses report that led to XBX A01 and A01+ head tracking, and
to **MiaRabbitFan** (Reddit) for the XREAL Air glasses report (0 reports a second) that led to the Air's start
command fix and the clearer head tracking line.
