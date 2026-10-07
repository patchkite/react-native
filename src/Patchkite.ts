import { Alert, AppState, type AppStateStatus, type EventSubscription } from "react-native";
import { AcquisitionClient, type RemoteUpdateInfo } from "./AcquisitionClient";
import NativePatchkite from "./NativePatchkite";
import {
  DeploymentStatus,
  InstallMode,
  SyncStatus,
  UpdateState,
  type Configuration,
  type DownloadProgressCallback,
  type HandleBinaryVersionMismatchCallback,
  type LocalPackage,
  type Package,
  type RemotePackage,
  type RollbackRetryOptions,
  type SyncOptions,
  type SyncStatusChangedCallback,
  type UpdateDialog,
} from "./types";

const log = (msg: string) => console.log(`[Patchkite] ${msg}`);

const KEY_LAST_REPORTED = "lastReported";
const KEY_ROLLBACK_INFO = "latestRollbackInfo";

export const DEFAULT_UPDATE_DIALOG: Required<UpdateDialog> = {
  appendReleaseDescription: false,
  descriptionPrefix: " Description: ",
  mandatoryContinueButtonLabel: "Continue",
  mandatoryUpdateMessage: "An update is available that must be installed.",
  optionalIgnoreButtonLabel: "Ignore",
  optionalInstallButtonLabel: "Install",
  optionalUpdateMessage: "An update is available. Would you like to install it?",
  title: "Update available",
};

export const DEFAULT_ROLLBACK_RETRY_OPTIONS: Required<RollbackRetryOptions> = {
  delayInHours: 24,
  maxRetryAttempts: 1,
};

// ------------------------------------------------------------------ configuration

let cachedConfig: Configuration | undefined;

export async function getConfiguration(): Promise<Configuration> {
  cachedConfig ??= (await NativePatchkite.getConfiguration()) as unknown as Configuration;
  return cachedConfig;
}

// ------------------------------------------------------------------ restart manager

let restartAllowed = true;
let restartQueued = false;
let restartInProgress = false;

export function allowRestart() {
  restartAllowed = true;
  if (restartQueued) {
    log("Running the queued restart.");
    restartQueued = false;
    void restartApp(false);
  }
}

export function disallowRestart() {
  restartAllowed = false;
}

export function clearPendingRestart() {
  restartQueued = false;
}

export async function restartApp(onlyIfUpdateIsPending = false): Promise<void> {
  if (restartInProgress) return;
  if (onlyIfUpdateIsPending && !(await NativePatchkite.getUpdateMetadata(UpdateState.PENDING))) return;
  if (!restartAllowed) {
    log("Restart deferred because disallowRestart() is active.");
    restartQueued = true;
    return;
  }
  restartInProgress = true;
  NativePatchkite.restartApp();
}

// ------------------------------------------------------------------ package

type RawPackage = Omit<Package, "isFirstRun" | "failedInstall" | "isPending"> & Partial<Package>;

async function toLocalPackage(raw: RawPackage, isPending: boolean): Promise<LocalPackage> {
  const [isFirstRun, failedInstall] = await Promise.all([
    NativePatchkite.isFirstRun(raw.packageHash),
    NativePatchkite.isFailedUpdate(raw.packageHash),
  ]);
  return {
    appVersion: raw.appVersion,
    deploymentKey: raw.deploymentKey,
    description: raw.description ?? "",
    isMandatory: !!raw.isMandatory,
    label: raw.label,
    packageHash: raw.packageHash,
    packageSize: raw.packageSize ?? 0,
    isFirstRun,
    failedInstall,
    isPending,
    install: (installMode = InstallMode.ON_NEXT_RESTART, minimumBackgroundDuration = 0, onInstalled) =>
      installPackage(raw.packageHash, installMode, minimumBackgroundDuration, onInstalled),
  };
}

let resumeSubscription: EventSubscription | undefined;

