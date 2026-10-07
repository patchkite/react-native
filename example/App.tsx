import React, { useEffect, useState } from 'react';
import { Button, Image, StyleSheet, Text, View } from 'react-native';
import patchkite, { type LocalPackage } from '@patchkite/react-native';

// Change this text, then run `patchkite release-react` to test an OTA update.
const BUNDLE_MESSAGE = 'Hello from the bundle shipped in the binary';

const statusLabel: Record<number, string> = {
  [patchkite.SyncStatus.UP_TO_DATE]: 'Up to date',
  [patchkite.SyncStatus.UPDATE_INSTALLED]: 'Update installed (restart to apply)',
  [patchkite.SyncStatus.UPDATE_IGNORED]: 'Update ignored',
  [patchkite.SyncStatus.UNKNOWN_ERROR]: 'Error',
  [patchkite.SyncStatus.SYNC_IN_PROGRESS]: 'Sync in progress',
  [patchkite.SyncStatus.CHECKING_FOR_UPDATE]: 'Checking for update...',
  [patchkite.SyncStatus.AWAITING_USER_ACTION]: 'Waiting for user',
  [patchkite.SyncStatus.DOWNLOADING_PACKAGE]: 'Downloading...',
  [patchkite.SyncStatus.INSTALLING_UPDATE]: 'Installing...',
};

function App() {
  const [status, setStatus] = useState('-');
  const [progress, setProgress] = useState('');
  const [running, setRunning] = useState<LocalPackage | null>(null);

  useEffect(() => {
    patchkite.getUpdateMetadata().then(setRunning);
  }, []);

  const sync = (installMode = patchkite.InstallMode.IMMEDIATE) =>
    patchkite
      .sync(
        { installMode },
        s => setStatus(statusLabel[s] ?? String(s)),
        p => setProgress(`${p.receivedBytes}/${p.totalBytes} bytes`),
      )
      .catch(e => setStatus(`Error: ${e.message}`));

  const syncWithDialog = () =>
    patchkite
      .sync(
        { installMode: patchkite.InstallMode.IMMEDIATE, updateDialog: { appendReleaseDescription: true } },
        s => setStatus(statusLabel[s] ?? String(s)),
      )
      .catch(e => setStatus(`Error: ${e.message}`));

  return (
    <View style={styles.container}>
      <Text style={styles.title} testID="message">
        {BUNDLE_MESSAGE}
      </Text>
      <Image source={require('./assets/noise.png')} style={{ width: 96, height: 96 }} />
      <Text testID="label">Running: {running ? `${running.label} (${running.packageHash.slice(0, 8)})` : 'binary'}</Text>
      <Text testID="status">Status: {status}</Text>
      <Text>{progress}</Text>
      <Button title="Sync now" onPress={() => sync()} />
      <Button title="Sync on resume" onPress={() => sync(patchkite.InstallMode.ON_NEXT_RESUME)} />
      <Button title="Sync on suspend" onPress={() => sync(patchkite.InstallMode.ON_NEXT_SUSPEND)} />
      <Button title="Sync with dialog" onPress={syncWithDialog} />
      <Button title="Restart app" onPress={() => patchkite.restartApp()} />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, justifyContent: 'center', alignItems: 'center', gap: 12, padding: 24 },
  title: { fontSize: 22, fontWeight: '600', textAlign: 'center' },
});

export default patchkite({ checkFrequency: patchkite.CheckFrequency.ON_APP_RESUME })(App);
