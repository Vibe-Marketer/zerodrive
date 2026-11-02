import React from 'react';
import { AlertTriangle, HardDrive, ShieldAlert, X } from 'lucide-react';
import { SpoolItem } from '../../types/zerodrive';
import { formatBytes } from '../../core/pureLogic';

interface QuitGuardModalProps {
  isOpen: boolean;
  actionType: 'quit' | 'unmount';
  spoolItems: SpoolItem[];
  onConfirmWaitAndFinish: () => void;
  onConfirmKeepInSpool: () => void;
  onCancel: () => void;
}

export const QuitGuardModal: React.FC<QuitGuardModalProps> = ({
  isOpen,
  actionType,
  spoolItems,
  onConfirmWaitAndFinish,
  onConfirmKeepInSpool,
  onCancel,
}) => {
  if (!isOpen) return null;

  const dirtyItems = spoolItems.filter(i => i.status === 'staging' || i.status === 'uploading');
  const dirtyBytes = dirtyItems.reduce((acc, curr) => acc + curr.sizeBytes, 0);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4 animate-in fade-in duration-200">
      <div className="w-full max-w-md bg-slate-900 border border-amber-500/30 rounded-2xl shadow-2xl p-6 text-white space-y-4">
        {/* Header with macOS Warning Badge */}
        <div className="flex items-start space-x-3.5">
          <div className="w-12 h-12 rounded-xl bg-amber-500/20 border border-amber-500/30 flex items-center justify-center shrink-0 text-amber-400">
            <AlertTriangle className="w-6 h-6" />
          </div>
          <div>
            <h2 className="text-base font-bold text-white leading-snug">
              ZeroDrive: {dirtyItems.length} Unsynced {dirtyItems.length === 1 ? 'File' : 'Files'} in Local Spool
            </h2>
            <p className="text-xs text-slate-300 mt-1 leading-relaxed">
              You have files queued or actively uploading to your cloud storage in{' '}
              <code className="text-amber-300 font-mono text-[11px] bg-slate-950/80 px-1 py-0.5 rounded">
                ~/.zerodrive-cache
              </code>{' '}
              ({formatBytes(dirtyBytes)}). {actionType === 'quit' ? 'Quitting' : 'Unmounting'} now could interrupt uploads or leave remote files incomplete.
            </p>
          </div>
        </div>

        {/* List of active spool files */}
        <div className="bg-slate-950/80 border border-white/10 rounded-lg p-2.5 max-h-36 overflow-y-auto space-y-1.5 text-xs">
          {dirtyItems.map((item) => (
            <div key={item.id} className="flex items-center justify-between text-slate-300">
              <span className="truncate pr-2 font-mono text-[11px]">{item.filename}</span>
              <span className="shrink-0 text-amber-400 font-mono text-[11px]">
                {item.status === 'staging' ? `Staging (${item.writeBackRemainingSec}s)` : `Uploading ${item.uploadProgress}%`}
              </span>
            </div>
          ))}
        </div>

        {/* Action Buttons matching NSAlert specification */}
        <div className="flex flex-col gap-2 pt-2">
          <button
            onClick={onConfirmWaitAndFinish}
            className="w-full py-2.5 px-4 rounded-lg bg-blue-600 hover:bg-blue-500 text-white font-medium text-xs transition-colors shadow-sm flex items-center justify-center space-x-2"
          >
            <span>Wait & {actionType === 'quit' ? 'Quit' : 'Unmount'} Automatically When Done</span>
          </button>

          <button
            onClick={onConfirmKeepInSpool}
            className="w-full py-2 px-4 rounded-lg bg-slate-800 hover:bg-slate-700 text-amber-300 font-medium text-xs border border-amber-500/20 transition-colors flex items-center justify-center space-x-2"
          >
            <span>Keep in Local Spool & {actionType === 'quit' ? 'Quit' : 'Unmount'} Now (Resumes Next Launch)</span>
          </button>

          <button
            onClick={onCancel}
            className="w-full py-1.5 px-4 rounded-lg hover:bg-white/5 text-slate-400 hover:text-white text-xs transition-colors"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
};
