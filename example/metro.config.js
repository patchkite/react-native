const path = require('path');
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');

const sdkRoot = path.resolve(__dirname, '..');
const escape = (s) => s.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');

/**
 * The Patchkite SDK is linked from the repository root. In a regular project,
 * `npm install @patchkite/react-native` is enough, with no extra configuration.
 *
 * @type {import('@react-native/metro-config').MetroConfig}
 */
const config = {
  watchFolders: [sdkRoot],
  resolver: {
    nodeModulesPaths: [path.resolve(__dirname, 'node_modules')],
    // The SDK's own devDependencies (react, react-native) must not be bundled twice.
    blockList: [new RegExp(`^${escape(path.join(sdkRoot, 'node_modules'))}/.*$`)],
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