async function installPackage(
  packageHash: string,
  installMode: InstallMode,
  minimumBackgroundDuration: number,
  onInstalled?: () => void,
) {
  await NativePatchkite.installUpdate(packageHash, installMode);
  onInstalled?.();
  resumeSubscription?.remove();
  resumeSubscription = undefined;

  if (installMode === InstallMode.IMMEDIATE) {
    await restartApp(false);
    return;
  }
  if (installMode === InstallMode.ON_NEXT_RESUME || installMode === InstallMode.ON_NEXT_SUSPEND) {
    let backgroundAt: number | undefined;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const durationMs = minimumBackgroundDuration * 1000;
    resumeSubscription = AppState.addEventListener("change", (state: AppStateStatus) => {
      if (state === "background") {
        backgroundAt = Date.now();
        if (installMode === InstallMode.ON_NEXT_SUSPEND) {
          timer = setTimeout(() => void restartApp(true), durationMs);
        }
      } else if (state === "active") {
        if (timer) clearTimeout(timer);
        if (backgroundAt !== undefined && Date.now() - backgroundAt >= durationMs) {
          void restartApp(true);
        }
        backgroundAt = undefined;
      }
    });
  }
}

export async function getUpdateMetadata(updateState: UpdateState = UpdateState.RUNNING): Promise<LocalPackage | null> {
  const raw = (await NativePatchkite.getUpdateMetadata(updateState)) as unknown as (RawPackage & { isPending?: boolean }) | null;
  if (!raw) return null;
  return toLocalPackage(raw, !!raw.isPending);
}

/** The latest package (pending or running). */
export const getCurrentPackage = () => getUpdateMetadata(UpdateState.LATEST);

// ------------------------------------------------------------------ check & download

export async function checkForUpdate(
  deploymentKey?: string,
  handleBinaryVersionMismatchCallback?: HandleBinaryVersionMismatchCallback,
): Promise<RemotePackage | null> {
  const base = await getConfiguration();
  const config = { ...base, deploymentKey: deploymentKey ?? base.deploymentKey };
  if (!config.deploymentKey) throw new Error("[Patchkite] Deployment key is not set (Info.plist/strings.xml `PatchkiteDeploymentKey`).");

  const local = await getUpdateMetadata(UpdateState.LATEST);
  const query: { appVersion: string; packageHash?: string; label?: string; binaryHash?: string } = local
    ? { appVersion: local.appVersion, packageHash: local.packageHash, label: local.label }
    : { appVersion: config.appVersion, binaryHash: config.binaryHash ?? undefined };
  // If the binary version changed, the old update is no longer relevant.
  if (local && local.appVersion !== config.appVersion) {
    query.appVersion = config.appVersion;
  }

  const client = new AcquisitionClient(config);
  const info = await client.updateCheck(query);

  if (info.should_run_binary_version && local) {
    log("Server requested reverting to the binary version (release disabled/rolled back).");
    NativePatchkite.clearUpdates();
    return null;
  }
  if (!info.is_available || info.update_app_version || (local && info.package_hash === local.packageHash)) {
    if (info.update_app_version) {
      log(`An update is available for binary version ${info.target_binary_range}, but this binary is ${config.appVersion}. Update the app from the store.`);
      handleBinaryVersionMismatchCallback?.(remoteFromInfo(info, config.deploymentKey, false, config));
    }
    return null;
  }
  const failedInstall = await NativePatchkite.isFailedUpdate(info.package_hash!);
  return remoteFromInfo(info, config.deploymentKey, failedInstall, config);
}

function remoteFromInfo(info: RemoteUpdateInfo, deploymentKey: string, failedInstall: boolean, config: Configuration): RemotePackage {
  const pkg: Omit<RemotePackage, "download"> = {
    appVersion: info.target_binary_range ?? info.app_version,
    deploymentKey,
    description: info.description ?? "",
    failedInstall,
    isFirstRun: false,
    isMandatory: info.is_mandatory,
    isPending: false,
    label: info.label ?? "",
    packageHash: info.package_hash ?? "",
    packageSize: info.package_size ?? 0,
    downloadUrl: info.download_url ?? "",
  };
  return {
    ...pkg,
    async download(progressCallback?: DownloadProgressCallback) {
      if (!pkg.downloadUrl) throw new Error("[Patchkite] Package has no download URL.");
      let sub: EventSubscription | undefined;
      if (progressCallback) {
        sub = NativePatchkite.onDownloadProgress((e) => progressCallback({ receivedBytes: e.receivedBytes, totalBytes: e.totalBytes }));
      }
      try {
        const raw = (await NativePatchkite.downloadUpdate({
          ...pkg,
          appVersion: config.appVersion,
          isDiff: !!info.is_diff,
        })) as unknown as RawPackage;
        new AcquisitionClient({ ...config, deploymentKey }).reportDownload(pkg.label).catch(() => {});
        return toLocalPackage(raw, false);
      } finally {
        sub?.remove();
      }
    },
  };
}

