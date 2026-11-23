# Changelog

## v0.1.0: Your PS5, on your Mac

*23 November 2026*

The first release of Couchwire, a native Mac app that streams your PS5 to your Mac over your home network.

### Added

- **Play your PS5 on your Mac** at up to 1080p and 60 frames per second, in H.264, HEVC or HEVC with HDR on an HDR display. Choose the resolution, frame rate, codec and bitrate in **Settings**, or per console.
- **DualSense, in full.** Rumble and adaptive triggers, the haptics over USB, the light bar, the PS button and the mute button all work as they do on the PS5. Other controllers (DualShock 4, Xbox and more) and the keyboard work too.
- **Voice chat.** Turn on the microphone from the stream controls, the **View** menu (⌃⌘M) or the DualSense's mute button, whose light shows when you're muted.
- **Wake from rest mode.** Couchwire wakes your PS5 when you press Play, and can put it back into rest mode from the stream controls. The menu bar icon lets you start playing without opening the window.
- **Guided setup** walks you through the PS5's settings, signing in to PlayStation Network on Sony's own page (only your Account ID is kept) and pairing with the code on your TV.
- **Performance stats** (⌥⌘I) show the bitrate, frame rate, latency and HDR format while you play.
- **Updates itself** from this page, checked against Couchwire's signing key.

**Install:** download `Couchwire-0.1.0.dmg`, open it, and drag Couchwire onto Applications. Needs macOS 14 or later on Apple silicon. The app is not notarised, so the first time macOS may say it cannot verify it: open System Settings > Privacy & Security, scroll to the message about Couchwire and click **Open Anyway**. After that, updates install from inside the app (Couchwire > Check for Updates…).

**Source:** Couchwire is free software under the GNU AGPL v3. `Couchwire-0.1.0-source.tar.gz` is the source of this release, including chiaki-ng, and `Couchwire-0.1.0-dependencies-source.tar` holds the exact sources of the libraries it's built with.
