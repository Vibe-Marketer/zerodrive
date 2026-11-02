import {
  CloudNode,
  SpoolItem,
  Telemetry,
  ConnectedCloud,
  StorageMode,
  CloudPreset,
} from '../types/zerodrive';
import { applyBandwidthCap, tickSpoolItem } from './pureLogic';

export const INITIAL_CLOUD_NODES: CloudNode[] = [
  {
    id: 'n1',
    name: 'Nike_Air_Campaign_4K_ProRes422HQ.mov',
    relativePath: 'Vault/Commercials/Nike_Air/Nike_Air_Campaign_4K_ProRes422HQ.mov',
    sizeBytes: 42_850_000_000, // 42.85 GB
    isFolder: false,
    sourceCloud: 'Vault',
    updatedAt: '2026-11-01T14:32:00Z',
    mimeType: 'video/quicktime',
  },
  {
    id: 'n2',
    name: 'A002_C014_1102A_RawFootage.braw',
    relativePath: 'Vault/Rushes/Day_01/A002_C014_1102A_RawFootage.braw',
    sizeBytes: 12_400_000_000, // 12.4 GB
    isFolder: false,
    sourceCloud: 'Vault',
    updatedAt: '2026-11-02T08:15:00Z',
    mimeType: 'video/x-braw',
  },
  {
    id: 'n3',
    name: 'DaVinci_Resolve_ColorGrade_v4.drp',
    relativePath: 'Vault/Projects/Color/DaVinci_Resolve_ColorGrade_v4.drp',
    sizeBytes: 840_000_000, // 840 MB
    isFolder: false,
    sourceCloud: 'Vault',
    updatedAt: '2026-11-02T09:40:00Z',
    mimeType: 'application/x-resolve',
  },
  {
    id: 'n4',
    name: 'Brand_Identity_Guidelines_Master.pdf',
    relativePath: 'Google_Drive/Shared_Agency/Brand_Identity_Guidelines_Master.pdf',
    sizeBytes: 85_000_000, // 85 MB
    isFolder: false,
    sourceCloud: 'Google_Drive',
    updatedAt: '2026-10-28T16:20:00Z',
    mimeType: 'application/pdf',
  },
  {
    id: 'n5',
    name: 'Agency_Client_Pitch_2027.key',
    relativePath: 'Google_Drive/Presentations/Agency_Client_Pitch_2027.key',
    sizeBytes: 340_000_000, // 340 MB
    isFolder: false,
    sourceCloud: 'Google_Drive',
    updatedAt: '2026-10-31T11:05:00Z',
    mimeType: 'application/x-iwork-keynote-sffkey',
  },
  {
    id: 'n6',
    name: 'Podcast_Ep58_Master_Stems_Surround.wav',
    relativePath: 'Dropbox/Audio/Podcast_Ep58_Master_Stems_Surround.wav',
    sizeBytes: 2_150_000_000, // 2.15 GB
    isFolder: false,
    sourceCloud: 'Dropbox',
    updatedAt: '2026-10-30T19:50:00Z',
    mimeType: 'audio/wav',
  },
  {
    id: 'n7',
    name: 'SoundDesign_Foley_Atmosphere_Pack.zip',
    relativePath: 'Dropbox/SFX/SoundDesign_Foley_Atmosphere_Pack.zip',
    sizeBytes: 6_800_000_000, // 6.8 GB
    isFolder: false,
    sourceCloud: 'Dropbox',
    updatedAt: '2026-10-25T13:12:00Z',
    mimeType: 'application/zip',
  },
  {
    id: 'n8',
    name: 'Llama_3_8B_Instruct_Q5_KM.gguf',
    relativePath: 'Vault/AI_Models/Llama_3_8B_Instruct_Q5_KM.gguf',
    sizeBytes: 5_730_000_000, // 5.73 GB
    isFolder: false,
    sourceCloud: 'Vault',
    updatedAt: '2026-10-29T22:00:00Z',
    mimeType: 'application/octet-stream',
  },
  {
    id: 'n9',
    name: 'Commercials',
    relativePath: 'Vault/Commercials',
    sizeBytes: 0,
    isFolder: true,
    sourceCloud: 'Vault',
    updatedAt: '2026-11-01T10:00:00Z',
    mimeType: 'inode/directory',
  },
  {
    id: 'n10',
    name: 'Shared_Agency',
    relativePath: 'Google_Drive/Shared_Agency',
    sizeBytes: 0,
    isFolder: true,
    sourceCloud: 'Google_Drive',
    updatedAt: '2026-10-28T09:00:00Z',
    mimeType: 'inode/directory',
  },
  {
    id: 'n11',
    name: 'Audio',
    relativePath: 'Dropbox/Audio',
    sizeBytes: 0,
    isFolder: true,
    sourceCloud: 'Dropbox',
    updatedAt: '2026-10-30T12:00:00Z',
    mimeType: 'inode/directory',
  },
];

export const INITIAL_SPOOL_ITEMS: SpoolItem[] = [
  {
    id: 'spool_1',
    filename: 'Shot_04_VFX_Comp_Pass3.exr',
    relativePath: 'Vault/Commercials/Nike_Air/Shot_04_VFX_Comp_Pass3.exr',
    sizeBytes: 780_000_000, // 780 MB
    status: 'staging',
    writeBackRemainingSec: 11,
    uploadProgress: 0,
    uploadSpeedMBps: 0,
    mediaDuration: '00:04:12',
    createdAt: Date.now() - 4000,
    sourceMode: 'move',
  },
  {
    id: 'spool_2',
    filename: 'Interview_Broll_CamB_Take2.mov',
    relativePath: 'Vault/Rushes/Day_01/Interview_Broll_CamB_Take2.mov',
    sizeBytes: 2_400_000_000, // 2.4 GB
    status: 'uploading',
    writeBackRemainingSec: 0,
    uploadProgress: 42,
    uploadSpeedMBps: 34.5,
    mediaDuration: '00:08:45',
    createdAt: Date.now() - 25000,
    sourceMode: 'move',
  },
];

export const INITIAL_CONNECTED_CLOUDS: ConnectedCloud[] = [
  {
    id: 'c_gdrive',
    type: 'google_drive',
    name: 'Google Drive',
    remoteName: 'ext_gdrive',
    connected: true,
    usedBytes: 840_000_000_000, // 840 GB
    totalBytes: 2_000_000_000_000, // 2 TB
    accountEmail: 'alex.creator@gmail.com',
  },
  {
    id: 'c_dropbox',
    type: 'dropbox',
    name: 'Dropbox',
    remoteName: 'ext_dropbox',
    connected: true,
    usedBytes: 1_820_000_000_000, // 1.82 TB
    totalBytes: 3_000_000_000_000, // 3 TB
    accountEmail: 'alex@studios.io',
  },
  {
    id: 'c_onedrive',
    type: 'onedrive',
    name: 'Microsoft OneDrive',
    remoteName: 'ext_onedrive',
    connected: false,
    usedBytes: 0,
    totalBytes: 1_000_000_000_000,
    accountEmail: '',
  },
];
