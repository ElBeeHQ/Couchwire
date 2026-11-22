# PSStream

A native macOS (SwiftUI/AppKit) PS5 Remote Play client, built for low latency.

The Remote Play protocol core (discovery, pairing, Takion transport, crypto, FEC) is
[chiaki-ng](https://github.com/streetpea/chiaki-ng)'s `libchiaki`, vendored as a submodule
under `Vendor/chiaki-ng`. Everything else is native:

| Layer        | Implementation |
|--------------|----------------|
| Video        | Annex-B → `CMSampleBuffer` → `AVSampleBufferDisplayLayer` (VideoToolbox hardware decode, `DisplayImmediately`, no buffering) |
| Audio        | Opus (libchiaki) → ~20 ms ring buffer → `AVAudioEngine` source node, with drift trimming |
| Input        | GameController framework (DualSense incl. touchpad, motion, rumble; any MFi/Xbox pad; keyboard fallback). Sent on every change, no polling |
| System       | Game Mode opt-in (`LSApplicationCategoryType` games + `GCSupportsGameMode`), latency-critical activity (no App Nap) |
| Secrets      | Pairing keys in the login Keychain |

## Build

```bash
brew install cmake pkg-config xcodegen protobuf json-c miniupnpc libevent curl openssl opus
git submodule update --init Vendor/chiaki-ng
git -C Vendor/chiaki-ng submodule update --init third-party/gf-complete third-party/jerasure third-party/nanopb
./scripts/build-chiaki.sh
xcodegen generate
open PSStream.xcodeproj
```

## First connection

1. On the PS5: **Settings › System › Remote Play** → enable Remote Play, then **Link Device** to show an 8-digit code.
   For wake-from-rest, also enable **Settings › System › Power Saving › Features Available in Rest Mode › Stay Connected to the Internet / Enable Turning On PS5 from Network**.
2. You need your **PSN Account ID** (Base64, 8 bytes — not your sign-in ID). In-app PSN sign-in to fetch it automatically is planned; for now use one of the community lookup tools.
3. Launch PSStream; the PS5 appears under *Nearby*. Click **Pair…**, enter the Account ID and code.
4. Click **Play**. Defaults: 1080p60, HEVC, 30 Mbps.

## Latency tips

- Wire both the Mac and PS5 with Ethernet if you can (Wi-Fi adds jitter and loss).
- Play full screen (⌃⌘F) so Game Mode engages (doubles Bluetooth controller polling).
- Connect the DualSense to the Mac over USB-C, or via Bluetooth with Game Mode on.

## License

libchiaki is AGPL-3.0; distributing PSStream binaries therefore requires releasing PSStream's source under AGPL-3.0 too.
