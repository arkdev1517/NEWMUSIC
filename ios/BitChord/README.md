# BitChord for iOS

This is the native SwiftUI iOS app target; it is not a WebView wrapper. It reuses the checked-in BitChord/YouTube Music InnerTube and Listen Together contracts while using iOS-native Keychain, AVPlayer, MediaPlayer, SwiftUI, and Files import APIs.

## Open and build

Open `BitChord.xcodeproj` in Xcode and select the shared `BitChord` scheme. The project includes the `BitChord` app target and `BitChordTests` unit-test target, targets iOS 17+, and has no third-party package dependencies. Automatic signing is configured; choose a development team in Xcode before installing on a physical device.

From the repository root:

```sh
xcodebuild -project ios/BitChord/BitChord.xcodeproj \
  -scheme BitChord \
  -destination 'generic/platform=iOS Simulator' build

xcodebuild -project ios/BitChord/BitChord.xcodeproj \
  -scheme BitChord \
  -destination 'platform=iOS Simulator,name=<installed iPhone simulator>' test
```

The second command needs a simulator name available in the local Xcode installation. No build or test result is claimed from the Linux migration workspace: it has no Xcode, iOS SDK, Swift compiler, or simulator.

## Current port scope

The code includes Home/Listen Now, Explore categories, YouTube Music search and filters, local imported-audio search, signed-in Library and collection pages, account sign-in/session storage, a native player and queue, audio-file import, and the real Listen Together REST/WebSocket client with server invite links and `bitchord://party/...` inbound handling. Read `../FEATURE_INVENTORY.md` for the Android source map, implementation status, verification boundary, and known parity gaps.

YouTube Music's InnerTube interface is unofficial and subject to change. iOS stream resolution is best-effort: Android's PoToken generation and JavaScript signature/`n` deciphering pipeline has not been ported, so some tracks will fail to resolve. Google may also block embedded sign-in for some accounts. These are service/platform constraints, not mocked behavior.
