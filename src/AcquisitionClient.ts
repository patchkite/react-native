import type { Configuration } from "./types";

export interface RemoteUpdateInfo {
  is_available: boolean;
  is_mandatory: boolean;
  should_run_binary_version: boolean;
  update_app_version: boolean;
  target_binary_range: string;
  app_version: string;
  download_url?: string;
  package_hash?: string;
  label?: string;
  package_size?: number;
  description?: string;
  is_diff?: boolean;
}

const BASE = "v1/public";

/** Client acquisition API. */
export class AcquisitionClient {
  constructor(private readonly config: Configuration) {}

  private url(path: string) {
    return `${this.config.serverUrl.replace(/\/$/, "")}/${BASE}/${path}`;
  }

  async updateCheck(current: { appVersion: string; packageHash?: string; label?: string; binaryHash?: string }): Promise<RemoteUpdateInfo> {
    const params: Record<string, string> = {
      deployment_key: this.config.deploymentKey,
      app_version: current.appVersion,
      client_unique_id: this.config.clientUniqueId,
      // The native SDK can apply binary patches (diffs are much smaller for large bundles).
      client_features: "bsdiff",
    };
    if (current.packageHash) params.package_hash = current.packageHash;
    if (current.label) params.label = current.label;
    if (!current.packageHash && current.binaryHash) params.binary_hash = current.binaryHash;
    const qs = Object.entries(params)
      .map(([k, v]) => `${k}=${encodeURIComponent(v)}`)
      .join("&");
    const res = await fetch(this.url(`update_check?${qs}`), { headers: { Accept: "application/json" } });
    if (!res.ok) throw new Error(`[Patchkite] update_check failed: ${res.status} ${await res.text()}`);
    return ((await res.json()) as { update_info: RemoteUpdateInfo }).update_info;
  }

  private async post(path: string, body: object) {
    const res = await fetch(this.url(path), {
      method: "POST",
      headers: { Accept: "application/json", "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`[Patchkite] ${path} failed: ${res.status}`);
  }

  reportDeploy(body: {
    deployment_key?: string;
    app_version: string;
    label?: string;
    status?: string;
    previous_label_or_app_version?: string;
    previous_deployment_key?: string;
  }) {
    return this.post("report_status/deploy", {
      client_unique_id: this.config.clientUniqueId,
      ...body,
      deployment_key: body.deployment_key ?? this.config.deploymentKey,
    });
  }

  reportDownload(label: string, deploymentKey?: string) {
    return this.post("report_status/download", {
      client_unique_id: this.config.clientUniqueId,
      deployment_key: deploymentKey ?? this.config.deploymentKey,
      label,
    });
  }
}
