# TDS Car Kit

Use your iPad as a CarPlay display for your iPhone. TDS Car Kit streams the
CarPlay interface over your local Wi-Fi network, with touch control and audio
through the iPad's speakers.

## Features

- Full-screen CarPlay on iPad, controlled by touch.
- Music playback through the iPad's speakers.
- Portrait and landscape display layouts.
- An iPhone receiver picker for connecting to your iPad.
- Separate iPad display and iPhone connection screens that adapt to screen width.
- Wi-Fi passwords saved in the device Keychain.
- Settings and connection diagnostics tucked behind the settings gear.
- CarPlay video and touch on the same iPhone.

## Connect

1. Connect the iPhone and iPad to the same Wi-Fi network.
2. Open TDS Car Kit on the iPad. Choose the display orientation in Settings,
   enable **Play audio on this device**, then tap **Start CarPlay display**.
3. Open TDS Car Kit on the iPhone. Enter the Wi-Fi name and password in Settings
   once, select your iPad, then tap **Connect to iPad**.
4. Accept the CarPlay prompt and keep both apps open. If the iPhone's system
   Connecting sheet stays visible, dismiss it with **X**.

The iPad receives the network connection without needing the Wi-Fi password in
TDS Car Kit. Use the gear on the full-screen display to return to settings.

## Build

Use macOS with Xcode and the iOS SDK. The deployment target is iOS/iPadOS 16.4.

1. Open `TDSCarKit.xcodeproj` and select your own signing team and bundle ID.
2. Create `.local/Identity/`. Receiver startup requires accessory authentication
   files in this directory: `certificate.p7b`, `leaf.cer`, and `private.x963`.
   An empty directory is sufficient to build and explore the interface.
3. Choose the `TDSCarKit` scheme and your iPad or iPhone, then build and run.
   Use the **Release** configuration for streaming performance.

Authentication material is supplied separately and bundled only in local builds.
The repository contains no authentication keys, certificates or provisioning
profiles. The app uses private CoreAccessories APIs.

## Tests

```sh
bash Tools/test.sh
bash Tools/test_audio.sh
```

The protocol suite covers iAP2, RTSP, pairing, authenticated audio/video framing,
replay protection and format negotiation. Identity-dependent tests skip when local
credentials are absent. Audio checks exercise AAC-LC, Opus and PCM conversion
using synthetic tones.

The listener integration check requires local authentication material:

```sh
bash Tools/test_listener.sh
```

## Source layout

- `App/`: UIKit interface, receiver, networking, playback and iPhone companion.
- `Sources/TDSCarKitCore/`: protocol parsing, cryptography and packet framing.
- `Sources/CTDSCarKitCrypto/`: native cryptographic helpers.
- `Tests/TDSCarKitCoreTests/`: protocol tests.
- `Tools/`: project generation, builds and automated checks.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) for the license and third-party
credits. Vendored BigInt is MIT-licensed; its license is in `ThirdParty/`.
