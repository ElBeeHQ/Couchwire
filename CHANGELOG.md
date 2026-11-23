# Changelog

## v0.2.2: Smoother on mobile data, sharper at home

*23 November 2026*

Automatic smoothing adds far less delay on a mobile hotspot, automatic quality gets back to full quality faster and can reach 50 Mbps at home, and Couchwire no longer quits while connecting over the internet.

### Added

- **Play on mobile data, with port forwarding.** Some mobile networks block internet play (Sony's app too). If you forward the PS5's ports on your home router, enter your home's address under **Away from Home** in the console's settings, and Couchwire connects straight to it, waking the PS5 first.
- **Setup asks for the PS button.** When a controller is connected during setup, macOS asks whether Couchwire can respond to the PS button, and setup explains to click Allow.

### Changed

- **Automatic smoothing** no longer assumes the worst on mobile hotspots. It starts at Balanced and steps up to Steadiest only while frames keep arriving very late, then steps back down after a calm minute. On a steady hotspot that roughly halves the delay.
- **Automatic quality climbs back faster.** After a session at home with a short, steady connection and nothing lost, it goes straight back to 1080p at 30 Mbps instead of one step at a time.
- **Automatic quality can reach 50 Mbps at home.** After a smooth session at 30 Mbps on your home network, wired or Wi-Fi, it moves up to 50 Mbps, if your own settings allow it. Over the internet it stays at 30 Mbps at most.
- A tidier **About Couchwire** window.
- While connecting over the internet, Couchwire keeps libchiaki's detailed connection log, so slow or failed connections can be looked into. It asks a busy PS5 again after 8 seconds instead of 12.
- The system log now records whether a stream is HDR at each step (what the PS5 sends, the decoded frames and the display's HDR headroom), and each change automatic quality makes.
- The PS button tip and setup use a controller symbol instead of the PlayStation logo.

### Fixed

- **Lower Quality** no longer fails over the internet. The PS5 takes up to a minute to let go of the old stream, so Couchwire now keeps asking, as it does after a network change, and says it's restarting at lower quality.
- Couchwire no longer quits while connecting over the internet. On some networks it opens 250 sockets at once to find a way through, which used up macOS's limit of 256 for an app.

## v0.2.1: The PS button, and a tidier Settings

*23 November 2026*

The PS button can now go to your PS5 instead of opening Games on your Mac, Settings fits on a laptop screen, and the sound recovers faster after Wi-Fi trouble at home.

### Changed

- Settings is split into Video, Account and Updates tabs, so it fits on a laptop screen. Internet Play is under Account.

### Fixed

- On a network that won't allow a direct connection to your PS5 (some mobile networks), Couchwire now says so after two tries instead of retrying for two minutes.
- The connecting steps no longer say they're waking your PS5 when it's already on. After a network change they say they're reconnecting, explain the wait while the PS5 lets go of the old stream, and number each new try.
- After a burst of Wi-Fi trouble at home (for example when your Mac scans for a hotspot), the sound catches up with the picture within about half a minute, instead of trailing it for several minutes.

### Added

- The first time you stream with a DualSense or another controller with a Home button, Couchwire explains how to send the PS button to your PS5 instead of opening Games on your Mac, with a button that opens Game Controllers settings.
- Couchwire writes a line of performance stats to the system log every 10 seconds while streaming, and logs each connect, wake-up and error message, so slow or failed connections can be looked into afterwards.

## v0.2.0: Play from anywhere

*23 November 2026*

Couchwire now plays your PS5 away from home, adjusts to the connection you're on and keeps going when your Mac changes network.

### Added

- **Internet play.** Turn on **Settings › Internet Play** and sign in to PlayStation Network to play your PS5 away from home, with no port forwarding. Couchwire wakes the console through PSN and shows each step while it connects. Most VPNs block it, and Couchwire says so when one is on.
- **Automatic quality.** Each stream starts at what the connection can handle (lower over the internet and on mobile hotspots), never above your own settings, and learns from every session. If a stream keeps struggling, Couchwire offers to restart it at lower quality.
- **Smoothing** (**Settings › Video**) evens out frames that arrive unevenly. Automatic works hardest on mobile hotspots and adds no delay on a steady network; Off, Balanced and Steadiest are there too, and changes apply mid-stream.
- **Reconnects by itself** when your Mac moves to another network mid-game: the frozen picture is replaced by "Reconnecting…" and the stream resumes at home or over the internet, whichever works from the new network.
- **Frame rate** in the performance stats, and a frame-pacing graph showing when frames arrived and when they were shown.

### Fixed

- Sound no longer stutters or jumps on uneven connections: Couchwire keeps a little more audio in reserve when it needs to.
- The performance stats fit smaller windows, and only flag lost frames and audio gaps from the last 30 seconds.

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
