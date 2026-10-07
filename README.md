# @patchkite/react-native

React Native SDK for [Patchkite](https://github.com/patchkite/patchkite), self-hosted over-the-air updates.

- New Architecture (TurboModule, bridgeless), iOS and Android, React Native 0.80+
- Diff updates and binary patches, so small changes are small downloads
- Automatic rollback when an update crashes before `notifyAppReady()`
- Code signing: packages are verified against your public key
- CodePush-style API: `sync`, `checkForUpdate`, install modes, update dialog

## Install

```bash
npm install @patchkite/react-native
cd ios && pod install
```

## Setup

**Android** — load the bundle through Patchkite in `MainApplication.kt`:

```kotlin
import io.github.patchkite.reactnative.Patchkite

override val reactHost: ReactHost by lazy {
  getDefaultReactHost(
    context = applicationContext,
    packageList = PackageList(this).packages,
    jsBundleFilePath = Patchkite.getJSBundleFile(applicationContext),
  )
}
```

and configure it in `res/values/strings.xml`:

```xml
<string moduleConfig="true" name="PatchkiteServerUrl">https://patchkite.example.com</string>
<string moduleConfig="true" name="PatchkiteDeploymentKey">DEPLOYMENT_KEY</string>
```

**iOS** — in `AppDelegate.swift`:

```swift
import PatchkiteReactNative

override func bundleURL() -> URL? {
#if DEBUG
  RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
#else
  Patchkite.bundleURL()
#endif
}
```

and add `PatchkiteServerURL` and `PatchkiteDeploymentKey` to `Info.plist`.

**JavaScript** — wrap your root component:

```tsx
import patchkite from "@patchkite/react-native";

export default patchkite({ checkFrequency: patchkite.CheckFrequency.ON_APP_RESUME })(App);
```

Release updates with the [Patchkite CLI](https://github.com/patchkite/cli):

```bash
patchkite release-react MyApp-Android android
```

The [React Native guide](https://patchkite.github.io/docs/guides/react-native/) covers deployment keys per build, code signing, manual control, and verification. See the [API reference](https://patchkite.github.io/docs/reference/react-native-api/) for every function and option.

## Development

| Path | Description |
|---|---|
| `src/` | TypeScript API |
| `android/`, `ios/` | Native module (Kotlin, Swift/Objective-C++) |
| `ios-tests/` | Swift package that unit-tests the iOS core on macOS |
| `test/fixtures/` | Reference values from the server (package hash, signatures, zips, bsdiff) |
| `example/` | Example app that links the SDK from this folder |

```bash
npm install && npm run typecheck
(cd ios-tests && swift test)
(cd example && npm install && cd android && ./gradlew :patchkite_react-native:testDebugUnitTest)
```

## License

[MIT](LICENSE)
