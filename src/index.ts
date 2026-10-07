import React from "react";
import { AppState, type AppStateStatus } from "react-native";
import * as Patchkite from "./Patchkite";
import {
  CheckFrequency,
  DeploymentStatus,
  InstallMode,
  SyncStatus,
  UpdateState,
  type PatchkiteOptions,
  type DownloadProgress,
  type HandleBinaryVersionMismatchCallback,
  type SyncStatusChangedCallback,
} from "./types";

type AnyComponent<P> = React.ComponentType<P>;

/** Optional hooks that can be defined on the root component. */
interface PatchkiteLifecycle {
  patchkiteStatusDidChange?(status: SyncStatus): void;
  patchkiteDownloadDidProgress?(progress: DownloadProgress): void;
  patchkiteOnBinaryVersionMismatch?: HandleBinaryVersionMismatchCallback;
}

function decorate<P extends object>(options: PatchkiteOptions, RootComponent: AnyComponent<P>): AnyComponent<P> {
  class PatchkiteComponent extends React.Component<P> {
    static displayName = `Patchkite(${RootComponent.displayName ?? RootComponent.name ?? "Component"})`;
    private rootRef = React.createRef<PatchkiteLifecycle>();
    private appStateSub?: { remove(): void };

    componentDidMount() {
      if (options.checkFrequency === CheckFrequency.MANUAL) {
        void Patchkite.notifyAppReady();
        return;
      }
      const root = () => this.rootRef.current;
      const statusCb: SyncStatusChangedCallback | undefined = (status) => root()?.patchkiteStatusDidChange?.(status);
      const progressCb = (p: DownloadProgress) => root()?.patchkiteDownloadDidProgress?.(p);
      const mismatchCb: HandleBinaryVersionMismatchCallback = (u) => root()?.patchkiteOnBinaryVersionMismatch?.(u);
      const hasStatusHook = () => typeof root()?.patchkiteStatusDidChange === "function";
      const run = () =>
        Patchkite.sync(options, hasStatusHook() ? statusCb : undefined, progressCb, mismatchCb).catch(() => {});

      void run();
      if (options.checkFrequency === CheckFrequency.ON_APP_RESUME) {
        let lastState = AppState.currentState;
        this.appStateSub = AppState.addEventListener("change", (state: AppStateStatus) => {
          if (state === "active" && lastState === "background") void run();
          lastState = state;
        });
      }
    }

    componentWillUnmount() {
      this.appStateSub?.remove();
    }

    render() {
      const props: P & { ref?: unknown } = { ...this.props };
      // Only class components can receive a ref for the lifecycle hooks.
      if (RootComponent.prototype?.render) props.ref = this.rootRef;
      return React.createElement(RootComponent as React.ComponentType<P>, props);
    }
  }
  return PatchkiteComponent as unknown as AnyComponent<P>;
}

/**
 * Usage:
 *
 *   export default patchkite(App)
 *   export default patchkite({ checkFrequency: patchkite.CheckFrequency.ON_APP_RESUME })(App)
 */
function patchkite<P extends object>(component: AnyComponent<P>): AnyComponent<P>;
function patchkite(options?: PatchkiteOptions): <P extends object>(component: AnyComponent<P>) => AnyComponent<P>;
function patchkite<P extends object>(arg?: PatchkiteOptions | AnyComponent<P>) {
  if (typeof arg === "function") return decorate({}, arg);
  return <Q extends object>(component: AnyComponent<Q>) => decorate(arg ?? {}, component);
}

patchkite.sync = Patchkite.sync;
patchkite.checkForUpdate = Patchkite.checkForUpdate;
patchkite.getUpdateMetadata = Patchkite.getUpdateMetadata;
patchkite.getCurrentPackage = Patchkite.getCurrentPackage;
patchkite.notifyAppReady = Patchkite.notifyAppReady;
patchkite.notifyApplicationReady = Patchkite.notifyAppReady;
patchkite.restartApp = Patchkite.restartApp;
patchkite.allowRestart = Patchkite.allowRestart;
patchkite.disallowRestart = Patchkite.disallowRestart;
patchkite.clearPendingRestart = Patchkite.clearPendingRestart;
patchkite.clearUpdates = Patchkite.clearUpdates;
patchkite.getConfiguration = Patchkite.getConfiguration;
patchkite.CheckFrequency = CheckFrequency;
patchkite.InstallMode = InstallMode;
patchkite.SyncStatus = SyncStatus;
patchkite.UpdateState = UpdateState;
patchkite.DeploymentStatus = DeploymentStatus;
patchkite.DEFAULT_UPDATE_DIALOG = Patchkite.DEFAULT_UPDATE_DIALOG;
patchkite.DEFAULT_ROLLBACK_RETRY_OPTIONS = Patchkite.DEFAULT_ROLLBACK_RETRY_OPTIONS;

export default patchkite;
export const {
  sync,
  checkForUpdate,
  getUpdateMetadata,
  notifyAppReady,
  restartApp,
  allowRestart,
  disallowRestart,
  clearUpdates,
} = Patchkite;
export * from "./types";
