import React, { useState } from 'react';
import {
  Folder,
  FileVideo,
  FileText,
  FileAudio,
  HardDrive,
  ChevronRight,
  X,
  Play,
  CheckCircle2,
  Share2,
  Clock,
  Sparkles,
} from 'lucide-react';
import { CloudNode } from '../../types/zerodrive';
import { formatBytes } from '../../core/pureLogic';

interface FinderPreviewModalProps {
  selectedNode: CloudNode | null;
  allNodes: CloudNode[];
  onClose: () => void;
}

export const FinderPreviewModal: React.FC<FinderPreviewModalProps> = ({
  selectedNode,
  allNodes,
  onClose,
}) => {
  const [activeItem, setActiveItem] = useState<CloudNode | null>(selectedNode);
  const [streamSimulated, setStreamSimulated] = useState(false);
  const [streamTTFB, setStreamTTFB] = useState<number | null>(null);

  if (!selectedNode && !activeItem) return null;
  const current = activeItem || selectedNode;

  const siblings = allNodes.filter(
    (n) => n.sourceCloud === current?.sourceCloud && !n.isFolder
  );

  const handleSimulateStream = () => {
    setStreamSimulated(true);
    const ttfb = Math.floor(Math.random() * 60) + 330; // 330ms - 390ms
    setStreamTTFB(ttfb);
  };

  return (
    <div className="w-full h-full flex flex-col apple-glass-window rounded-2xl overflow-hidden shadow-2xl text-[#f5f5f7] select-none">
      {/* Finder Window Titlebar */}
      <div className="h-11 px-4 flex items-center justify-between border-b border-white/[0.08] bg-white/[0.02] shrink-0">
        <div className="flex items-center space-x-2">
          <button
            onClick={onClose}
            className="w-3 h-3 rounded-full bg-[#FF5F56] border border-[#E0443E] hover:opacity-85 transition-opacity flex items-center justify-center text-[7px] text-[#4a0002] font-bold group"
          >
            <span className="opacity-0 group-hover:opacity-100">✕</span>
          </button>
          <div className="w-3 h-3 rounded-full bg-[#FFBD2E] border border-[#DEA123]" />
          <div className="w-3 h-3 rounded-full bg-[#27C93F] border border-[#1AAB29]" />
        </div>

        {/* Finder Path Breadcrumbs */}
        <div className="flex items-center space-x-2 text-[12px] font-medium text-white/80">
          <HardDrive className="w-4 h-4 text-[#007aff]" />
          <span>ZeroDrive</span>
          <ChevronRight className="w-3 h-3 text-white/30" />
          <span>{current?.sourceCloud}</span>
          <ChevronRight className="w-3 h-3 text-white/30" />
          <span className="text-white font-semibold">{current?.name}</span>
        </div>

        <button
          onClick={onClose}
          className="text-[12px] font-medium text-white/60 hover:text-white px-2.5 py-1 rounded-md hover:bg-white/[0.06] transition-colors"
        >
          Return to Studio
        </button>
      </div>

      {/* Finder Body: Left Sidebar + File Grid + Right Inspector */}
      <div className="flex-1 flex overflow-hidden">
        {/* Finder Sidebar */}
        <div className="w-48 apple-glass-sidebar p-3 space-y-4 text-xs shrink-0 select-none hidden sm:block">
          <div className="space-y-1">
            <span className="text-[10px] font-semibold uppercase tracking-wider text-white/40 px-2 block">
              Favorites
            </span>
            <div className="space-y-0.5 text-white/70">
              <div className="px-2 py-1 rounded-md hover:bg-white/[0.06] cursor-pointer">
                Applications
              </div>
              <div className="px-2 py-1 rounded-md hover:bg-white/[0.06] cursor-pointer">
                Desktop
              </div>
              <div className="px-2 py-1 rounded-md hover:bg-white/[0.06] cursor-pointer">
                Documents
              </div>
              <div className="px-2 py-1 rounded-md hover:bg-white/[0.06] cursor-pointer">
                Downloads
              </div>
            </div>
          </div>

          <div className="space-y-1">
            <span className="text-[10px] font-semibold uppercase tracking-wider text-white/40 px-2 block">
              Locations
            </span>
            <div className="px-2 py-1.5 rounded-lg bg-[#007aff]/15 text-[#007aff] font-semibold flex items-center space-x-2 border border-[#007aff]/25">
              <HardDrive className="w-3.5 h-3.5 shrink-0" />
              <span className="truncate">ZeroDrive</span>
            </div>
          </div>

          <div className="space-y-1">
            <span className="text-[10px] font-semibold uppercase tracking-wider text-white/40 px-2 block">
              Remotes
            </span>
            <div className="space-y-0.5 pl-1 text-[11px] text-white/70">
              <div className="px-2 py-1 rounded-md hover:bg-white/[0.06] cursor-pointer flex items-center space-x-1.5">
                <Folder className="w-3 h-3 text-[#007aff]" />
                <span>Vault</span>
              </div>
              <div className="px-2 py-1 rounded-md hover:bg-white/[0.06] cursor-pointer flex items-center space-x-1.5">
                <Folder className="w-3 h-3 text-[#34c759]" />
                <span>Google_Drive</span>
              </div>
              <div className="px-2 py-1 rounded-md hover:bg-white/[0.06] cursor-pointer flex items-center space-x-1.5">
                <Folder className="w-3 h-3 text-[#5856d6]" />
                <span>Dropbox</span>
              </div>
              <div className="px-2 py-1 rounded-md hover:bg-white/[0.06] cursor-pointer flex items-center space-x-1.5">
                <Folder className="w-3 h-3 text-[#ff9f0a]" />
                <span>_Retakes</span>
              </div>
            </div>
          </div>
        </div>

        {/* Center File Browser */}
        <div className="flex-1 p-5 overflow-y-auto space-y-4">
          <div className="flex items-center justify-between pb-3 border-b border-white/[0.08]">
            <div className="flex items-center space-x-2 text-xs text-white/50">
              <span className="font-semibold text-white/90">
                ~/ZeroDrive/{current?.sourceCloud}
              </span>
              <span>· {siblings.length} items</span>
            </div>
            <span className="text-[11px] font-mono text-[#34c759] font-medium">
              macOS Kernel NFSv3 · 0 B Local SSD
            </span>
          </div>

          <div className="grid grid-cols-2 lg:grid-cols-3 gap-3">
            {siblings.map((node) => {
              const isSelected = current?.id === node.id;
              return (
                <button
                  key={node.id}
                  onClick={() => {
                    setActiveItem(node);
                    setStreamSimulated(false);
                    setStreamTTFB(null);
                  }}
                  className={`p-3.5 rounded-xl text-left flex flex-col justify-between transition-all ${
                    isSelected
                      ? 'bg-[#007aff]/20 border border-[#007aff] text-white shadow-md'
                      : 'apple-glass-panel hover:bg-white/[0.06] text-white/80'
                  }`}
                >
                  <div className="flex items-start justify-between mb-3">
                    <div className="w-8 h-8 rounded-lg bg-white/[0.06] flex items-center justify-center">
                      {node.name.endsWith('.mov') || node.name.endsWith('.braw') ? (
                        <FileVideo className="w-4 h-4 text-[#007aff]" />
                      ) : node.name.endsWith('.wav') ? (
                        <FileAudio className="w-4 h-4 text-[#ff9f0a]" />
                      ) : (
                        <FileText className="w-4 h-4 text-white/70" />
                      )}
                    </div>
                    {isSelected && (
                      <CheckCircle2 className="w-3.5 h-3.5 text-[#007aff]" />
                    )}
                  </div>
                  <div className="space-y-0.5">
                    <p className="text-xs font-semibold truncate leading-tight">{node.name}</p>
                    <p className="text-[10px] text-white/40 font-mono">
                      {formatBytes(node.sizeBytes)}
                    </p>
                  </div>
                </button>
              );
            })}
          </div>
        </div>

        {/* Right Inspector & Stream Benchmark */}
        {current && (
          <aside className="w-72 apple-glass-sidebar p-5 flex flex-col justify-between text-xs shrink-0 select-none overflow-y-auto">
            <div className="space-y-5">
              <div className="text-center pt-2">
                <div className="w-16 h-16 rounded-2xl bg-white/[0.06] border border-white/[0.1] mx-auto flex items-center justify-center text-[#007aff] mb-2.5">
                  <FileVideo className="w-8 h-8" />
                </div>
                <h4 className="font-semibold text-white/95 text-xs truncate px-2">{current.name}</h4>
                <p className="text-[11px] text-white/40 font-mono mt-0.5">
                  {formatBytes(current.sizeBytes)}
                </p>
              </div>

              <div className="space-y-2.5 pt-2 border-t border-white/[0.08] text-[11px]">
                <div className="flex justify-between text-white/50">
                  <span>Kind</span>
                  <span className="text-white/90">ZeroDrive Virtual File</span>
                </div>
                <div className="flex justify-between text-white/50">
                  <span>Remote</span>
                  <span className="text-white/90 font-medium">{current.sourceCloud}</span>
                </div>
                <div className="flex justify-between text-white/50">
                  <span>VFS Mode</span>
                  <span className="text-[#007aff] font-mono font-medium">writes (0 B read SSD)</span>
                </div>
                <div className="flex justify-between text-white/50">
                  <span>Spotlight</span>
                  <span className="text-[#34c759] font-mono">Blocked (.metadata_never_index)</span>
                </div>
              </div>

              {/* 0-Byte Stream Tester */}
              <div className="p-3.5 rounded-xl apple-glass-panel space-y-2.5">
                <span className="text-[10px] font-semibold uppercase tracking-wider text-white/40 flex items-center space-x-1">
                  <Sparkles className="w-3 h-3 text-[#007aff]" />
                  <span>0-Byte RAM Stream Test</span>
                </span>

                <button
                  onClick={handleSimulateStream}
                  className="w-full py-1.5 px-3 rounded-lg apple-btn-primary text-white font-medium text-xs transition-colors flex items-center justify-center space-x-1.5"
                >
                  <Play className="w-3 h-3 fill-current" />
                  <span>Test QuickLook Stream</span>
                </button>

                {streamSimulated && streamTTFB && (
                  <div className="p-2.5 rounded-lg bg-black/40 border border-white/[0.08] text-[11px] space-y-1">
                    <div className="flex justify-between text-[#34c759] font-semibold">
                      <span>Cold-Read Latency (TTFB):</span>
                      <span className="font-mono">{streamTTFB} ms</span>
                    </div>
                    <div className="flex justify-between text-white/50">
                      <span>Local SSD Footprint:</span>
                      <span className="font-mono text-[#34c759]">0 KB added</span>
                    </div>
                    <div className="flex justify-between text-white/50">
                      <span>RAM Ring-Buffer:</span>
                      <span className="font-mono text-white/90">32 MB active</span>
                    </div>
                  </div>
                )}
              </div>
            </div>

            <div className="pt-3 border-t border-white/[0.08]">
              <button
                onClick={onClose}
                className="w-full py-1.5 rounded-lg apple-btn-secondary text-white/90 text-xs font-medium transition-colors"
              >
                Close Inspector
              </button>
            </div>
          </aside>
        )}
      </div>
    </div>
  );
};
