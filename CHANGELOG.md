# Changelog

All notable changes to `@patchkite/react-native` are documented here. This project follows [Semantic Versioning](https://semver.org/).

## 1.0.0

First public release.

- `sync`, `checkForUpdate`, `getUpdateMetadata`, `notifyAppReady`, `restartApp`, `allowRestart`/`disallowRestart`, `clearUpdates`, and the root component wrapper.
- Install modes, update dialog, mandatory updates, rollback retry options.
- Diff updates and bsdiff binary patches, including patches against the store binary's bundle.
- Automatic rollback, code signing (RS256), and install metrics reporting.
