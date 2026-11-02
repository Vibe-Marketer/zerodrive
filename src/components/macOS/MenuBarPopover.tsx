import React, { useState } from 'react';
import {
  HardDrive,
  ShieldCheck,
  Search,
  ExternalLink,
  Trash2,
  Play,
  Layers,
  ArrowUpRight,
  Power,
  RotateCw,
} from 'lucide-react';
import { SpoolItem, CloudNode, Telemetry } from '../../types/zerodrive';
import { formatBytes, searchCloudNodes } from '../../core/pureLogic';

interface MenuBarPopoverProps {
  telemetry: Telemetry;
  spoolItems: SpoolItem[];
  cloudNodes: CloudNode[];
  onToggleStreamGuard: () => void;
  onSyncNow: (item: SpoolItem) => void;
  onPurge: (item: SpoolItem) => void;
  onRevealInFinder: (node: CloudNode) => void;
  onOpenStudio: () => void;
  onRequestUnmount: () => void;
}

export const MenuBarPopover: React.FC<MenuBarPopoverProps> = ({
  telemetry,
  spoolItems,
  cloudNodes,
  onToggleStreamGuard,
  onSyncNow,
  onPurge,
  onRevealInFinder,
  onOpenStudio,
  onRequestUnmount,
}) => {
  const [searchQuery, setSearchQuery] = useState('');
  const { results: searchResults, searchDurationMs } = searchCloudNodes(cloudNodes, searchQuery, 4);
  const dirtySpool = spoolItems.filter(i => i.status === 'staging' || i.status === 'uploading');

  return (
    <div className="w-full max-w-sm mx-auto apple-glass-window rounded-2xl p-4 space-y-4 text-[#f5f5f7] select-none shadow-2xl">
      {/* Header */}
      <div className="flex items-center justify-between pb-3 border-b border-white/[0.08]">
        <div className="flex items-center space-x-2.5">
          <div className="w-7 h-7 rounded-lg bg-[#007aff]/15 border border-[#007aff]/30 flex items-center justify-center text-[#007aff]">
            <HardDrive className="w-4 h-4" />
          </div>
          <div>
            <h3 className="text-xs font-semibold text-white/95">ZeroDrive Menu Bar Daemon</h3>
            <p className="text-[11px] text-[#34c759] font-mono">
              {telemetry.mountStatus === 'mounted' ? '~/ZeroDrive · Active' : 'Unmounted'}
            </p>
          </div>
        </div>
        <button
          onClick={onOpenStudio}
          className="text-[12px] text-[#007aff] hover:text-[#0077ed] font-medium flex items-center space-x-1"
        >
          <span>Open Studio</span>
          <ArrowUpRight className="w-3.5 h-3.5" />
        </button>
      </div>

      {/* Offline Indicator Banner */}
      {!telemetry.isOnline && (
        <div className="p-2.5 rounded-xl bg-[#ff9f0a]/15 border border-[#ff9f0a]/30 flex items-center justify-between text-[11px] text-[#ff9f0a]">
          <div className="flex items-center space-x-2">
            <span className="w-2 h-2 rounded-full bg-[#ff9f0a] animate-pulse" />
            <span className="font-semibold">Offline — Local Spool Only</span>
          </div>
          <span className="font-mono text-white/60 text-[10px]">~/.zerodrive-cache</span>
        </div>
      )}

      {/* Cloud Bandwidth & Stream Guard */}
      <div className="space-y-2">
        <div className="flex items-center justify-between">
          <div>
            <span className="text-[10px] font-semibold text-white/40 uppercase tracking-wider block">
              Cloud Transfer Rate
            </span>
            <div className="flex items-baseline space-x-1.5">
              <span className="text-xl font-bold font-mono tracking-tight text-[#007aff]">
                {telemetry.uploadSpeedMBps.toFixed(1)}
              </span>
              <span className="text-[11px] text-white/50 font-mono">MB/s upload</span>
            </div>
          </div>

          <button
            onClick={onToggleStreamGuard}
            className={`px-2.5 py-1 rounded-md text-[11px] font-medium flex items-center space-x-1.5 transition-all ${
              telemetry.streamGuardActive
                ? 'bg-[#34c759]/20 text-[#34c759] border border-[#34c759]/40'
                : 'apple-btn-secondary text-white/80'
            }`}
          >
            <ShieldCheck className="w-3.5 h-3.5 text-[#34c759]" />
            <span>{telemetry.streamGuardActive ? 'Guard: 3 MB/s' : 'Stream Guard'}</span>
          </button>
        </div>

        {/* Speed Chart */}
        <div className="h-10 w-full bg-black/25 rounded-lg border border-white/[0.06] p-1 flex items-end justify-between gap-1 overflow-hidden">
          {[14, 22, 31, 44, 38, telemetry.uploadSpeedMBps * 1.5, telemetry.uploadSpeedMBps * 1.8, telemetry.uploadSpeedMBps * 2.1].map((val, idx) => {
            const height = Math.min(32, Math.max(4, Math.round(val)));
            return (
              <div
                key={idx}
                className="flex-1 rounded-t-sm transition-all duration-300"
                style={{
                  height: `${height}px`,
                  backgroundColor: telemetry.streamGuardActive ? '#34c759' : '#007aff',
                  opacity: 0.4 + (idx / 10),
                }}
              />
            );
          })}
        </div>
      </div>

      {/* Instant RAM Search */}
      <div className="space-y-2 pt-1 border-t border-white/[0.08]">
        <div className="flex items-center justify-between text-[11px] text-white/50">
          <span className="font-semibold uppercase tracking-wider">Instant RAM Search</span>
          <span className="font-mono text-[#34c759]">{searchDurationMs} ms</span>
        </div>
        <div className="relative">
          <Search className="w-3.5 h-3.5 text-white/40 absolute left-2.5 top-2" />
          <input
            type="text"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            placeholder="Type to filter 14,280 files in RAM…"
            className="w-full bg-black/30 border border-white/10 rounded-lg pl-8 pr-3 py-1.5 text-xs text-white placeholder-white/30 focus:outline-none focus:border-[#007aff]"
          />
        </div>

        {searchQuery.trim() && (
          <div className="space-y-1 pt-1 max-h-32 overflow-y-auto">
            {searchResults.length === 0 ? (
              <p className="text-[11px] text-white/40 italic py-1">No matching files in RAM index</p>
            ) : (
              searchResults.map((node) => (
                <div
                  key={node.id}
                  className="flex items-center justify-between p-2 rounded-lg bg-white/[0.03] hover:bg-white/[0.06] text-xs transition-colors"
                >
                  <div className="truncate pr-2">
                    <p className="truncate font-medium text-[11px] text-white/90">{node.name}</p>
                    <span className="text-[10px] text-white/40">{formatBytes(node.sizeBytes)} · {node.sourceCloud}</span>
                  </div>
                  <button
                    onClick={() => onRevealInFinder(node)}
                    className="p-1 hover:bg-white/[0.08] text-[#007aff] rounded"
                    title="Reveal in Finder"
                  >
                    <ExternalLink className="w-3.5 h-3.5" />
                  </button>
                </div>
              ))
            )}
          </div>
        )}
      </div>

      {/* Mini Spool Drawer */}
      <div className="space-y-2 pt-1 border-t border-white/[0.08]">
        <div className="flex items-center justify-between text-[11px]">
          <span className="font-semibold uppercase tracking-wider text-white/40">
            Write Spool (~/.zerodrive-cache)
          </span>
          <span className="font-mono text-[#ff9f0a] font-semibold">
            {dirtySpool.length} unsynced
          </span>
        </div>

        {dirtySpool.length === 0 ? (
          <div className="p-2.5 rounded-lg bg-[#34c759]/10 border border-[#34c759]/20 text-[11px] text-[#34c759] flex items-center space-x-2">
            <span className="w-1.5 h-1.5 bg-[#34c759] rounded-full" />
            <span>Spool clean · 0 Bytes local SSD used</span>
          </div>
        ) : (
          <div className="space-y-1.5">
            {dirtySpool.slice(0, 2).map((item) => (
              <div
                key={item.id}
                className="p-2.5 rounded-lg apple-glass-panel text-[11px] space-y-1.5"
              >
                <div className="flex items-center justify-between">
                  <span className="truncate max-w-[170px] font-medium text-white/90">
                    {item.filename}
                  </span>
                  <span className="font-mono text-[10px] text-white/50">
                    {formatBytes(item.sizeBytes)}
                  </span>
                </div>
                <div className="flex items-center justify-between text-[10px] text-white/50">
                  <span>
                    {item.status === 'staging'
                      ? `Uploads in ${item.writeBackRemainingSec}s`
                      : `Uploading ${item.uploadProgress}%`}
                  </span>
                  <div className="flex items-center space-x-1.5">
                    {item.status === 'staging' && (
                      <button
                        onClick={() => onSyncNow(item)}
                        className="text-[#007aff] hover:underline font-medium"
                      >
                        Sync
                      </button>
                    )}
                    <button
                      onClick={() => onPurge(item)}
                      className="text-[#ff453a] hover:underline font-medium"
                    >
                      Purge
                    </button>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Footer Controls */}
      <div className="pt-2 border-t border-white/[0.08] flex items-center justify-between">
        <button
          onClick={onOpenStudio}
          className="text-[12px] text-white/70 hover:text-white font-medium flex items-center space-x-1.5"
        >
          <Layers className="w-3.5 h-3.5 text-[#007aff]" />
          <span>Studio Window</span>
        </button>

        <button
          onClick={onRequestUnmount}
          className="text-[12px] text-[#ff453a] hover:text-[#ff6961] font-medium flex items-center space-x-1 px-2 py-0.5 rounded hover:bg-white/[0.06]"
        >
          <Power className="w-3.5 h-3.5" />
          <span>Unmount</span>
        </button>
      </div>
    </div>
  );
};
