import type { CodegenTypes, TurboModule } from "react-native";
import { TurboModuleRegistry } from "react-native";

export type DownloadProgressEvent = {
  receivedBytes: CodegenTypes.Double;
  totalBytes: CodegenTypes.Double;
};

export interface Spec extends TurboModule {
  getConfiguration(): Promise<CodegenTypes.UnsafeObject>;
  getUpdateMetadata(updateState: CodegenTypes.Int32): Promise<CodegenTypes.UnsafeObject | null>;
  downloadUpdate(updatePackage: CodegenTypes.UnsafeObject): Promise<CodegenTypes.UnsafeObject>;
  installUpdate(packageHash: string, installMode: CodegenTypes.Int32): Promise<void>;
  isFailedUpdate(packageHash: string): Promise<boolean>;
  isFirstRun(packageHash: string): Promise<boolean>;
  notifyApplicationReady(): Promise<void>;
  popRollbackReport(): Promise<CodegenTypes.UnsafeObject | null>;
  getValue(key: string): Promise<string | null>;
  setValue(key: string, value: string): Promise<void>;
  restartApp(): void;
  clearUpdates(): void;
  readonly onDownloadProgress: CodegenTypes.EventEmitter<DownloadProgressEvent>;
}

export default TurboModuleRegistry.getEnforcing<Spec>("Patchkite");
