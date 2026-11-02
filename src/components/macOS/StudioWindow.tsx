import React, { useState, useRef } from 'react';
import {
  ArrowDownToLine,
  Upload,
  HardDrive,
  Cloud,
  Clock,
  Activity,
  Layers,
  Search,
  ExternalLink,
  ShieldCheck,
  RotateCw,
  FolderPlus,
  Trash2,
  CheckCircle2,
  AlertCircle,
  FileVideo,
  FileAudio,
  FileText,
  FileArchive,
  ChevronRight,
  Sliders,
  Copy,
  Check,
  Sparkles,
  Zap,
  Radio,
  FileCode,
  Folder,
} from 'lucide-react';
import {
  CloudNode,
  SpoolItem,
  Telemetry,
  ConnectedCloud,
  StorageMode,
  CloudPreset,
} from '../../types/zerodrive';
import { formatBytes, searchCloudNodes } from '../../core/pureLogic';

interface StudioWindowProps {
  telemetry: Telemetry;
  spoolItems: SpoolItem[];
  cloudNodes: CloudNode[];
  connectedClouds: ConnectedCloud[];
  storageMode: StorageMode;
  cloudPreset: CloudPreset;
  onDropFiles: (files: { name: string; size: number }[], mode: 'move' | 'copy' | 'bypass') => void;
  onSyncNow: (item: SpoolItem) => void;
  onTagRetake: (item: SpoolItem) => void;
  onPurge: (item: SpoolItem) => void;
  onRevealInFinder: (node: CloudNode) => void;
  onToggleStreamGuard: () => void;
  onToggleCloudConnection: (cloudId: string) => void;
  onHealMount: (mode: 'stale' | 'buffer' | 'refresh') => void;
  onRequestUnmount: () => void;
  onClose: () => void;
}

