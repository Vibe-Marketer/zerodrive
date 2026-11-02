export type StorageMode = 'dfy' | 'byok';
export type CloudPreset = 'cloudflare_r2' | 'backblaze_b2' | 'aws_s3';
export type ExternalCloudType = 'google_drive' | 'dropbox' | 'onedrive';

export interface CloudNode {
  id: string;
  name: string;
  relativePath: string;
  sizeBytes: number;
  isFolder: boolean;
  sourceCloud: 'Vault' | 'Google_Drive' | 'Dropbox' | 'OneDrive';
  updatedAt: string;
  mimeType: string;
  isRetake?: boolean;
}

export type SpoolStatus = 'staging' | 'uploading' | 'synced' | 'purged' | 'retake';

export interface SpoolItem {
  id: string;
  filename: string;
  relativePath: string;
  sizeBytes: number;
  status: SpoolStatus;
  writeBackRemainingSec: number;
  uploadProgress: number; // 0 to 100
  uploadSpeedMBps: number;
  mediaDuration?: string;
  createdAt: number;
  sourceMode: 'move' | 'copy' | 'bypass';
}

export interface ConnectedCloud {
  id: string;
  type: ExternalCloudType;
  name: string;
  remoteName: string;
  connected: boolean;
  usedBytes: number;
  totalBytes: number;
  accountEmail: string;
}

export interface Telemetry {
  uploadSpeedMBps: number;
  downloadSpeedMBps: number;
  activeUploads: number;
  activeQueued: number;
  spoolUsedBytes: number;
  spoolMaxBytes: number;
  totalCloudBytes: number;
  totalSpaceSavedBytes: number;
  ramIndexCount: number;
  isOnline: boolean;
  streamGuardActive: boolean;
  mountStatus: 'mounted' | 'unmounting' | 'unmounted' | 'healing';
  lastRefreshed: number;
  nfsPid: number;
  ttfbMs: number;
}

export interface RcloneConfigSettings {
  volname: string;
  mountPath: string;
  cacheDir: string;
  vfsCacheMode: 'writes' | 'full';
  vfsCacheMaxSize: string;
  vfsWriteBack: string;
  vfsCacheMaxAge: string;
  vfsReadChunkSize: string;
  vfsReadChunkSizeLimit: string;
  bufferSize: string;
  vfsReadAhead: string;
  dirCacheTime: string;
  attrTimeout: string;
  rcAddr: string;
}
