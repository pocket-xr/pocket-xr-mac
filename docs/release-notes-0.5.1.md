# Pocket XR for Mac 0.5.1

## Wake this Mac from your phone

A paired phone can now wake this Mac from sleep to show its screen (Wake-on-LAN).

- **The phone learns this Mac's network address** once paired, and sends a wake packet when the Mac does not answer.
- **macOS needs "Wake for network access" on**: System Settings, Battery, Options (on a desktop Mac, Energy). Pocket
  XR's menu (**Show this Mac on your phone**) says whether it is on, and never changes it.
- **On a MacBook it works only on the power adapter.** On battery the Air did not wake. With the lid closed a MacBook
  stays asleep unless an external display is connected.
- **A full wake.** The phone's packet alone wakes a Mac only halfway, with its screens off, so there was no picture
  and it went back to sleep within a minute. Now a stream starting wakes the Mac fully, turns its screen on, and keeps
  it awake until the stream ends.

On an Intel MacBook Air on its adapter, over Wi-Fi, with the lid open: the phone woke it, its screen came on, and the
picture came about 4 seconds after the stream started.

## The pointer lands where you point

macOS can move Pocket XR's virtual screen after a stream starts, for example when the Mac's built-in screen goes back
to its own size. The pointer kept the old place: on the test Air it landed 160 points to the left of the glasses
pointer and could not reach the right edge. It now follows the screen wherever macOS puts it.

## Clearer "no picture"

When there is no picture, the log now says why: the Mac's screens are asleep, Pocket XR is not allowed to record the
screen, or macOS offered no screen to capture. Before, it always named Screen Recording.

## Not tried yet

- Waking a desktop Mac, or a Mac on Ethernet.
- Waking a MacBook with its lid closed and an external display connected.
- Apple Silicon Macs.

If you try any of these, **Send logs to Mike** in the menu helps a lot.

## Install

Download `PocketXR-Mac-0.5.1.zip`, unzip it and move **Pocket XR** to Applications, replacing the old one. One app for
Intel and Apple Silicon, signed with a Developer ID and notarised by Apple.

Pocket XR is a community project, not made by or affiliated with XREAL or VITURE. Showing this Mac on a phone is
compatible with Moonlight. It is ported in part from Sunshine and Apollo (GPL-3.0), and uses ENet and nanors (MIT).