// ------------------------------------------------------------------ status report

async function reportStatus() {
  const config = await getConfiguration();
  const client = new AcquisitionClient(config);

  const rollback = (await NativePatchkite.popRollbackReport()) as unknown as RawPackage | null;
  if (rollback) {
    log(`Update ${rollback.label} failed and was rolled back.`);
    await client
      .reportDeploy({ deployment_key: rollback.deploymentKey, app_version: config.appVersion, label: rollback.label, status: DeploymentStatus.FAILED })
      .catch(() => {});
  }

  const running = (await NativePatchkite.getUpdateMetadata(UpdateState.RUNNING)) as unknown as RawPackage | null;
  const identifier = running ? `${running.deploymentKey}:${running.label}` : `binary:${config.appVersion}`;
  const last = await NativePatchkite.getValue(KEY_LAST_REPORTED);
  if (identifier === last) return;

  let previous: { deploymentKey?: string; labelOrAppVersion?: string } = {};
  if (last) {
    const [key, labelOrVersion] = last.split(/:(.*)/s);
    previous = key === "binary" ? { labelOrAppVersion: labelOrVersion } : { deploymentKey: key, labelOrAppVersion: labelOrVersion };
  }
  try {
    await client.reportDeploy(
      running
        ? {
            deployment_key: running.deploymentKey,
            app_version: config.appVersion,
            label: running.label,
            status: DeploymentStatus.SUCCEEDED,
            previous_label_or_app_version: previous.labelOrAppVersion,
            previous_deployment_key: previous.deploymentKey,
          }
        : { app_version: config.appVersion, previous_label_or_app_version: previous.labelOrAppVersion, previous_deployment_key: previous.deploymentKey },
    );
    await NativePatchkite.setValue(KEY_LAST_REPORTED, identifier);
  } catch {
    // retried on the next notifyAppReady
  }
}

let notifyAppReadyPromise: Promise<void> | undefined;

/** Tell Patchkite the update is running successfully (prevents auto-rollback). */
export function notifyAppReady(): Promise<void> {
  notifyAppReadyPromise ??= (async () => {
    await NativePatchkite.notifyApplicationReady();
    reportStatus().catch(() => {});
  })();
  return notifyAppReadyPromise;
}

// ------------------------------------------------------------------ rollback retry

async function shouldUpdateBeIgnored(remote: RemotePackage, options: SyncOptions): Promise<boolean> {
  if (!remote.failedInstall || options.ignoreFailedUpdates === false) return false;
  if (!options.rollbackRetryOptions) return true;
  const opts = { ...DEFAULT_ROLLBACK_RETRY_OPTIONS, ...options.rollbackRetryOptions };
  const raw = await NativePatchkite.getValue(KEY_ROLLBACK_INFO);
  const info = raw ? (JSON.parse(raw) as { packageHash: string; time: number; count: number }) : null;
  if (!info || info.packageHash !== remote.packageHash) {
    await NativePatchkite.setValue(KEY_ROLLBACK_INFO, JSON.stringify({ packageHash: remote.packageHash, time: Date.now(), count: 0 }));
    return true;
  }
  const hoursSince = (Date.now() - info.time) / 36e5;
  if (hoursSince >= opts.delayInHours && info.count < opts.maxRetryAttempts) {
    await NativePatchkite.setValue(KEY_ROLLBACK_INFO, JSON.stringify({ ...info, time: Date.now(), count: info.count + 1 }));
    return false;
  }
  return true;
}

// ------------------------------------------------------------------ sync

let syncInProgress = false;

export async function sync(
  options: SyncOptions = {},
  syncStatusChangeCallback?: SyncStatusChangedCallback,
  downloadProgressCallback?: DownloadProgressCallback,
  handleBinaryVersionMismatchCallback?: HandleBinaryVersionMismatchCallback,
): Promise<SyncStatus> {
  // An update is already installed and waiting for a restart (resume/suspend), or a reload is in progress:
  // don't start a network request, because the reload tears down the RN instance mid-request.
  if (restartInProgress || resumeSubscription) {
    (syncStatusChangeCallback ?? defaultStatusLogger)(SyncStatus.UPDATE_INSTALLED);
    return SyncStatus.UPDATE_INSTALLED;
  }
  if (syncInProgress) {
    (syncStatusChangeCallback ?? defaultStatusLogger)(SyncStatus.SYNC_IN_PROGRESS);
    return SyncStatus.SYNC_IN_PROGRESS;
  }
  syncInProgress = true;
  try {
    return await syncInternal(options, syncStatusChangeCallback ?? defaultStatusLogger, downloadProgressCallback, handleBinaryVersionMismatchCallback);
  } finally {
    syncInProgress = false;
  }
}

