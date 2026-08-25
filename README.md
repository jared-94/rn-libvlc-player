# rn-libvlc-player

LibVLC Player for **bare React Native** projects — zero dependency on Expo.

Powered by:
- **libvlcjni** on Android (`org.videolan.android:libvlc-all`)
- **MobileVLCKit** on iOS (via CocoaPods)

Inspired by [expo-libvlc-player](https://github.com/cornejobarraza/expo-libvlc-player) — same API surface, without the `expo-modules-core` requirement.

---

## Supported versions

| Platform        | Version |
| --------------- | ------- |
| React Native    | ≥ 0.73  |
| Android         | 7+ (API 24) |
| iOS             | 15.1+   |

---

## Installation

```sh
npm install rn-libvlc-player
```

### Android

1. Add the VideoLAN Maven repo and the package to your **app's** `android/build.gradle`:

```groovy
// android/build.gradle (project level) – allprojects.repositories
maven { url "https://maven.videolan.org/repository/releases/" }
```

2. Register the package in `MainApplication.kt` (or `.java`):

```kotlin
import com.rnlibvlcplayer.RNLibVlcPlayerPackage

override fun getPackages(): List<ReactPackage> = listOf(
    MainReactPackage(),
    RNLibVlcPlayerPackage(),    // <── add this
)
```

> **Battery optimisation:** background playback requires the user to whitelist your app. Call `LibVlcPlayerModule.checkBatteryOptimization()` to check the status.

### iOS

```sh
cd ios && pod install
```

Add `NSLocalNetworkUsageDescription` to your `Info.plist` if you stream from the local network:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Allow $(PRODUCT_NAME) to access your local network</string>
```

For background playback, add the `audio` key to `UIBackgroundModes` in `Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

---

## Usage

```tsx
import React, { useRef } from "react";
import { View, Button, StyleSheet } from "react-native";
import { LibVlcPlayerView, LibVlcPlayerModule } from "rn-libvlc-player";
import type { LibVlcPlayerHandle } from "rn-libvlc-player";

const STREAM = "https://download.blender.org/peach/bigbuckbunny_movies/big_buck_bunny_720p_h264.mov";

export default function App() {
    const playerRef = useRef<LibVlcPlayerHandle>(null);

    return (
        <View style={styles.container}>
            <LibVlcPlayerView
                ref={playerRef}
                source={STREAM}
                autoplay
                repeat={false}
                volume={80}
                contentFit="contain"
                style={styles.player}
                onPlaying={() => console.log("▶ playing")}
                onPaused={() => console.log("⏸ paused")}
                onEndReached={() => console.log("⏹ end")}
                onTimeChanged={e => console.log("time", e.nativeEvent.time)}
                onFirstPlay={e => console.log("media info", e.nativeEvent)}
                onEncounteredError={e => console.error("error", e.nativeEvent.error)}
            />
            <Button title="Play"  onPress={() => playerRef.current?.play()} />
            <Button title="Pause" onPress={() => playerRef.current?.pause()} />
            <Button title="Seek 30s" onPress={() => playerRef.current?.seek(30_000)} />
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1, backgroundColor: "#000" },
    player: { width: "100%", aspectRatio: 16 / 9 },
});
```

---

## API

### `<LibVlcPlayerView>`

All standard `ViewProps` are forwarded. Extra props:

| Prop | Type | Default | Description |
| ---- | ---- | ------- | ----------- |
| `source` | `string \| null` | — | Media URI. `null` releases the player |
| `options` | `string[]` | `[]` | VLC command-line options |
| `tracks` | `Tracks` | `undefined` | Audio/video/subtitle track ids |
| `slaves` | `Slave[]` | `[]` | Extra audio or subtitle files |
| `rate` | `number` | `1` | Playback rate (≥ 1) |
| `time` | `number` | `0` | Initial time in ms |
| `volume` | `number` | `100` | Volume 0-100 |
| `mute` | `boolean` | `false` | Mute |
| `repeat` | `boolean` | `false` | Loop |
| `autoplay` | `boolean` | `true` | Auto-start |
| `playInBackground` | `boolean` | `false` | Continue in background |
| `scale` | `number` | `0` | VLC scale factor (0 = auto) |
| `contentFit` | `"contain" \| "cover" \| "fill" \| "none"` | `"contain"` | Video scaling mode |
| `aspectRatio` | `string \| number \| "auto"` | `undefined` | Container aspect ratio |

#### Callbacks

`onBuffering`, `onPlaying`, `onPaused`, `onStopped`, `onEndReached`, `onEncounteredError`, `onTimeChanged`, `onPositionChanged`, `onESAdded`, `onFirstPlay`, `onRecordChanged`, `onSnapshotTaken`, `onForeground`, `onBackground`, `onDialogDisplay`

### Imperative methods (via `ref`)

| Method | Description |
| ------ | ----------- |
| `play()` | Start / resume |
| `pause()` | Pause |
| `stop()` | Stop |
| `seek(value, type?)` | Seek to time (ms) or position (0-1) |
| `record(path?)` | Start/stop recording |
| `snapshot(path)` | Save a frame to disk |
| `postAction(1 \| 2)` | Answer a VLC dialog |
| `dismiss()` | Dismiss a VLC dialog |

### `LibVlcPlayerModule`

| Method | Platform | Returns |
| ------ | -------- | ------- |
| `checkBatteryOptimization()` | Android | `Promise<boolean>` |
| `triggerNetworkAlert()` | iOS | `Promise<void>` |
| `isPictureInPictureSupported()` | Both | `boolean` |

---

## Differences from `expo-libvlc-player`

| Feature | expo-libvlc-player | rn-libvlc-player |
| ------- | ------------------ | ---------------- |
| Requires `expo` package | ✅ | ❌ |
| Expo config plugin | ✅ | ❌ (manual setup) |
| Same API surface | — | ✅ |
| Managed workflow support | ✅ | ❌ |
| Bare workflow support | ✅ (with expo pkg) | ✅ |

---

## Known issues

Same as the upstream library:

- **Android black screen** when returning to app (VLC surface detach/attach).
- **iOS audio delay** on mute/resume (VLCKit internal clock issue).
- **iOS local network** prompt may appear during external media playback.

---

## License

MIT
