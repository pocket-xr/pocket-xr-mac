# Pocket XR for Mac 0.5.12

- **Faster than 60 frames a second.** Pocket XR's screens (the virtual displays your apps and the pointer live on)
  were always 60 Hz, and were captured at 60 frames a second, even on glasses that show 90 or 120. They now run at the
  glasses' fastest rate, up to 120 Hz. In 3D, the glasses' side by side mode is picked at its highest rate (it was 60
  Hz first), and if macOS leaves the glasses at 60 Hz when the same size is offered faster, Pocket XR switches it.
  The log says the rate of each screen and of the glasses.
- **Quick pointer** (Settings, Head tracking). Pocket XR draws the pointer itself at every frame, from where your mouse
  is now, instead of waiting for it to come through screen capture with the rest of the picture. Off by default for
  now; turn it on if the pointer feels slow.
- **Settings in Steady mode.** In Steady mode the Space pane showed the sizes for normal tracking, which do nothing
  there, so its Size slider seemed broken. It now shows Steady mode's own Size and Screen gap, as the control panel
  does. Layout says it is not used in Steady mode.
- **3D and Steady mode.** Steady mode puts the glasses in Ultrawide, one flat 32:9 picture, so there is no left and
  right eye picture to draw. The 3D switch is now greyed out in Steady mode, in Settings and on the control panel, with
  a note; 3D comes back when Steady mode is off. Pointer follows head is greyed out too: it never acted in Steady mode.
- **Hands with a camera that faces you** (your Mac's own camera, or a webcam). To open the launcher or recentre, turn
  your palm to your face, as with the glasses' camera; to that camera it is the back of your hand. Before, it wanted
  the palm to the camera, which is what a hand shows it when it pinches at a screen, so pinch and hold recentred
  instead of grabbing a window.

**Not yet tried:** none of this has been tried with glasses yet. The faster rates are untried on any glasses, and it
is not known how much an Intel Mac's graphics keep up at 120 Hz with three screens; send logs if it stutters. Quick
pointer is untried in the glasses: it may draw the pointer where an app has hidden it (while typing, or in a video).
The hand change was checked only with the core checks on made-up hands. It compiled on the Intel Air and the core
checks pass.

Everything else is as in 0.5.11.

## Install

Download `PocketXR-Mac-0.5.12.zip`, unzip it and move **Pocket XR** to Applications. One app for Intel and Apple
Silicon, signed with a Developer ID and notarised by Apple.

Pocket XR is a community project, not made by or affiliated with XREAL or VITURE.