function defaultStatusLogger(status: SyncStatus) {
  const messages: Partial<Record<SyncStatus, string>> = {
    [SyncStatus.CHECKING_FOR_UPDATE]: "Checking for update.",
    [SyncStatus.AWAITING_USER_ACTION]: "Awaiting user action.",
    [SyncStatus.DOWNLOADING_PACKAGE]: "Downloading package.",
    [SyncStatus.INSTALLING_UPDATE]: "Installing update.",
    [SyncStatus.UP_TO_DATE]: "App is up to date.",
    [SyncStatus.UPDATE_IGNORED]: "User cancelled the update.",
    [SyncStatus.UPDATE_INSTALLED]: "Update is installed and will be run on the next app restart.",
    [SyncStatus.UNKNOWN_ERROR]: "An unknown error occurred.",
    [SyncStatus.SYNC_IN_PROGRESS]: "Sync already in progress.",
  };
  const m = messages[status];
  if (m) log(m);
}

async function syncInternal(
  options: SyncOptions,
  onStatus: SyncStatusChangedCallback,
  onProgress?: DownloadProgressCallback,
  onMismatch?: HandleBinaryVersionMismatchCallback,
): Promise<SyncStatus> {
  const opts = {
    installMode: InstallMode.ON_NEXT_RESTART,
    mandatoryInstallMode: InstallMode.IMMEDIATE,
    minimumBackgroundDuration: 0,
    ignoreFailedUpdates: true,
    ...options,
  };
  const updateDialog = opts.updateDialog === true ? DEFAULT_UPDATE_DIALOG : opts.updateDialog ? { ...DEFAULT_UPDATE_DIALOG, ...opts.updateDialog } : null;

  try {
    await notifyAppReady();
    onStatus(SyncStatus.CHECKING_FOR_UPDATE);
    const remote = await checkForUpdate(opts.deploymentKey, onMismatch);

    const doDownloadAndInstall = async () => {
      onStatus(SyncStatus.DOWNLOADING_PACKAGE);
      const local = await remote!.download(onProgress);
      const mode = local.isMandatory ? opts.mandatoryInstallMode : opts.installMode;
      onStatus(SyncStatus.INSTALLING_UPDATE);
      await local.install(mode, opts.minimumBackgroundDuration, () => onStatus(SyncStatus.UPDATE_INSTALLED));
      return SyncStatus.UPDATE_INSTALLED;
    };

    if (!remote || (await shouldUpdateBeIgnored(remote, opts))) {
      if (remote) log("This update previously failed and was rolled back; ignoring it.");
      const current = await getUpdateMetadata(UpdateState.LATEST);
      const status = current?.isPending ? SyncStatus.UPDATE_INSTALLED : SyncStatus.UP_TO_DATE;
      onStatus(status);
      return status;
    }

    if (!updateDialog) return await doDownloadAndInstall();

    onStatus(SyncStatus.AWAITING_USER_ACTION);
    return await new Promise<SyncStatus>((resolve, reject) => {
      let message = remote.isMandatory ? updateDialog.mandatoryUpdateMessage : updateDialog.optionalUpdateMessage;
      if (updateDialog.appendReleaseDescription && remote.description) message += `${updateDialog.descriptionPrefix}${remote.description}`;
      const install = { text: remote.isMandatory ? updateDialog.mandatoryContinueButtonLabel : updateDialog.optionalInstallButtonLabel, onPress: () => doDownloadAndInstall().then(resolve, reject) };
      const buttons = remote.isMandatory
        ? [install]
        : [
            {
              text: updateDialog.optionalIgnoreButtonLabel,
              onPress: () => {
                onStatus(SyncStatus.UPDATE_IGNORED);
                resolve(SyncStatus.UPDATE_IGNORED);
              },
            },
            install,
          ];
      Alert.alert(updateDialog.title, message, buttons, { cancelable: false });
    });
  } catch (error) {
    onStatus(SyncStatus.UNKNOWN_ERROR);
    log(String(error instanceof Error ? error.message : error));
    throw error;
  }
}

export function clearUpdates() {
  NativePatchkite.clearUpdates();
}
