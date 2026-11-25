# Changelog

Earlier versions: docs/release-notes-0.3.0.md, -0.4.0.md and -0.4.1.md.

## 0.5.11

Details: [docs/release-notes-0.5.11.md](docs/release-notes-0.5.11.md).

- **Up to six screens, from three** (one constant, ScreenLimit.most). Settings, Space, Screens and the menu go from 1
  to 6; the default stays 2. Layouts for 4 to 6: the row (Four to Six across, narrowed so it never goes round past
  179 degrees), Two rows (Stacked with 4 or more), Main + a column of up to five, and Theater with flanks further out,
  left then right. The displays on the Mac are laid out the same way.
- **Six hosts for the phone's PC screens** instead of three: new bases 53989, 54989 and 55989, six mDNS names. Each
  virtual screen is still made only when the phone asks for it.
- **PC screens from a Windows PC**: up to six Apollos; without mDNS, ports past 49989 are tried only while the one
  before answers.
- Checked with the core checks (every layout, 1 to 6 screens) and compiled on the Intel Air. Not yet run live with
  more than three screens: not in the glasses, and not with more than three PC screens streaming to the phone.

## 0.5.10

Details: [docs/release-notes-0.5.10.md](docs/release-notes-0.5.10.md).

- **Taps on the glasses: softer taps count.** The detector is now the Steam Deck's 0.7.11 one. A tester found the
  first one (which 0.5.8 ported) needed a lot of force. What sets a tap apart is how suddenly it starts, so a tap is
  now a jolt of at least 0.25 g that jumps 0.15 g within 3 ms. It may last up to 150 ms, and the frame ringing after
  it counts as part of the same tap. Taps 0.2 to 0.7 s apart make a run, so about 2 a second works.
- **Tap sensitivity** (Settings, Head tracking), 25% to 300%: higher for softer taps, lower if it acts when you did
  not tap. 100% is the Deck's default, which the tester liked.
- Every jolt now goes to the log with its strength, how long it lasted, the head's turn and whether it counted (and
  why not), at most 120 lines a minute, so a missed tap shows up. Checked with the Deck's tests on made-up motion;
  not yet tried on a Mac with glasses.

## 0.5.9

Details: [docs/release-notes-0.5.9.md](docs/release-notes-0.5.9.md).

- **3D on glasses that macOS keeps at 1920 x 1080.** When glasses switch to 3D they come back offering a 3840 x 1080
  mode and split whatever arrives into a left and a right half. If macOS kept them at 1920 x 1080, Pocket XR drew one
  picture across the whole width: each eye got half of it, stretched, and the two ran into each other in the middle
  (a user's XREAL 1S on an M4 Pro, November 2026). Now, when the glasses say they are in 3D (or, with no settings
  link, when 3D is on and a 3840 x 1080 mode is offered), Pocket XR switches their display to that mode itself, as
  Pocket XR on the phone does. If no such mode is offered, 3D is turned off and Settings, Picture says why, instead of
  a broken picture. The log lists the modes the glasses offer, what they report for 3D, and the size the picture is
  drawn at. Not yet tried with the 1S or on Apple Silicon; on the Aura with an Intel Mac macOS picked the mode itself.

## 0.5.8

Details: [docs/release-notes-0.5.8.md](docs/release-notes-0.5.8.md).

- **Text size** (Settings, Space, Screens): Standard, 125% or 150%. Everything on every screen is drawn larger, at the
  same width as seen, so the side screens of three do not move further out. Each screen gets fewer points (1536 x 864,
  1280 x 720) and is made HiDPI, so it stays sharp. Takes effect when Pocket XR opens again. For a user's report (the
  XREAL 1S on an M4 Pro, November 2026): with three screens the text was too small, and bringing them **Nearer** would
  not help. Nearer only changes how far away the screens look; each keeps its width as seen, so text stays the same
  size. Making them **Bigger** instead moves the side screens further out, past the edge of the glasses' view, where
  turning your head (head tracking) brings them in. Not yet tried with glasses.
- The XREAL 1S on an M4 Pro is the first report of Pocket XR working on an Apple Silicon Mac (README).

- **Taps on the glasses** (Settings, Head tracking), off by default: tap the glasses' frame twice to recentre, three
  times to switch the view. Switching the view is the Mac's nearest to the Steam Deck's switch between the Space and
  Steady mode: Steady mode on or off where the glasses have it (the Aura, the One series), else Body Anchor and Smooth
  Follow in turn. The taps are read from the head tracking stream, for every model the Mac reads it from, with the
  Deck's detector and its values: a sharp jolt away from the 30 ms average, quiet before it, over within 40 ms, the
  head turning slower than 60 degrees a second, and two or three such taps 0.08 to 0.45 s apart. Checked with made-up
  motion (taps, head turns, walking, hard steps); not yet tried with real taps on glasses, on the Mac or the Deck.

## 0.5.7

Details: [docs/release-notes-0.5.7.md](docs/release-notes-0.5.7.md).

- **Stay awake on the power adapter** (Settings, Help, Pocket XR; also in the menu under **Show this Mac on your
  phone**), off by default. While this Mac is plugged in, it does not go to sleep when left idle; its screen still can.
  For reaching it from your phone away from home, over Tailscale or the like: a sleeping Mac's Tailscale sleeps too, and
  a wake packet only travels on the local network. On battery, or with the setting off, the Mac sleeps as usual. Uses
  some power. Closing a MacBook's lid still sleeps it unless a display is connected. Not yet tried with a phone over
  Tailscale.

## 0.5.6

Details: [docs/release-notes-0.5.6.md](docs/release-notes-0.5.6.md).

- **XBX glasses' display is found.** Pocket XR found the glasses' display only by a maker's name in it (XREAL, NREAL,
  VITURE, ROKID or RAYNEO). The XBX A01+ names its display "xbx a01+" (seen on Windows, November 2026), so it was never
  found. Now a name with "XBX" counts, and so does a screen whose name is the plugged-in glasses' USB product name,
  ignoring case. Not tried with XBX glasses on a Mac.

## 0.5.5

Details: [docs/release-notes-0.5.5.md](docs/release-notes-0.5.5.md).

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
