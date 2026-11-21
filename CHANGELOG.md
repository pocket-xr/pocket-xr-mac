# Changelog

Earlier versions: docs/release-notes-0.3.0.md, -0.4.0.md and -0.4.1.md.

## Unreleased

- Waking this Mac from the phone (Wake-on-LAN): a paired phone now gets this Mac's real MAC address (of the network
  interface it reaches) instead of zeros, so it can send the wake packet it already sends to other computers. The menu
  says whether **Wake for network access** is on, and where to turn it on. Untested: waking from sleep has not been
  tried yet.

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
