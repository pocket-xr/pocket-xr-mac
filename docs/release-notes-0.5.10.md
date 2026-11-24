# Pocket XR for Mac 0.5.10

- **Taps on the glasses: softer taps count.** The first tap detector needed a lot of force. This one is the same as
  Pocket XR for Steam Deck 0.7.11, made from a tester's recordings: what sets a tap apart is how suddenly it starts,
  not how hard it is.
  - A tap needs a jolt of at least 0.25 g that jumps 0.15 g within 3 ms.
  - It can last up to 150 ms, and the frame ringing after it counts as part of the same tap.
  - Taps 0.2 to 0.7 s apart make a run, so about two a second works. Two taps recentre, three switch the view.
- **Tap sensitivity** (Settings, Head tracking, under **Taps on the glasses**): 25% to 300%. Higher if soft taps are
  missed, lower if it acts when you did not tap. 100% is the Deck's default, which the tester liked.
- Every jolt now goes to the log with its strength, how long it lasted, the head's turn and whether it counted (and
  why not), so a missed tap shows up. If taps don't work for you, please use **Send logs to Mike** in the menu.

**Not yet tried:** real taps on any glasses on a Mac. The detector was checked only with the Deck's tests on
made-up motion: soft and firm taps, ringing, head turns, walking, hard steps, and the sensitivity. On the Deck the
tester found it "more sensitive than I expected, in a good way". Taps are still off by default.

Everything else is as in 0.5.9.

## Thanks

- **Pierre Zammit**, for recording his taps on the Steam Deck, which these values come from.

## Install

Download `PocketXR-Mac-0.5.10.zip`, unzip it and move **Pocket XR** to Applications. One app for Intel and Apple
Silicon, signed with a Developer ID and notarised by Apple.

Pocket XR is a community project, not made by or affiliated with XREAL or VITURE.
