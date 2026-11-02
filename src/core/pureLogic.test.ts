import test from 'node:test';
import assert from 'node:assert/strict';
import {
  searchCloudNodes,
  getDirtyFileCount,
  shouldBlockTermination,
  formatBytes,
  generateRcloneConfig,
  applyBandwidthCap,
  tickSpoolItem,
  checkAPFSFreeSpace,
} from './pureLogic';
import { CloudNode, SpoolItem } from '../types/zerodrive';

test('formatBytes handles zero and standard units correctly', () => {
  assert.equal(formatBytes(0), '0 B');
  assert.equal(formatBytes(1024), '1 KB');
  assert.equal(formatBytes(1024 * 1024 * 500), '500 MB');
  assert.equal(formatBytes(1024 * 1024 * 1024 * 1.5), '1.5 GB');
  assert.equal(formatBytes(1024 * 1024 * 1024 * 1024 * 2), '2 TB');
});

test('searchCloudNodes filters correctly and measures search duration < 10ms', () => {
  const sampleNodes: CloudNode[] = [
    {
      id: '1',
      name: 'Cinematic_Commercial_4K_ProRes.mov',
      relativePath: 'Vault/Projects/Cinematic_Commercial_4K_ProRes.mov',
      sizeBytes: 1024 * 1024 * 1024 * 18,
      isFolder: false,
      sourceCloud: 'Vault',
      updatedAt: '2026-11-01',
      mimeType: 'video/quicktime',
    },
    {
      id: '2',
      name: 'Client_Brief_v3.pdf',
      relativePath: 'Google_Drive/Documents/Client_Brief_v3.pdf',
      sizeBytes: 1024 * 1024 * 4,
      isFolder: false,
      sourceCloud: 'Google_Drive',
      updatedAt: '2026-10-28',
      mimeType: 'application/pdf',
    },
    {
      id: '3',
      name: 'Podcast_Ep42_Master_Stems.wav',
      relativePath: 'Dropbox/Audio/Podcast_Ep42_Master_Stems.wav',
      sizeBytes: 1024 * 1024 * 850,
      isFolder: false,
      sourceCloud: 'Dropbox',
      updatedAt: '2026-10-30',
      mimeType: 'audio/wav',
    },
  ];

  const search = searchCloudNodes(sampleNodes, 'prores');
  assert.equal(search.results.length, 1);
  assert.equal(search.results[0].name, 'Cinematic_Commercial_4K_ProRes.mov');
  assert.ok(search.searchDurationMs < 10, 'Search took less than 10ms');

  const searchEmpty = searchCloudNodes(sampleNodes, '');
  assert.equal(searchEmpty.results.length, 3);
});

test('getDirtyFileCount and shouldBlockTermination protect against data loss', () => {
  const cleanSpool: SpoolItem[] = [
    {
      id: 's1',
      filename: 'done.mov',
      relativePath: 'Vault/done.mov',
      sizeBytes: 1024 * 1024 * 500,
      status: 'synced',
      writeBackRemainingSec: 0,
      uploadProgress: 100,
      uploadSpeedMBps: 0,
      createdAt: Date.now(),
      sourceMode: 'move',
    },
  ];
  assert.equal(shouldBlockTermination(cleanSpool), false);
  assert.equal(getDirtyFileCount(cleanSpool).dirtyCount, 0);

  const dirtySpool: SpoolItem[] = [
    ...cleanSpool,
    {
      id: 's2',
      filename: 'render.mov',
      relativePath: 'Vault/render.mov',
      sizeBytes: 1024 * 1024 * 800,
      status: 'staging',
      writeBackRemainingSec: 12,
      uploadProgress: 0,
      uploadSpeedMBps: 0,
      createdAt: Date.now(),
      sourceMode: 'move',
    },
  ];
  assert.equal(shouldBlockTermination(dirtySpool), true);
  const dirtyInfo = getDirtyFileCount(dirtySpool);
  assert.equal(dirtyInfo.dirtyCount, 1);
  assert.equal(dirtyInfo.dirtyBytes, 1024 * 1024 * 800);
});

test('applyBandwidthCap enforces 3 MB/s Stream Guard limit', () => {
  assert.equal(applyBandwidthCap(45.0, false), 45.0);
  assert.equal(applyBandwidthCap(45.0, true), 3.0);
  assert.equal(applyBandwidthCap(2.1, true), 2.1);
});

