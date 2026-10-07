/** Public enums & types. */

export enum CheckFrequency {
  ON_APP_START = 0,
  ON_APP_RESUME = 1,
  MANUAL = 2,
}

export enum InstallMode {
  IMMEDIATE = 0,
  ON_NEXT_RESTART = 1,
  ON_NEXT_RESUME = 2,
  ON_NEXT_SUSPEND = 3,
}

export enum SyncStatus {
  UP_TO_DATE = 0,
  UPDATE_INSTALLED = 1,
  UPDATE_IGNORED = 2,
  UNKNOWN_ERROR = 3,
  SYNC_IN_PROGRESS = 4,
  CHECKING_FOR_UPDATE = 5,
  AWAITING_USER_ACTION = 6,
  DOWNLOADING_PACKAGE = 7,
  INSTALLING_UPDATE = 8,
}

export enum UpdateState {
  RUNNING = 0,
  PENDING = 1,
  LATEST = 2,
}

export enum DeploymentStatus {
  FAILED = "DeploymentFailed",
  SUCCEEDED = "DeploymentSucceeded",
}

export interface DownloadProgress {
  totalBytes: number;
  receivedBytes: number;
}

export type DownloadProgressCallback = (progress: DownloadProgress) => void;
export type SyncStatusChangedCallback = (status: SyncStatus) => void;
export type HandleBinaryVersionMismatchCallback = (update: RemotePackage) => void;

export interface Package {
  appVersion: string;
  deploymentKey: string;
  description: string;
  failedInstall: boolean;
  isFirstRun: boolean;
  isMandatory: boolean;
  isPending: boolean;
  label: string;
  packageHash: string;
  packageSize: number;
}

export interface LocalPackage extends Package {
  install(installMode?: InstallMode, minimumBackgroundDuration?: number, onInstalled?: () => void): Promise<void>;
}

export interface RemotePackage extends Package {
  downloadUrl: string;
  download(downloadProgressCallback?: DownloadProgressCallback): Promise<LocalPackage>;
}

export interface UpdateDialog {
  appendReleaseDescription?: boolean;
  descriptionPrefix?: string;
  mandatoryContinueButtonLabel?: string;
  mandatoryUpdateMessage?: string;
  optionalIgnoreButtonLabel?: string;
  optionalInstallButtonLabel?: string;
  optionalUpdateMessage?: string;
  title?: string;
}

export interface RollbackRetryOptions {
  /** Minimum hours before retrying an update that was rolled back (default 24). */
  delayInHours?: number;
  /** Maximum number of retry attempts (default 1). */
  maxRetryAttempts?: number;
}

export interface SyncOptions {
  deploymentKey?: string;
  installMode?: InstallMode;
  mandatoryInstallMode?: InstallMode;
  minimumBackgroundDuration?: number;
  updateDialog?: UpdateDialog | true | null;
  rollbackRetryOptions?: RollbackRetryOptions | null;
  ignoreFailedUpdates?: boolean;
}

export interface PatchkiteOptions extends SyncOptions {
  checkFrequency?: CheckFrequency;
}

export interface StatusReport {
  status?: DeploymentStatus;
  package?: Package;
  appVersion?: string;
  previousLabelOrAppVersion?: string;
  previousDeploymentKey?: string;
}

export interface Configuration {
  appVersion: string;
  deploymentKey: string;
  serverUrl: string;
  clientUniqueId: string;
  publicKey?: string;
  /** SHA-256 of the bundle shipped in the binary, used to patch from the binary on the first update. */
  binaryHash?: string | null;
}
