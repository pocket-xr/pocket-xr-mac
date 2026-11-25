# Pocket XR for Mac 0.5.11

- **Up to six screens, from three.** Settings, Space, Screens and the menu's **Screens** now go from 1 to 6. The
  default is still 2, and nothing changes unless you pick more. Changing the number restarts Pocket XR, as before.
  - **Row** (Four across, Five across, Six across): side by side on an arc. Six at the usual 40 degrees reach 125
    degrees out on each side, so you turn your head to see the outer ones. Wide screens are narrowed so the row never
    goes round behind you (six at most 58 degrees each).
  - **Stacked** with four to six screens becomes **Two rows**: the first half on top, the rest under them, all
    smaller together if they would reach more than 35 degrees up or down.
  - **Main + side** puts the other screens in one column beside the main one (Main + three stacked, and so on),
    smaller together to fit.
  - **Theater** puts the extra screens further out beside the big one, left then right.
  - On the Mac, the displays are laid out as they look: two rows are above and below each other, so the pointer
    crosses the way your eyes expect.
- **This Mac as up to six PC screens for the phone.** Pocket XR now runs six hosts instead of three, the new ones on
  ports 53989, 54989 and 55989 (each with its own set 5 below and 21 above, as before), and announces six on the
  network (your Mac's name, then "Pocket XR (4)" to "(6)"). Each one's virtual screen is still made only when the
  phone first asks for it. How many the phone shows is up to Pocket XR on the phone.
- **PC screens from a Windows PC**: a PC with more than three Apollos can fill up to six floating screens. When mDNS
  does not get through, the ports after 49989 are tried only while the one before answers, so a PC with three costs
  no extra wait.

**Not yet tried:** anything live with more than three screens. Nothing has been run on a Mac with four, five or six
floating screens in the glasses, or with more than three PC screens streaming to the phone at once. It is not known
whether macOS, the Intel Air's encoder, or the glasses' frame rate keep up with six screens; each extra screen is one
more capture and, for the phone, one more video stream to encode. The new layouts were checked only with the core
checks on made-up numbers: every layout from 1 to 6 screens at 15 to 100 degrees wide stays centred, inside 35
degrees up and down and 179 round, with no two screens overlapping. It compiled on the Intel Air.

Everything else is as in 0.5.10.

## Install

Download `PocketXR-Mac-0.5.11.zip`, unzip it and move **Pocket XR** to Applications. One app for Intel and Apple
Silicon, signed with a Developer ID and notarised by Apple.

Pocket XR is a community project, not made by or affiliated with XREAL or VITURE.