test('generateRcloneConfig formats multi-cloud combine remote correctly', () => {
  const config = generateRcloneConfig({
    primaryRemoteType: 's3',
    primaryProvider: 'Cloudflare',
    bucket: 'my-vault-bucket',
    connectedClouds: [
      { name: 'Google Drive', remote: 'ext_gdrive' },
      { name: 'Dropbox', remote: 'ext_dropbox' },
    ],
  });

  assert.ok(config.includes('[primary_vault]'));
  assert.ok(config.includes('[ZeroDriveUnified]'));
  assert.ok(config.includes('type = combine'));
  assert.ok(config.includes('"Vault=primary_vault:my-vault-bucket"'));
  assert.ok(config.includes('"Google_Drive=ext_gdrive:"'));
  assert.ok(config.includes('"Dropbox=ext_dropbox:"'));
});

test('tickSpoolItem advances staging countdown to uploading and finishes syncing', () => {
  const stagingItem: SpoolItem = {
    id: 's1',
    filename: 'clip.mp4',
    relativePath: 'Vault/clip.mp4',
    sizeBytes: 10 * 1024 * 1024, // 10 MB
    status: 'staging',
    writeBackRemainingSec: 2,
    uploadProgress: 0,
    uploadSpeedMBps: 0,
    createdAt: Date.now(),
    sourceMode: 'move',
  };

  const ticked1 = tickSpoolItem(stagingItem, 10, 1);
  assert.equal(ticked1.writeBackRemainingSec, 1);
  assert.equal(ticked1.status, 'staging');

  const ticked2 = tickSpoolItem(ticked1, 10, 1);
  assert.equal(ticked2.status, 'uploading');
  assert.equal(ticked2.writeBackRemainingSec, 0);

  // 10 MB file at 10 MB/s should complete in 1 tick of 1s
  const ticked3 = tickSpoolItem(ticked2, 10, 1);
  assert.equal(ticked3.status, 'synced');
  assert.equal(ticked3.uploadProgress, 100);
});

test('checkAPFSFreeSpace correctly alerts on low and critical host Mac SSD space', () => {
  // Scenario 1: Healthy space (120 GB free, 2 GB file)
  const healthy = checkAPFSFreeSpace(2 * 1024 * 1024 * 1024, 120 * 1024 * 1024 * 1024);
  assert.equal(healthy.canStage, true);
  assert.equal(healthy.isWarning, false);
  assert.equal(healthy.isCritical, false);
  assert.equal(healthy.recommendedMode, 'move');

  // Scenario 2: Low space warning (< 15 GB free, 1 GB file)
  const low = checkAPFSFreeSpace(1 * 1024 * 1024 * 1024, 10 * 1024 * 1024 * 1024);
  assert.equal(low.canStage, true);
  assert.equal(low.isWarning, true);
  assert.equal(low.isCritical, false);
  assert.equal(low.recommendedMode, 'bypass');

  // Scenario 3: Critical space (< 3 GB free or file exceeds space)
  const critical = checkAPFSFreeSpace(5 * 1024 * 1024 * 1024, 2 * 1024 * 1024 * 1024);
  assert.equal(critical.canStage, false);
  assert.equal(critical.isCritical, true);
  assert.equal(critical.recommendedMode, 'bypass');
  assert.ok(critical.shortfallBytes > 0);
});

test('offline mode pauses uploads without losing progress and resumes on reconnect', () => {
  const uploadingItem: SpoolItem = {
    id: 's-active',
    filename: 'raw_footage.braw',
    relativePath: 'Vault/raw_footage.braw',
    sizeBytes: 100 * 1024 * 1024,
    status: 'uploading',
    writeBackRemainingSec: 0,
    uploadProgress: 45.5,
    uploadSpeedMBps: 35.0,
    createdAt: Date.now(),
    sourceMode: 'move',
  };

  // When offline, ticking freezes upload progress
  const paused = tickSpoolItem(uploadingItem, 35.0, 1, false);
  assert.equal(paused.status, 'paused_offline');
  assert.equal(paused.uploadProgress, 45.5);
  assert.equal(paused.uploadSpeedMBps, 0);

  // When back online, resuming continues progress
  const resumed = tickSpoolItem(paused, 20.0, 1, true);
  assert.equal(resumed.status, 'uploading');
  assert.ok(resumed.uploadProgress > 45.5);

  // Paused offline items are dirty and must block termination
  assert.equal(shouldBlockTermination([paused]), true);
  assert.equal(getDirtyFileCount([paused]).dirtyCount, 1);
});