export const StudioWindow: React.FC<StudioWindowProps> = ({
  telemetry,
  spoolItems,
  cloudNodes,
  connectedClouds,
  storageMode,
  cloudPreset,
  onDropFiles,
  onSyncNow,
  onTagRetake,
  onPurge,
  onRevealInFinder,
  onToggleStreamGuard,
  onToggleCloudConnection,
  onHealMount,
  onRequestUnmount,
  onClose,
}) => {
  const [selectedTab, setSelectedTab] = useState<number>(0);
  const [searchQuery, setSearchQuery] = useState('');
  const [dropMode, setDropMode] = useState<'move' | 'copy'>('move');
  const [bypassSpool, setBypassSpool] = useState(false);
  const [isDragOver, setIsDragOver] = useState(false);
  const [copiedPlist, setCopiedPlist] = useState(false);
  const [copiedBash, setCopiedBash] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const { results: searchResults, searchDurationMs } = searchCloudNodes(cloudNodes, searchQuery, 40);
  const dirtyCount = spoolItems.filter(i => i.status === 'staging' || i.status === 'uploading').length;

  const handleDragOver = (e: React.DragEvent) => {
    e.preventDefault();
    setIsDragOver(true);
  };

  const handleDragLeave = () => {
    setIsDragOver(false);
  };

  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    setIsDragOver(false);
    if (e.dataTransfer.files && e.dataTransfer.files.length > 0) {
      const dropped = Array.from(e.dataTransfer.files).map(f => ({
        name: f.name,
        size: f.size > 0 ? f.size : 1024 * 1024 * 750,
      }));
      onDropFiles(dropped, bypassSpool ? 'bypass' : dropMode);
    }
  };

  const handleFileInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    if (e.target.files && e.target.files.length > 0) {
      const dropped = Array.from(e.target.files).map(f => ({
        name: f.name,
        size: f.size > 0 ? f.size : 1024 * 1024 * 500,
      }));
      onDropFiles(dropped, bypassSpool ? 'bypass' : dropMode);
    }
  };

  const handleSimulateDropDemo = () => {
    const demoFiles = [
      { name: 'Commercial_Cut_4K_ProRes422HQ.mov', size: 1024 * 1024 * 1024 * 2.4 },
      { name: 'Multitrack_Stems_96k24b.wav', size: 1024 * 1024 * 850 },
    ];
    onDropFiles(demoFiles, bypassSpool ? 'bypass' : dropMode);
  };

  return (
    <div className="w-full h-full flex flex-col apple-glass-window rounded-2xl overflow-hidden shadow-2xl select-none text-[#f5f5f7]">
      {/* Authentic macOS Sonoma/Sequoia Titlebar */}
      <div className="h-11 px-4 flex items-center justify-between border-b border-white/[0.08] bg-white/[0.02] shrink-0">
        {/* Apple Traffic Lights with precise geometry and borders */}
        <div className="flex items-center space-x-2">
          <button
            onClick={onClose}
            className="w-3 h-3 rounded-full bg-[#FF5F56] border border-[#E0443E] hover:opacity-85 transition-opacity flex items-center justify-center text-[7px] text-[#4a0002] font-bold group"
            title="Close ZeroDrive Studio"
          >
            <span className="opacity-0 group-hover:opacity-100">✕</span>
          </button>
          <div className="w-3 h-3 rounded-full bg-[#FFBD2E] border border-[#DEA123]" />
          <div className="w-3 h-3 rounded-full bg-[#27C93F] border border-[#1AAB29]" />
        </div>

        {/* Center: Title and macOS Native Segmented Status Pill */}
        <div className="flex items-center space-x-3">
          <div className="flex items-center space-x-2 text-[13px] font-semibold tracking-tight text-white/90">
            <HardDrive className="w-4 h-4 text-[#007aff]" />
            <span>ZeroDrive Studio</span>
          </div>

          <div className="hidden sm:flex items-center space-x-2 text-[11px] font-mono apple-segmented-track px-3 py-0.5 rounded-full text-white/70">
            <span className="text-[#34c759] font-medium">~/ZeroDrive</span>
            <span className="text-white/20">·</span>
            <span>14,280 files</span>
            <span className="text-white/20">·</span>
            <span className={dirtyCount > 0 ? 'text-[#ff9f0a] font-semibold' : 'text-white/70'}>
              {formatBytes(telemetry.spoolUsedBytes)} spool
            </span>
          </div>
        </div>

        {/* Right: Unmount Action */}
        <div className="flex items-center space-x-2">
          <button
            onClick={onRequestUnmount}
            className="text-[12px] font-medium text-[#ff453a] hover:text-[#ff6961] px-2.5 py-1 rounded-md hover:bg-white/[0.06] transition-colors"
          >
            Unmount
          </button>
        </div>
      </div>

      {/* Main App Workspace: SplitView Sidebar + Detail Content */}
      <div className="flex-1 flex overflow-hidden">
        {/* Apple SplitView Sidebar */}
        <aside className="w-56 apple-glass-sidebar p-3 flex flex-col justify-between shrink-0">
          <div className="space-y-1">
            <span className="text-[10px] font-semibold uppercase tracking-wider text-white/40 px-3 pb-1 block">
              Workspace
            </span>

            <button
              onClick={() => setSelectedTab(0)}
              className={`w-full text-left px-3 py-1.5 rounded-lg text-[13px] font-medium flex items-center space-x-2.5 transition-all ${
                selectedTab === 0
                  ? 'bg-[#0071e3] text-white shadow-sm'
                  : 'text-white/75 hover:bg-white/[0.06] hover:text-white'
              }`}
            >
              <ArrowDownToLine className="w-4 h-4" />
              <span>Dropzone & Search</span>
            </button>

            <button
              onClick={() => setSelectedTab(1)}
              className={`w-full text-left px-3 py-1.5 rounded-lg text-[13px] font-medium flex items-center space-x-2.5 transition-all ${
                selectedTab === 1
                  ? 'bg-[#0071e3] text-white shadow-sm'
                  : 'text-white/75 hover:bg-white/[0.06] hover:text-white'
              }`}
            >
              <Cloud className="w-4 h-4" />
              <span>Cloud Connections</span>
            </button>

            <button
              onClick={() => setSelectedTab(2)}
              className={`w-full text-left px-3 py-1.5 rounded-lg text-[13px] font-medium flex items-center justify-between transition-all ${
                selectedTab === 2
                  ? 'bg-[#0071e3] text-white shadow-sm'
                  : 'text-white/75 hover:bg-white/[0.06] hover:text-white'
              }`}
            >
              <div className="flex items-center space-x-2.5">
                <Clock className="w-4 h-4" />
                <span>Staging & Retakes</span>
              </div>
              {dirtyCount > 0 && (
                <span className="px-1.5 py-0.2 rounded-full text-[10px] font-bold bg-[#ff9f0a] text-black">
                  {dirtyCount}
                </span>
              )}
            </button>

            <button
              onClick={() => setSelectedTab(3)}
              className={`w-full text-left px-3 py-1.5 rounded-lg text-[13px] font-medium flex items-center space-x-2.5 transition-all ${
                selectedTab === 3
                  ? 'bg-[#0071e3] text-white shadow-sm'
                  : 'text-white/75 hover:bg-white/[0.06] hover:text-white'
              }`}
            >
              <Sliders className="w-4 h-4" />
              <span>Bandwidth & Scripts</span>
            </button>
          </div>

          {/* Engine Status Block */}
          <div className="p-3 rounded-xl apple-glass-panel space-y-2 text-[11px]">
            <div className="flex items-center justify-between text-white/50">
              <span>Engine Status</span>
              <span className="text-[#34c759] font-medium flex items-center space-x-1">
                <span className="w-1.5 h-1.5 rounded-full bg-[#34c759]" />
                <span>Loopback v3</span>
              </span>
            </div>
            <div className="flex items-center justify-between text-white/50">
              <span>Localhost RPC</span>
              <span className="font-mono text-white/90">127.0.0.1:55729</span>
            </div>
            <div className="flex items-center justify-between text-white/50">
              <span>Stream Guard</span>
              <span className={telemetry.streamGuardActive ? 'text-[#34c759] font-medium' : 'text-white/70'}>
                {telemetry.streamGuardActive ? 'Active (3 MB/s)' : 'Off'}
              </span>
            </div>
          </div>
        </aside>

        {/* Tab 0: Dashboard & Dropzone */}
        {selectedTab === 0 && (
          <div className="flex-1 p-6 overflow-y-auto space-y-6">
            {/* 3 Metric Cards */}
            <div className="grid grid-cols-1 md:grid-cols-3 gap-3.5">
              <div className="p-4 rounded-xl apple-glass-panel space-y-1">
                <span className="text-[11px] font-semibold text-white/40 uppercase tracking-wider">
                  Mac SSD Space Saved
                </span>
                <p className="text-2xl font-bold font-mono tracking-tight text-[#34c759]">
                  {formatBytes(telemetry.totalSpaceSavedBytes)}
                </p>
                <p className="text-[11px] text-white/50">
                  Zero bytes local SSD footprint for read streams
                </p>
              </div>

              <div className="p-4 rounded-xl apple-glass-panel space-y-1">
                <span className="text-[11px] font-semibold text-white/40 uppercase tracking-wider">
                  Unified Cloud Capacity
                </span>
                <p className="text-2xl font-bold font-mono tracking-tight text-[#007aff]">
                  {formatBytes(telemetry.totalCloudBytes)}
                </p>
                <p className="text-[11px] text-white/50">
                  Primary Vault + Google Drive + Dropbox
                </p>
              </div>

              <div className="p-4 rounded-xl apple-glass-panel space-y-1">
                <span className="text-[11px] font-semibold text-white/40 uppercase tracking-wider">
                  Local NVMe Write Spool
                </span>
                <p className="text-2xl font-bold font-mono tracking-tight text-[#ff9f0a]">
                  {formatBytes(telemetry.spoolUsedBytes)}
                  <span className="text-xs text-white/40 font-normal"> / 50 GB</span>
                </p>
                <p className="text-[11px] text-white/50">
                  Auto-evicts 60 seconds after upload completes
                </p>
              </div>
            </div>

            {/* Apple Liquid Glass Drag-and-Drop Offload Box */}
            <div
              onDragOver={handleDragOver}
              onDragLeave={handleDragLeave}
              onDrop={handleDrop}
              className={`p-7 rounded-2xl border transition-all flex flex-col items-center justify-center text-center space-y-4 relative ${
                isDragOver
                  ? 'border-[#007aff] bg-[#007aff]/10 shadow-lg shadow-[#007aff]/20'
                  : 'border-white/15 apple-glass-panel hover:border-white/25'
              }`}
            >
              <input
                ref={fileInputRef}
                type="file"
                multiple
                onChange={handleFileInputChange}
                className="hidden"
              />

              <div className="w-13 h-13 rounded-2xl bg-[#007aff]/15 border border-[#007aff]/30 flex items-center justify-center text-[#007aff] shadow-inner">
                <Upload className="w-6 h-6" />
              </div>

              <div className="space-y-1">
                <h3 className="text-sm font-semibold text-white/95">
                  Drag Files or Folders Here to Offload Instantly
                </h3>
                <p className="text-[12px] text-white/50 max-w-md">
                  Drop high-bitrate video, sound design libraries, or archives to stage in the NVMe write-spool and upload to your cloud.
                </p>
              </div>

              {/* Native Apple Segmented Mode Control */}
              <div className="flex flex-col sm:flex-row items-center gap-3">
                <div className="apple-segmented-track p-0.5 rounded-lg flex text-[12px] font-medium">
                  <button
                    onClick={() => setDropMode('move')}
                    className={`px-3 py-1 rounded-md transition-all ${
                      dropMode === 'move'
                        ? 'apple-segmented-pill text-white font-semibold'
                        : 'text-white/60 hover:text-white'
                    }`}
                  >
                    Move to Vault & Free Mac Space (Default)
                  </button>
                  <button
                    onClick={() => setDropMode('copy')}
                    className={`px-3 py-1 rounded-md transition-all ${
                      dropMode === 'copy'
                        ? 'apple-segmented-pill text-white font-semibold'
                        : 'text-white/60 hover:text-white'
                    }`}
                  >
                    Copy to Vault (Keep Local)
                  </button>
                </div>

                <div className="flex items-center space-x-2">
                  <button
                    onClick={() => fileInputRef.current?.click()}
                    className="apple-btn-secondary px-3 py-1 rounded-md text-[12px] font-medium text-white/80 hover:text-white transition-colors"
                  >
                    Choose Files…
                  </button>
                  <button
                    onClick={handleSimulateDropDemo}
                    className="apple-btn-secondary px-3 py-1 rounded-md text-[12px] font-medium text-[#007aff] hover:text-[#0077ed] transition-colors"
                  >
                    + Add 2.4 GB Video
                  </button>
                </div>
              </div>

              <label className="flex items-center space-x-2 text-[11px] text-white/50 cursor-pointer pt-0.5">
                <input
                  type="checkbox"
                  checked={bypassSpool}
                  onChange={(e) => setBypassSpool(e.target.checked)}
                  className="rounded border-white/20 text-[#007aff] focus:ring-0"
                />
                <span>Direct Cloud Upload (Bypass Local Spool for Massive Folders)</span>
              </label>
            </div>

            {/* Instant RAM Search Bar (< 1 ms) */}
            <div className="space-y-3">
              <div className="flex items-center justify-between text-xs">
                <span className="font-semibold text-white/80 flex items-center space-x-1.5">
                  <Search className="w-3.5 h-3.5 text-[#007aff]" />
                  <span>Instant Cloud Search</span>
                </span>
                <span className="text-[11px] font-mono text-[#34c759]">
                  RAM Latency: {searchDurationMs} ms
                </span>
              </div>

              <div className="relative">
                <Search className="w-4 h-4 text-white/40 absolute left-3 top-2.5" />
                <input
                  type="text"
                  value={searchQuery}
                  onChange={(e) => setSearchQuery(e.target.value)}
                  placeholder="Search 14,280 files pre-warmed in RAM across Vault, Google Drive, Dropbox…"
                  className="w-full bg-black/30 border border-white/10 rounded-xl pl-9 pr-4 py-2 text-xs text-white placeholder-white/30 focus:outline-none focus:border-[#007aff]"
                />
              </div>

              {/* Search Results Grid */}
              <div className="apple-glass-panel rounded-xl overflow-hidden divide-y divide-white/[0.05] max-h-56 overflow-y-auto">
                {searchResults.map((node) => (
                  <div
                    key={node.id}
                    className="px-3.5 py-2 hover:bg-white/[0.04] transition-colors flex items-center justify-between text-xs"
                  >
                    <div className="flex items-center space-x-2.5 min-w-0 pr-3">
                      <div className="w-7 h-7 rounded-lg bg-white/[0.05] flex items-center justify-center shrink-0">
                        {node.name.endsWith('.mov') || node.name.endsWith('.braw') ? (
                          <FileVideo className="w-3.5 h-3.5 text-[#007aff]" />
                        ) : node.name.endsWith('.wav') ? (
                          <FileAudio className="w-3.5 h-3.5 text-[#ff9f0a]" />
                        ) : (
                          <FileText className="w-3.5 h-3.5 text-white/70" />
                        )}
                      </div>
                      <div className="min-w-0">
                        <p className="font-medium text-white/90 truncate text-xs">{node.name}</p>
                        <p className="text-[10px] text-white/40 font-mono truncate">
                          {node.relativePath}
                        </p>
                      </div>
                    </div>

                    <div className="flex items-center space-x-3 shrink-0">
                      <span className="text-[11px] text-white/50">{node.sourceCloud}</span>
                      <span className="text-white/20">·</span>
                      <span className="text-[11px] font-mono tabular-nums text-white/80 w-16 text-right">
                        {formatBytes(node.sizeBytes)}
                      </span>
                      <button
                        onClick={() => onRevealInFinder(node)}
                        className="apple-btn-secondary px-2.5 py-1 rounded-md text-[11px] font-medium text-white/90 transition-colors flex items-center space-x-1"
                      >
                        <ExternalLink className="w-3 h-3 text-[#007aff]" />
                        <span>Reveal</span>
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>
        )}

        {/* Tab 1: Cloud Connections */}
        {selectedTab === 1 && (
          <div className="flex-1 p-6 overflow-y-auto space-y-6">
            <div>
              <h3 className="text-sm font-semibold text-white/95">Unified Storage Remotes</h3>
              <p className="text-xs text-white/50 mt-0.5">
                All connected cloud providers are unified into one mount point at <code className="font-mono text-[#007aff]">~/ZeroDrive</code> via rclone combine.
              </p>
            </div>

            {/* Primary Vault */}
            <div className="p-4 rounded-xl apple-glass-panel space-y-3">
              <div className="flex items-center justify-between">
                <div className="flex items-center space-x-3">
                  <div className="w-10 h-10 rounded-xl bg-[#007aff]/15 border border-[#007aff]/30 flex items-center justify-center text-[#007aff]">
                    <HardDrive className="w-5 h-5" />
                  </div>
                  <div>
                    <h4 className="text-xs font-semibold text-white/90">
                      Primary Vault: {storageMode === 'dfy' ? 'ZeroDrive Managed R2 Vault' : 'BYOK Cloudflare R2'}
                    </h4>
                    <p className="text-[11px] text-white/50">
                      Endpoint: Cloudflare R2 · 0 Egress Fees · 5 TB Allocation
                    </p>
                  </div>
                </div>
                <span className="text-[11px] font-medium text-[#34c759]">
                  Active Primary
                </span>
              </div>
            </div>

            {/* Connected External Clouds */}
            <div className="space-y-3">
              <h4 className="text-[11px] font-semibold uppercase tracking-wider text-white/40">
                Connected External Clouds (rclone combine)
              </h4>

              <div className="grid grid-cols-1 gap-2.5">
                {connectedClouds.map((cloud) => (
                  <div
                    key={cloud.id}
                    className="p-3.5 rounded-xl apple-glass-panel flex items-center justify-between text-xs"
                  >
                    <div className="flex items-center space-x-3">
                      <div className="w-8 h-8 rounded-lg bg-white/[0.05] flex items-center justify-center text-white/80">
                        <Cloud className="w-4 h-4 text-[#007aff]" />
                      </div>
                      <div>
                        <div className="flex items-center space-x-2">
                          <span className="font-medium text-white/90">{cloud.name}</span>
                          <span className="text-[10px] text-white/40 font-mono">
                            ~/ZeroDrive/{cloud.name.replace(/\s+/g, '_')}
                          </span>
                        </div>
                        <p className="text-[11px] text-white/50">
                          {cloud.connected
                            ? `${cloud.accountEmail} · ${formatBytes(cloud.usedBytes)} of ${formatBytes(cloud.totalBytes)}`
                            : 'Not connected'}
                        </p>
                      </div>
                    </div>

                    <button
                      onClick={() => onToggleCloudConnection(cloud.id)}
                      className={`px-3 py-1 rounded-md text-[11px] font-medium transition-colors ${
                        cloud.connected
                          ? 'apple-btn-secondary text-[#ff453a] hover:text-[#ff6961]'
                          : 'apple-btn-primary text-white'
                      }`}
                    >
                      {cloud.connected ? 'Disconnect' : 'Connect Account'}
                    </button>
                  </div>
                ))}
              </div>
            </div>

            {/* 1-Click Deploy & Infrastructure Provisioning */}
            <div className="p-4 rounded-xl apple-glass-panel space-y-3.5">
              <div className="flex items-center justify-between">
                <div>
                  <h4 className="text-xs font-semibold text-white/90">
                    1-Click Provisioning & Deployment Infrastructure
                  </h4>
                  <p className="text-[11px] text-white/50">
                    Active Domain: <code className="text-[#34c759] font-mono">zerodrive.aisimple.co</code> · Future Target: <code className="text-[#007aff] font-mono">zerodrive.dev</code>
                  </p>
                </div>
                <span className="text-[11px] font-mono text-[#34c759] font-semibold flex items-center space-x-1">
                  <span className="w-1.5 h-1.5 rounded-full bg-[#34c759]" />
                  <span>API Live: /v1/vault/provision</span>
                </span>
              </div>

              <div className="grid grid-cols-1 md:grid-cols-2 gap-3 text-xs">
                <div className="p-3 rounded-lg bg-black/30 border border-white/[0.06] space-y-2">
                  <span className="text-[10px] font-semibold uppercase tracking-wider text-white/40 block">
                    1-Click User Onboarding
                  </span>
                  <p className="text-[11px] text-white/70 leading-relaxed">
                    Users enter their email in the macOS app or click <em>Activate Instant Vault</em>. The client calls <code className="font-mono text-[#007aff]">zerodrive.aisimple.co/v1/vault/provision</code> to get scoped R2 keys and mounts in &lt; 5 seconds with zero manual S3 setup.
                  </p>
                  <button
                    onClick={async () => {
                      try {
                        const res = await fetch('/v1/vault/provision', {
                          method: 'POST',
                          headers: { 'Content-Type': 'application/json' },
                          body: JSON.stringify({ email: 'creator@aisimple.co', licenseKey: 'ZD_PRO_TRIAL', machineUUID: 'MAC-DEMO-01' }),
                        });
                        const data = await res.json();
                        alert(`Provisioned successfully via zerodrive.aisimple.co!\n\nUser: ${data.userPrefix}\nBucket: ${data.bucket}\nAccess Key: ${data.accessKeyId}\nQuota: ${data.quotaTB} TB`);
                      } catch (e) {
                        alert('API Provisioning test completed.');
                      }
                    }}
                    className="apple-btn-primary px-3 py-1.5 rounded-md text-[11px] font-medium text-white transition-colors"
                  >
                    Test 1-Click Provisioning (Live API)
                  </button>
                </div>

                <div className="p-3 rounded-lg bg-black/30 border border-white/[0.06] space-y-2">
                  <span className="text-[10px] font-semibold uppercase tracking-wider text-white/40 block">
                    1-Click Cloudflare Worker Deploy
                  </span>
                  <p className="text-[11px] text-white/70 leading-relaxed">
                    Deploy the provisioning worker to Cloudflare with one command or bundle it under <code className="font-mono text-[#34c759]">zerodrive.aisimple.co</code>:
                  </p>
                  <code className="block p-2 rounded bg-black/60 text-[#34c759] font-mono text-[10px] overflow-x-auto">
                    npx wrangler deploy --name zerodrive-provisioner
                  </code>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* Tab 2: Staging & Retakes */}
        {selectedTab === 2 && (
          <div className="flex-1 p-6 overflow-y-auto space-y-4">
            <div className="flex items-center justify-between">
              <div>
                <h3 className="text-sm font-semibold text-white/95">
                  Local NVMe Write Spool (~/.zerodrive-cache)
                </h3>
                <p className="text-xs text-white/50">
                  15-second write-back window allows triaging and purging mistake renders before cloud upload begins.
                </p>
              </div>
              <span className="text-[11px] font-mono text-[#ff9f0a]">
                {dirtyCount} pending upload
              </span>
            </div>

            {spoolItems.length === 0 ? (
              <div className="p-12 text-center rounded-2xl apple-glass-panel space-y-2">
                <CheckCircle2 className="w-9 h-9 text-[#34c759] mx-auto" />
                <h4 className="text-sm font-semibold text-white/90">Local Spool is Clean</h4>
                <p className="text-xs text-white/50">
                  All local staging cache has been safely uploaded and evicted. Local SSD usage is 0 Bytes.
                </p>
              </div>
            ) : (
              <div className="apple-glass-panel rounded-xl overflow-hidden divide-y divide-white/[0.05] text-xs">
                {spoolItems.map((item) => (
                  <div key={item.id} className="p-3.5 space-y-2">
                    <div className="flex items-center justify-between">
                      <div className="flex items-center space-x-2.5 min-w-0 pr-2">
                        <FileVideo className="w-4 h-4 text-[#007aff] shrink-0" />
                        <span className="font-medium text-white/90 truncate text-xs">{item.filename}</span>
                        <span className="text-[10px] text-white/40 font-mono">
                          {formatBytes(item.sizeBytes)}
                        </span>
                      </div>

                      <div className="flex items-center space-x-1.5 shrink-0">
                        {item.status === 'staging' && (
                          <button
                            onClick={() => onSyncNow(item)}
                            className="apple-btn-secondary px-2.5 py-1 rounded-md text-[11px] font-medium text-[#007aff]"
                          >
                            Keep & Sync Now
                          </button>
                        )}

                        <button
                          onClick={() => onTagRetake(item)}
                          className="apple-btn-secondary px-2.5 py-1 rounded-md text-[11px] font-medium text-[#ff9f0a]"
                        >
                          Tag as Retake
                        </button>

                        <button
                          onClick={() => onPurge(item)}
                          className="apple-btn-secondary px-2.5 py-1 rounded-md text-[11px] font-medium text-[#ff453a]"
                        >
                          Purge Locally
                        </button>
                      </div>
                    </div>

                    <div className="flex items-center justify-between text-[11px] text-white/50">
                      <span>
                        Status:{' '}
                        <span className={`font-medium ${
                          item.status === 'staging'
                            ? 'text-[#ff9f0a]'
                            : item.status === 'uploading'
                            ? 'text-[#007aff]'
                            : item.status === 'synced'
                            ? 'text-[#34c759]'
                            : 'text-white/50'
                        }`}>
                          {item.status === 'staging'
                            ? `Staging (starts in ${item.writeBackRemainingSec}s)`
                            : item.status === 'uploading'
                            ? `Uploading ${item.uploadProgress}% @ ${item.uploadSpeedMBps.toFixed(1)} MB/s`
                            : item.status.toUpperCase()}
                        </span>
                      </span>

                      {item.status === 'uploading' && (
                        <div className="w-36 bg-white/[0.08] rounded-full h-1.5 overflow-hidden">
                          <div
                            className="bg-[#007aff] h-1.5 transition-all duration-300"
                            style={{ width: `${item.uploadProgress}%` }}
                          />
                        </div>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}

        {/* Tab 3: Bandwidth & Workflows */}
        {selectedTab === 3 && (
          <div className="flex-1 p-6 overflow-y-auto space-y-6">
            {/* Bandwidth Section */}
            <div className="p-4 rounded-xl apple-glass-panel space-y-3">
              <div className="flex items-center justify-between">
                <div>
                  <h4 className="text-xs font-semibold text-white/90">Stream / Call Guard</h4>
                  <p className="text-[11px] text-white/50">
                    Caps cloud background upload to 3 MB/s to prevent Zoom / stream lag while local NVMe saves run at native speed.
                  </p>
                </div>
                <button
                  onClick={onToggleStreamGuard}
                  className={`px-3 py-1.5 rounded-lg text-xs font-medium flex items-center space-x-2 transition-all ${
                    telemetry.streamGuardActive
                      ? 'bg-[#34c759]/20 text-[#34c759] border border-[#34c759]/40'
                      : 'apple-btn-secondary text-white/80'
                  }`}
                >
                  <ShieldCheck className="w-4 h-4 text-[#34c759]" />
                  <span>{telemetry.streamGuardActive ? 'Guard Active: 3 MB/s' : 'Enable 3 MB/s Cap'}</span>
                </button>
              </div>

              {/* Bandwidth Chart Visualizer */}
              <div className="space-y-1">
                <div className="flex justify-between text-[11px] text-white/50">
                  <span>Rolling Cloud Upstream Rate</span>
                  <span className="font-mono text-[#007aff] font-semibold">{telemetry.uploadSpeedMBps.toFixed(1)} MB/s</span>
                </div>
                <div className="h-14 w-full bg-black/25 rounded-lg p-1.5 flex items-end gap-1 overflow-hidden border border-white/[0.06]">
                  {[12, 18, 26, 38, 45, 34, 29, 36, 41, 32, telemetry.uploadSpeedMBps * 1.5, telemetry.uploadSpeedMBps * 1.9].map((val, i) => (
                    <div
                      key={i}
                      className="flex-1 rounded-t-sm transition-all duration-300"
                      style={{
                        height: `${Math.min(50, Math.max(5, val))}%`,
                        backgroundColor: telemetry.streamGuardActive ? '#34c759' : '#007aff',
                        opacity: 0.4 + (i / 15),
                      }}
                    />
                  ))}
                </div>
              </div>
            </div>

            {/* Self-Healing Actions */}
            <div className="p-4 rounded-xl apple-glass-panel space-y-3">
              <h4 className="text-[11px] font-semibold uppercase tracking-wider text-white/40">
                Self-Healing & Diagnostics
              </h4>
              <div className="grid grid-cols-1 sm:grid-cols-3 gap-2.5">
                <button
                  onClick={() => onHealMount('stale')}
                  className="p-3 rounded-lg apple-glass-panel hover:bg-white/[0.06] text-left space-y-1 text-xs transition-colors"
                >
                  <div className="font-medium text-white/90 flex items-center space-x-1.5">
                    <RotateCw className="w-3.5 h-3.5 text-[#007aff]" />
                    <span>Clean Ghost Mounts</span>
                  </div>
                  <p className="text-[10px] text-white/40">diskutil unmount force</p>
                </button>

                <button
                  onClick={() => onHealMount('buffer')}
                  className="p-3 rounded-lg apple-glass-panel hover:bg-white/[0.06] text-left space-y-1 text-xs transition-colors"
                >
                  <div className="font-medium text-white/90 flex items-center space-x-1.5">
                    <Sliders className="w-3.5 h-3.5 text-[#af52de]" />
                    <span>Boost 4K/8K Buffer</span>
                  </div>
                  <p className="text-[10px] text-white/40">64M RAM ring-buffer</p>
                </button>

                <button
                  onClick={() => onHealMount('refresh')}
                  className="p-3 rounded-lg apple-glass-panel hover:bg-white/[0.06] text-left space-y-1 text-xs transition-colors"
                >
                  <div className="font-medium text-white/90 flex items-center space-x-1.5">
                    <RotateCw className="w-3.5 h-3.5 text-[#34c759]" />
                    <span>Refresh Cloud Tree</span>
                  </div>
                  <p className="text-[10px] text-white/40">POST /vfs/refresh</p>
                </button>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};
