import React, { useState, useEffect } from 'react';
import {
  HardDrive,
  FolderOpen,
  Code2,
  Upload,
  Layers,
  Sparkles,
  ShieldCheck,
  RotateCcw,
  CheckCircle2,
  AppWindow,
} from 'lucide-react';
import {
  CloudNode,
  SpoolItem,
  Telemetry,
  ConnectedCloud,
  StorageMode,
  CloudPreset,
} from './types/zerodrive';
import {
  INITIAL_CLOUD_NODES,
  INITIAL_SPOOL_ITEMS,
  INITIAL_CONNECTED_CLOUDS,
} from './core/simulatorEngine';
import {
  searchCloudNodes,
  getDirtyFileCount,
  shouldBlockTermination,
  formatBytes,
  applyBandwidthCap,
  tickSpoolItem,
  handleNetworkStatusChange,
  checkAPFSFreeSpace,
} from './core/pureLogic';
import { MacMenuBar } from './components/macOS/MacMenuBar';
import { MenuBarPopover } from './components/macOS/MenuBarPopover';
import { StudioWindow } from './components/macOS/StudioWindow';
import { FinderPreviewModal } from './components/macOS/FinderPreviewModal';
import { QuitGuardModal } from './components/macOS/QuitGuardModal';
import { CodebaseExportModal } from './components/macOS/CodebaseExportModal';

