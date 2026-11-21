# Pocket XR for Mac 0.5.2

- **XREAL XBX A01 and A01+ head tracking, take two.** On the Steam Deck, an XBX A01+ sent nothing at all on its
  interface 1 when asked for motion. XR Gaming's driver (wheaney's nrealAirLinuxDriver) wakes these glasses' controller
  first. Now, if interface 1 stays silent for about 6 s, Pocket XR does the same:
  - it sends a start-up handshake on interface 0, then a "heartbeat" every 100 ms;
  - it asks interface 1 again, then tries interface 2;
  - it uses whichever interface sends motion.

  The heartbeat stops when head tracking stops. The log names each HID interface tried, the first bytes each one
  sends, and the choice. Ported from Pocket XR for Steam Deck 0.6.1. **Not yet tried with the glasses**: if you have
  an XBX, turn on **Head tracking for XREAL Air and VITURE (USB HID)** in Settings, then use **Send logs to Mike** in
  the menu.

Everything else is as in 0.5.1.

## Thanks

- **Pierre Zammit**, for testing the Steam Deck version with his XBX A01+ and sending logs.
- **BlackSniper7** (Reddit), for the XBX A01+ glasses report on the Mac.

## Install

Download `PocketXR-Mac-0.5.2.zip`, unzip it and move **Pocket XR** to Applications. One app for Intel and Apple
Silicon, signed with a Developer ID and notarised by Apple.

Pocket XR is a community project, not made by or affiliated with XREAL or VITURE.
