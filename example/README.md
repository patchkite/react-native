# Patchkite React Native example

Links `@patchkite/react-native` from the repository root.

```bash
npm install
cd ios && pod install && cd ..
```

Set `PatchkiteServerUrl`/`PatchkiteDeploymentKey` in `android/app/src/main/res/values/strings.xml` and `PatchkiteServerURL`/`PatchkiteDeploymentKey` in `ios/PatchkiteExample/Info.plist`, then run a **release** build:

```bash
npx react-native run-android --mode release
npx react-native run-ios --mode Release
```

Release an update from this folder with `patchkite release-react <app> android`.
