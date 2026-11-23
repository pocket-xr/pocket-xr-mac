# Pocket XR for Mac 0.5.9

- **3D on glasses that macOS keeps at 1920 x 1080.** When glasses switch to 3D, they split whatever they are sent
  into a left half and a right half, one for each eye, and offer a wider 3840 x 1080 mode for it. Pocket XR left
  picking that mode to macOS. If macOS kept the glasses at 1920 x 1080, Pocket XR drew one ordinary picture across
  the whole width, so each eye got a different half of it, stretched, and the two ran together in the middle.

  Now, when the glasses say they are in 3D, Pocket XR switches their display to 3840 x 1080 itself, as Pocket XR on
  the phone does. That includes 3D turned on from the glasses' own menu. If the glasses give no answer, it does the
  same when 3D is on in Pocket XR and that mode is offered. If no such mode is offered, Pocket XR turns 3D off and
  **Settings, Picture** says why, instead of showing a broken picture.

  The log now lists the modes the glasses offer, what they report for 2D or 3D, each switch and whether macOS took
  it, and the size the picture is drawn at. If 3D still looks wrong, please use **Send logs to Mike** in the menu.

**Not yet tried:** any of this with glasses. That means not with the XREAL 1S, not on Apple Silicon, not whether
macOS accepts the switch, and not whether the 1S's settings link opens on a Mac. With the XREAL Aura on an Intel Mac,
macOS already picked the 3840 x 1080 mode itself, so nothing changes there.

Everything else is as in 0.5.8.

## Thanks

- **A Reddit user**, for reporting that 3D looked "all combined in the middle" with the XREAL 1S on an M4 Pro
  MacBook Pro.

## Install

Download `PocketXR-Mac-0.5.9.zip`, unzip it and move **Pocket XR** to Applications. One app for Intel and Apple
Silicon, signed with a Developer ID and notarised by Apple.

Pocket XR is a community project, not made by or affiliated with XREAL or VITURE.
