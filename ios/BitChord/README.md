# BitChord for iOS

This is the native SwiftUI iOS app target; it is not a WebView wrapper. It reuses the checked-in BitChord/YouTube Music InnerTube and Listen Together contracts while using iOS-native Keychain, AVPlayer, MediaPlayer, JavaScriptCore, SwiftUI, and Files import APIs.

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

The code includes onboarding; Home/Listen Now; Explore categories; YouTube Music search with filters, typeahead and local search modes; signed-in Library and collection pages with the account verbs (like/dislike, save, subscribe, playlist create/delete/add/remove); on-device playlists; a queue engine with shuffle/repeat/play-next/reorder, radio autoplay, playback speed, crossfade and a sleep timer; offline downloads with a Wi-Fi-only policy; synced lyrics (LRCLIB, YouTube captions, the YouTube Music lyrics tab, embedded tags); listening history and Replay statistics; Last.fm/ListenBrainz scrobbling; backup export/import; audio-file import; and the real Listen Together REST/WebSocket client with server invite links and `bitchord://party/...` inbound handling. Read `../FEATURE_INVENTORY.md` for the Android source map, implementation status, verification boundary, and known parity gaps.

YouTube Music's InnerTube interface is unofficial and subject to change. iOS stream resolution now includes multi-client player requests and a JavaScriptCore port of the signature/`n` deciphering, but Android's PoToken (BotGuard) generation has no iOS counterpart, so YouTube may still refuse some tracks. Google may also block embedded sign-in for some accounts. These are service/platform constraints, not mocked behavior. Nothing in this port has been compiled or run yet — the migration workspace has no Swift toolchain (see the inventory's verification record).
