# Pocket XR for Mac 0.5.0

## Show this Mac on your phone, with nothing else installed

Pocket XR on your phone can show this Mac's screens in the glasses (its PC screens). The Mac end is now part of Pocket
XR for Mac itself: **no Sunshine and no separate PC helper app**.

- **Pairing:** the phone pairs with no PIN to type. You click **Allow** on the Mac once.
- **Virtual screens:** each PC screen gets its own virtual screen on the Mac, at the shape of the phone's window. Up
  to three at once.
- **What comes through:** the picture with the pointer drawn in, the Mac's sound, the phone's mouse and keyboard, and
  the clipboard.
- **Permissions:** it needs **Screen & System Audio Recording** and **Accessibility**. One message names both, with a
  button for each pane of System Settings and a **Reopen Pocket XR** button (macOS lets an app record the screen only
  after it reopens). Without Screen Recording, the phone is told why and stops trying, instead of retrying with no
  picture.
- **The old PC helper:** if it is running, Pocket XR offers to quit it and the Sunshines it runs. Phones it allowed
  stay allowed. Afterwards you can move **Pocket XR PC helper** and **Sunshine** from Applications to the Bin.
- **Menu:** **Show this Mac on your phone** turns it on or off, opens the permissions, and forgets phones.
- **Speed:**
  - Only the newest picture waits for the video encoder.
  - A still screen is resent about 10 times a second, not at the full frame rate.
  - On Macs where HEVC can't run in low-latency mode, H.264 is used instead.

  On an Intel MacBook Air with XREAL glasses on a Galaxy Z Flip7, mouse, typing and sound worked, and the phone showed
  17–18 ms of host time (22 ms before these changes).

## Another computer in these glasses

The menu item is now **Show another computer in these glasses**, with a note: it is for glasses plugged into this
Mac. Glasses on a phone open PC screens from the phone. With no glasses plugged in, it says so. This Mac is left out
of the list of computers. The launcher's button is now **Other computer**.

## Head tracking

- **XBX A01 and XBX A01+** (USB 3318:0440 and 3318:0442) are recognised. They are read over USB HID like the XREAL
  Air, on interface 1.
- **XREAL Air family:** the start command now goes the way the working macOS driver sends it (report ID 0xAA). A
  tester's Air read 0 reports a second before.
- **The Glasses report** now says why no head tracking comes: which HID device was looked for, whether it opened,
  whether the start command was taken, whether macOS allows Input Monitoring, and whether the switch is off in
  Settings.
- USB HID head tracking is still a switch in Settings: **Head tracking for XREAL Air and VITURE (USB HID)**.

## Thanks

- **BlackSniper7** (Reddit), for the XBX A01+ glasses report that led to head tracking for the XBX A01 and A01+.
- **MiaRabbitFan** (Reddit), for the XREAL Air glasses report (0 reports a second) that led to the Air's start command
  fix and the clearer head tracking line in the Glasses report.

## Not tried yet

- The XBX A01 and A01+.
- The Air start command change, on an Air.
- Apple Silicon Macs.
- Two or three phone PC screens at once.
- 120 frames a second with the real screen.
- Clipboard from the Mac to the phone.
- Pocket XR offering to quit the old PC helper (on the test Mac it was quit by hand).

If you try any of these, **Send logs to Mike** in the menu helps a lot.

## Install

Download `PocketXR-Mac-0.5.0.zip`, unzip it and move **Pocket XR** to Applications. One app for Intel and Apple
Silicon, signed with a Developer ID and notarised by Apple.

Pocket XR is a community project, not made by or affiliated with XREAL or VITURE. Showing this Mac on a phone is
compatible with Moonlight. It is ported in part from Sunshine and Apollo (GPL-3.0), and uses ENet and nanors (MIT).
