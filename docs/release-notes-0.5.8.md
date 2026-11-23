# Pocket XR for Mac 0.5.8

- **Text size** (Settings, Space, Screens): Standard, 125% or 150%. Everything on every screen is drawn larger, and
  the screens stay as wide as before, so with three screens the side ones do not move further out. Each screen gets
  fewer points (1536 x 864 or 1280 x 720) and twice the pixels (HiDPI), so text stays sharp. Takes effect when
  Pocket XR opens again.

  Why: with three screens the text can be too small to read. **Nearer** does not help, as it only changes how far
  away the screens look; each keeps its width as seen, so text stays the same size. **Bigger** makes text larger but
  moves the side screens out past the edge of the glasses' view, where you turn your head to see them.

- **Taps on the glasses** (Settings, Head tracking), off by default: tap the glasses' frame twice to recentre, three
  times to switch the view: Steady mode on or off where your glasses have it (the Aura, the One series), else Body
  Anchor and Smooth Follow in turn. Read from the head tracking stream, so it needs head tracking. The same detector
  as Pocket XR for Steam Deck.

- **First report from an Apple Silicon Mac:** the XREAL 1S on a MacBook Pro with an M4 Pro, three screens (the README
  lists it).

**Not yet tried:**
- Text size with any glasses, or on Apple Silicon, and how three HiDPI screens at 125% or 150% run on an Intel Mac.
- Taps with real taps on any glasses (the Steam Deck's version isn't confirmed either). Checked only with made-up
  motion: taps, head turns, walking and hard steps. If it misses taps, or acts when you did not tap, use
  **Send logs to Mike** in the menu.

Everything else is as in 0.5.7.

## Thanks

- **A Reddit user**, for reporting the XREAL 1S working on an M4 Pro MacBook Pro, and that the text of three screens
  was too small.
- **Pierre Zammit**, for asking for taps on the glasses (on the Steam Deck).

## Install

Download `PocketXR-Mac-0.5.8.zip`, unzip it and move **Pocket XR** to Applications. One app for Intel and Apple
Silicon, signed with a Developer ID and notarised by Apple.

Pocket XR is a community project, not made by or affiliated with XREAL or VITURE.
