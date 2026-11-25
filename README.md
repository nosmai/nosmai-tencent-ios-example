# Nosmai Effects with Tencent RTC on iOS

The broadcaster feeds Nosmai camera output into a TRTC live room using custom video capture. The audience receives the host’s stream through the normal TRTC remote view.

## Requirements

- Xcode, CocoaPods and two physical iOS devices running iOS 15 or later.
- A Nosmai Effects licence for the broadcaster’s bundle identifier. The Xcode project uses `com.nosmai.quickstart.tencent`.
- The Podfile pins `NosmaiCameraSDK 3.0.7` and `TXLiteAVSDK_TRTC 13.6.21648`.

## Set up the project

From the repository root, create the local configuration and install the dependencies.

```sh
cp Configuration/Example.plist Configuration/Local.plist
pod install
open NosmaiTencentDemo.xcworkspace
```

In Xcode, select your signing team for the app target. If you change the bundle identifier, use the same identifier when registering the Nosmai licence. Set these fields in `Configuration/Local.plist`, which Git ignores.

- `nosmaiAPIKey` — App-bound Nosmai Effects licence for the broadcasting device. A viewer can leave this field empty.
- `tencentSDKAppID` — Numeric SDKAppID for your Tencent RTC application.
- `roomID` — String room ID shared by the host and audience.

Issue a short-lived UserSig on your server for each participant. On the phone, enter the user ID and its matching UserSig when joining. Give the host and each viewer a distinct user ID under the same SDKAppID.

## Broadcast and watch

1. On the first phone, select **Go Live (Host)** and allow camera and microphone access.
2. On the second phone, select **Watch (Audience)** and join the same room.
3. Open the host’s effects controls and apply a visible effect. Check the result on the viewer.
4. Leave the broadcast from the live screen to release the camera and session resources.

## Add Nosmai to an existing app

Keep your TRTC room and audio configuration. Enable custom video capture for the broadcaster’s main stream and pass each Nosmai output buffer to `sendCustomVideoData`. Audience members use `startRemoteView` when the host’s video becomes available. Clear the Nosmai callback and stop custom capture when leaving.

- [LiveViewController.swift](NosmaiTencentDemo/LiveViewController.swift) shows capture, publication, remote playback and teardown.
- [EffectsPanelView.swift](NosmaiTencentDemo/EffectsPanelView.swift) applies beauty controls, Cloud Filters and AR effects on the broadcaster.

## References

- [Nosmai iOS quickstart](https://nosmai.com/docs/effects/quickstart/ios/)
- [Register a Nosmai licence](https://nosmai.com/docs/effects/license-key/)
- [Tencent UserSig](https://trtc.io/document/35166)
