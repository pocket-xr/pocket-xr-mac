# Pocket XR for Mac 0.5.7

- **Stay awake on the power adapter**, for reaching this Mac from your phone away from home, over Tailscale or the
  like. A sleeping Mac's Tailscale is asleep too, and the phone's wake packet only travels on the local network, so
  from elsewhere the phone could not reach a Mac that had gone to sleep. With this on:
  - while the Mac is plugged in, it does not go to sleep when left idle; its screen still can;
  - on battery it sleeps as usual, and it goes back to that when you unplug it.

  **Off by default.** Turn it on in **Settings, Help, Pocket XR**, or in the menu under **Show this Mac on your phone**.
  It uses some power. Closing a MacBook's lid still sleeps it, unless a display is connected.

  Its code was tried on an Intel MacBook Air, outside the app, with `pmset -g assertions`: held while plugged in, let
  go when switched off and when
  unplugged. **Not yet tried:** the switch in the app itself, staying awake again after plugging back in, a phone
  reaching the Mac over Tailscale, and a desktop Mac.

Everything else is as in 0.5.6.

## Install

Download `PocketXR-Mac-0.5.7.zip`, unzip it and move **Pocket XR** to Applications. One app for Intel and Apple
Silicon, signed with a Developer ID and notarised by Apple.

Pocket XR is a community project, not made by or affiliated with XREAL or VITURE.
