# Contributing to the Patchkite React Native SDK

Thanks for helping! Open an issue first for larger changes.

```bash
npm install && npm run typecheck
(cd ios-tests && swift test)                     # iOS core, macOS only
(cd example && npm install)
(cd example/android && ./gradlew :patchkite_react-native:testDebugUnitTest)
```

Try changes end to end with the example app against a local server (see the [quickstart](https://docs.patchkite.com/start/quickstart/)). Test with a release build — debug builds load JavaScript from Metro.

- The package hash, signature, diff, and bsdiff logic must match the server exactly, as specified in the [package format reference](https://docs.patchkite.com/reference/package-format/). The Kotlin and Swift tests check it against `test/fixtures`, which are synced from server releases by `scripts/update-fixtures.sh`.
- Keep Android and iOS behavior and log messages consistent. Log lines start with `[Patchkite]`; the CLI's `debug` command filters on it.

## Releases

Maintainers bump `version` in `package.json`, add a CHANGELOG entry, and push a `vX.Y.Z` tag. CI publishes to npm with provenance.