export default function App() {
  const [isMounted, setIsMounted] = useState<boolean>(true);
  const [activeViewMode, setActiveViewMode] = useState<'studio' | 'menubar' | 'finder'>('studio');
  const [codebaseOpen, setCodebaseOpen] = useState<boolean>(false);
  const [finderPreviewNode, setFinderPreviewNode] = useState<CloudNode | null>(INITIAL_CLOUD_NODES[0]);
  const [quitGuardOpen, setQuitGuardOpen] = useState<boolean>(false);
  const [quitActionType, setQuitActionType] = useState<'quit' | 'unmount'>('unmount');

  const [storageMode, setStorageMode] = useState<StorageMode>('dfy');
  const [cloudPreset, setCloudPreset] = useState<CloudPreset>('cloudflare_r2');
  const [cloudNodes, setCloudNodes] = useState<CloudNode[]>(INITIAL_CLOUD_NODES);
  const [spoolItems, setSpoolItems] = useState<SpoolItem[]>(INITIAL_SPOOL_ITEMS);
  const [connectedClouds, setConnectedClouds] = useState<ConnectedCloud[]>(INITIAL_CONNECTED_CLOUDS);
  const [freeDiskBytes, setFreeDiskBytes] = useState<number>(120 * 1024 * 1024 * 1024); // 120 GB default

  const [telemetry, setTelemetry] = useState<Telemetry>({
    uploadSpeedMBps: 34.5,
    downloadSpeedMBps: 0.0,
    activeUploads: 1,
    activeQueued: 1,
    spoolUsedBytes: 3_180_000_000,
    spoolMaxBytes: 50 * 1024 * 1024 * 1024,
    totalCloudBytes: 4_100_000_000_000, // 4.1 TB
    totalSpaceSavedBytes: 3_920_000_000_000, // 3.92 TB
    ramIndexCount: 14_280,
    isOnline: true,
    streamGuardActive: false,
    mountStatus: 'mounted',
    lastRefreshed: Date.now(),
    nfsPid: 48291,
    ttfbMs: 380,
  });

  const { dirtyCount, dirtyBytes } = getDirtyFileCount(spoolItems);

  const handleToggleOnline = () => {
    setTelemetry((prev) => {
      const nextOnline = !prev.isOnline;
      setSpoolItems((items) => handleNetworkStatusChange(items, nextOnline));
      return {
        ...prev,
        isOnline: nextOnline,
        uploadSpeedMBps: nextOnline ? 34.5 : 0,
      };
    });
  };

  // Background engine tick: 1s interval to simulate write-back timers and uploads
  useEffect(() => {
    if (!isMounted) return;

    const interval = setInterval(() => {
      setSpoolItems((prevItems) => {
        const rawSpeed = telemetry.streamGuardActive ? 2.8 : 36.0;
        const effectiveSpeed = applyBandwidthCap(rawSpeed, telemetry.streamGuardActive);

        return prevItems.map((item) => tickSpoolItem(item, effectiveSpeed, 1, telemetry.isOnline));
      });

      setTelemetry((prev) => {
        const uploadingCount = spoolItems.filter((i) => i.status === 'uploading').length;
        const currentSpeed = !telemetry.isOnline
          ? 0
          : uploadingCount > 0
          ? applyBandwidthCap(telemetry.streamGuardActive ? 2.8 : 34.5 + (Math.random() * 4 - 2), telemetry.streamGuardActive)
          : 0;

        const currentSpoolBytes = spoolItems
          .filter((i) => i.status === 'staging' || i.status === 'uploading' || i.status === 'paused_offline')
          .reduce((sum, item) => sum + item.sizeBytes, 0);

        return {
          ...prev,
          uploadSpeedMBps: currentSpeed,
          activeUploads: uploadingCount,
          activeQueued: spoolItems.filter((i) => i.status === 'staging').length,
          spoolUsedBytes: currentSpoolBytes,
        };
      });
    }, 1000);

    return () => clearInterval(interval);
  }, [isMounted, telemetry.streamGuardActive, telemetry.isOnline, spoolItems]);

  // Dropzone file offloader
  const handleDropFiles = (
    droppedFiles: { name: string; size: number }[],
    mode: 'move' | 'copy' | 'bypass'
  ) => {
    const newItems: SpoolItem[] = droppedFiles.map((file) => ({
      id: `spool_${Date.now()}_${Math.random().toString(36).substring(2, 7)}`,
      filename: file.name,
      relativePath: `Vault/${file.name}`,
      sizeBytes: file.size,
      status: mode === 'bypass' ? 'uploading' : 'staging',
      writeBackRemainingSec: mode === 'bypass' ? 0 : 15,
      uploadProgress: 0,
      uploadSpeedMBps: telemetry.streamGuardActive ? 3.0 : 35.0,
      createdAt: Date.now(),
      sourceMode: mode,
    }));

    setSpoolItems((prev) => [...newItems, ...prev]);

    if (mode === 'move' || mode === 'bypass') {
      const addedSpace = droppedFiles.reduce((acc, f) => acc + f.size, 0);
      setTelemetry((prev) => ({
        ...prev,
        totalSpaceSavedBytes: prev.totalSpaceSavedBytes + addedSpace,
      }));
    }
  };

  const handleSyncNow = (item: SpoolItem) => {
    setSpoolItems((prev) =>
      prev.map((i) =>
        i.id === item.id
          ? {
              ...i,
              status: 'uploading',
              writeBackRemainingSec: 0,
              uploadProgress: i.uploadProgress || 1,
              uploadSpeedMBps: telemetry.streamGuardActive ? 3.0 : 35.0,
            }
          : i
      )
    );
  };

  const handleTagRetake = (item: SpoolItem) => {
    setSpoolItems((prev) =>
      prev.map((i) =>
        i.id === item.id
          ? {
              ...i,
              status: 'retake',
              relativePath: `_Retakes/${item.filename}`,
            }
          : i
      )
    );
  };

  const handlePurge = (item: SpoolItem) => {
    setSpoolItems((prev) => prev.filter((i) => i.id !== item.id));
  };

  const handleToggleStreamGuard = () => {
    setTelemetry((prev) => ({
      ...prev,
      streamGuardActive: !prev.streamGuardActive,
    }));
  };

  const handleRevealInFinder = (node: CloudNode) => {
    setFinderPreviewNode(node);
    setActiveViewMode('finder');
  };

  const handleToggleCloudConnection = (cloudId: string) => {
    setConnectedClouds((prev) =>
      prev.map((c) =>
        c.id === cloudId
          ? {
              ...c,
              connected: !c.connected,
              accountEmail: !c.connected ? 'alex.user@work.com' : '',
            }
          : c
      )
    );
  };

  const handleHealMount = (mode: 'stale' | 'buffer' | 'refresh') => {
    if (mode === 'refresh') {
      setTelemetry((prev) => ({ ...prev, lastRefreshed: Date.now() }));
    }
  };

  const handleRequestUnmount = () => {
    if (shouldBlockTermination(spoolItems)) {
      setQuitActionType('unmount');
      setQuitGuardOpen(true);
    } else {
      setIsMounted(false);
      setTelemetry((prev) => ({ ...prev, mountStatus: 'unmounted' }));
    }
  };

  const handleConfirmWaitAndFinish = () => {
    setSpoolItems((prev) =>
      prev.map((i) => ({
        ...i,
        status: 'synced',
        uploadProgress: 100,
        writeBackRemainingSec: 0,
      }))
    );
    setQuitGuardOpen(false);
    setIsMounted(false);
    setTelemetry((prev) => ({ ...prev, mountStatus: 'unmounted' }));
  };

  const handleConfirmKeepInSpool = () => {
    setQuitGuardOpen(false);
    setIsMounted(false);
    setTelemetry((prev) => ({ ...prev, mountStatus: 'unmounted' }));
  };

  return (
    <div className="w-screen h-screen flex flex-col bg-[#0f0f14] overflow-hidden select-none font-sans">
      {/* Top Native macOS Sequoia / Sonoma Menu Bar */}
      <MacMenuBar
        isMounted={isMounted}
        dirtyCount={dirtyCount}
        isOnline={telemetry.isOnline}
        activeViewMode={activeViewMode}
        onChangeViewMode={(mode) => setActiveViewMode(mode)}
        onToggleOnline={handleToggleOnline}
        onOpenCodebase={() => setCodebaseOpen(true)}
      />

      {/* Main Native macOS Application Canvas */}
      <main className="flex-1 p-4 md:p-6 flex items-center justify-center overflow-hidden relative">
        {/* View Mode 1: Main ZeroDrive Studio Window (Default) */}
        {activeViewMode === 'studio' && (
          <div className="w-full h-full max-w-6xl max-h-[820px] animate-in fade-in zoom-in-[0.99] duration-150">
            <StudioWindow
              telemetry={telemetry}
              spoolItems={spoolItems}
              cloudNodes={cloudNodes}
              connectedClouds={connectedClouds}
              storageMode={storageMode}
              cloudPreset={cloudPreset}
              freeDiskBytes={freeDiskBytes}
              onChangeFreeDiskBytes={(bytes) => setFreeDiskBytes(bytes)}
              onToggleOnline={handleToggleOnline}
              onDropFiles={handleDropFiles}
              onSyncNow={handleSyncNow}
              onTagRetake={handleTagRetake}
              onPurge={handlePurge}
              onRevealInFinder={handleRevealInFinder}
              onToggleStreamGuard={handleToggleStreamGuard}
              onToggleCloudConnection={handleToggleCloudConnection}
              onHealMount={handleHealMount}
              onRequestUnmount={handleRequestUnmount}
              onClose={() => setActiveViewMode('menubar')}
            />
          </div>
        )}

        {/* View Mode 2: Menu Bar Popover Extra Daemon */}
        {activeViewMode === 'menubar' && (
          <div className="w-full flex flex-col items-center justify-center p-4 animate-in fade-in zoom-in-[0.99] duration-150">
            <div className="text-center mb-4 space-y-1">
              <span className="text-[11px] font-semibold uppercase tracking-wider text-white/40">
                Menu Bar Mode Active
              </span>
              <p className="text-xs text-white/60">
                The main studio window is closed. ZeroDrive keeps running seamlessly in the background menu bar.
              </p>
            </div>

            <MenuBarPopover
              telemetry={telemetry}
              spoolItems={spoolItems}
              cloudNodes={cloudNodes}
              onToggleStreamGuard={handleToggleStreamGuard}
              onSyncNow={handleSyncNow}
              onPurge={handlePurge}
              onRevealInFinder={handleRevealInFinder}
              onOpenStudio={() => setActiveViewMode('studio')}
              onRequestUnmount={handleRequestUnmount}
            />
          </div>
        )}

        {/* View Mode 3: Real macOS Finder Volume Preview (`~/ZeroDrive`) */}
        {activeViewMode === 'finder' && (
          <div className="w-full h-full max-w-6xl max-h-[820px] animate-in fade-in zoom-in-[0.99] duration-150">
            <FinderPreviewModal
              selectedNode={finderPreviewNode}
              allNodes={cloudNodes}
              onClose={() => setActiveViewMode('studio')}
            />
          </div>
        )}
      </main>

      {/* Quit / Unmount Guard NSAlert Modal */}
      <QuitGuardModal
        isOpen={quitGuardOpen}
        actionType={quitActionType}
        spoolItems={spoolItems}
        onConfirmWaitAndFinish={handleConfirmWaitAndFinish}
        onConfirmKeepInSpool={handleConfirmKeepInSpool}
        onCancel={() => setQuitGuardOpen(false)}
      />

      {/* Full Swift Codebase & DMG Packaging Hub */}
      <CodebaseExportModal
        isOpen={codebaseOpen}
        onClose={() => setCodebaseOpen(false)}
      />
    </div>
  );
}
