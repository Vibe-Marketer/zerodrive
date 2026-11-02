import {
  HardDrive,
  Wifi,
  WifiOff,
  Battery,
  Code2,
  FolderOpen,
  AppWindow,
  Sliders,
  AlertTriangle,
} from 'lucide-react';

interface MacMenuBarProps {
  isMounted: boolean;
  dirtyCount: number;
  isOnline: boolean;
  activeViewMode: 'studio' | 'menubar' | 'finder';
  onChangeViewMode: (mode: 'studio' | 'menubar' | 'finder') => void;
  onToggleOnline: () => void;
  onOpenCodebase: () => void;
}

export const MacMenuBar: React.FC<MacMenuBarProps> = ({
  isMounted,
  dirtyCount,
  isOnline,
  activeViewMode,
  onChangeViewMode,
  onToggleOnline,
  onOpenCodebase,
}) => {
  return (
    <header className="h-8 w-full bg-[#1e1e24]/85 backdrop-blur-2xl border-b border-white/[0.08] text-white flex items-center justify-between px-3 text-[12px] select-none z-50 shrink-0">
      {/* Left Apple App Menu */}
      <div className="flex items-center space-x-3.5">
        <span className="font-semibold text-white/90 text-sm cursor-default hover:text-white transition-colors">
          
        </span>
        <span className="font-semibold text-white text-[13px] tracking-tight">
          ZeroDrive
        </span>

        {/* View Presence Mode Switcher (Studio Window vs Menu Bar Popover vs Finder) */}
        <div className="hidden sm:flex items-center apple-segmented-track p-0.5 rounded-lg text-[11px] font-medium ml-2">
          <button
            onClick={() => onChangeViewMode('studio')}
            className={`px-2.5 py-0.5 rounded-md transition-all flex items-center space-x-1.5 ${
              activeViewMode === 'studio'
                ? 'apple-segmented-pill text-white font-semibold'
                : 'text-white/60 hover:text-white'
            }`}
          >
            <AppWindow className="w-3 h-3 text-[#007aff]" />
            <span>Studio Window</span>
          </button>

          <button
            onClick={() => onChangeViewMode('menubar')}
            className={`px-2.5 py-0.5 rounded-md transition-all flex items-center space-x-1.5 ${
              activeViewMode === 'menubar'
                ? 'apple-segmented-pill text-white font-semibold'
                : 'text-white/60 hover:text-white'
            }`}
          >
            <HardDrive className="w-3 h-3 text-[#34c759]" />
            <span>Menu Bar Daemon</span>
            {dirtyCount > 0 && (
              <span className="bg-[#ff9f0a] text-black text-[9px] font-bold px-1 rounded-full">
                {dirtyCount}
              </span>
            )}
          </button>

          <button
            onClick={() => onChangeViewMode('finder')}
            className={`px-2.5 py-0.5 rounded-md transition-all flex items-center space-x-1.5 ${
              activeViewMode === 'finder'
                ? 'apple-segmented-pill text-white font-semibold'
                : 'text-white/60 hover:text-white'
            }`}
          >
            <FolderOpen className="w-3 h-3 text-[#5ac8fa]" />
            <span>Finder (~/ZeroDrive)</span>
          </button>
        </div>
      </div>

      {/* Right System Tray & Codebase Inspector */}
      <div className="flex items-center space-x-3">
        {/* Swift 5.9+ Source Codebase Exporter */}
        <button
          onClick={onOpenCodebase}
          className="flex items-center space-x-1.5 px-2.5 py-0.5 rounded-md apple-btn-secondary text-[11px] font-medium text-white/90 hover:text-white transition-colors"
          title="Inspect and download native Swift codebase & .dmg installer script"
        >
          <Code2 className="w-3.5 h-3.5 text-[#007aff]" />
          <span>Swift & .dmg Source</span>
        </button>

        {/* Menu Bar Extra Item */}
        <button
          onClick={() => onChangeViewMode('menubar')}
          className={`flex items-center space-x-1 px-1.5 py-0.5 rounded-md transition-all ${
            activeViewMode === 'menubar'
              ? 'bg-white/[0.12] text-white'
              : 'hover:bg-white/[0.06] text-white/80'
          }`}
          title="ZeroDrive Menu Bar Daemon"
        >
          <div className="relative">
            <HardDrive className={`w-3.5 h-3.5 ${isMounted ? 'text-[#007aff]' : 'text-white/40'}`} />
            {isMounted && (
              <span className="absolute -top-0.5 -right-0.5 w-1.5 h-1.5 bg-[#34c759] rounded-full" />
            )}
          </div>
          {dirtyCount > 0 && (
            <span className="bg-[#ff9f0a] text-[9px] font-bold px-1 rounded-full text-black">
              {dirtyCount}
            </span>
          )}
        </button>

        {/* macOS Status Indicators */}
        <div className="flex items-center space-x-2.5 text-white/60 border-l border-white/[0.08] pl-2.5">
          <button
            onClick={onToggleOnline}
            className={`flex items-center space-x-1.5 px-1.5 py-0.5 rounded transition-colors ${
              !isOnline ? 'bg-[#ff9f0a]/20 text-[#ff9f0a] border border-[#ff9f0a]/40' : 'hover:bg-white/[0.06] text-white/80'
            }`}
            title={isOnline ? 'Network: Online (Click to simulate offline)' : 'Network: Offline — Local Spool Active (Click to reconnect)'}
          >
            {isOnline ? (
              <Wifi className="w-3.5 h-3.5 text-white/80" />
            ) : (
              <>
                <WifiOff className="w-3.5 h-3.5 text-[#ff9f0a]" />
                <span className="text-[10px] font-bold tracking-tight">Offline (Local Spool)</span>
              </>
            )}
          </button>

          <div className="flex items-center space-x-1 text-[11px] font-mono">
            <Battery className="w-3.5 h-3.5 text-[#34c759]" />
            <span>98%</span>
          </div>
          <span className="text-[11px] text-white/85 font-medium">
            Mon Nov 2 &nbsp;11:15 AM
          </span>
        </div>
      </div>
    </header>
  );
};
