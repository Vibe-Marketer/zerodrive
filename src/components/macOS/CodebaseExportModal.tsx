import React, { useState } from 'react';
import {
  Code2,
  Download,
  Copy,
  Check,
  FileCode,
  FolderTree,
  Terminal,
  X,
  ExternalLink,
  Layers,
  Sparkles,
} from 'lucide-react';
import JSZip from 'jszip';
import { SWIFT_CODEBASE_FILES, CodeFile } from '../../core/swiftCodebase';

interface CodebaseExportModalProps {
  isOpen: boolean;
  onClose: () => void;
}

export const CodebaseExportModal: React.FC<CodebaseExportModalProps> = ({
  isOpen,
  onClose,
}) => {
  const [selectedFile, setSelectedFile] = useState<CodeFile>(SWIFT_CODEBASE_FILES[0]);
  const [copied, setCopied] = useState(false);
  const [isZipping, setIsZipping] = useState(false);
  const [zipSuccess, setZipSuccess] = useState(false);

  if (!isOpen) return null;

  const handleCopyCode = () => {
    navigator.clipboard.writeText(selectedFile.content);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const handleDownloadZip = async () => {
    setIsZipping(true);
    try {
      const zip = new JSZip();
      const rootFolder = zip.folder('ZeroDriveProject')!;

      for (const file of SWIFT_CODEBASE_FILES) {
        rootFolder.file(file.path, file.content);
      }

      // Add a quick README.md
      rootFolder.file(
        'README.md',
        `# ZeroDrive — Native macOS Desktop Application & Multi-Cloud Streaming Engine

## Prerequisites
- macOS 13.0 (Ventura) or newer
- Xcode Command Line Tools installed (\`xcode-select --install\`)

## Build & DMG Installer Generation
Run the bundled build script:

\`\`\`bash
bash build_installer.sh
\`\`\`

This will:
1. Download & verify the official CGO-enabled \`rclone\` universal binary with \`nfsmount\`
2. Compile all Swift sources into a native Universal Binary (\`arm64\` + \`x86_64\`)
3. Embed \`rclone\` inside \`ZeroDrive.app/Contents/Resources/rclone\`
4. Ad-hoc codesign the application
5. Generate the standard drag-to-Applications \`build/ZeroDrive-Installer.dmg\`
`
      );

      const content = await zip.generateAsync({ type: 'blob' });
      const url = URL.createObjectURL(content);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'ZeroDrive-macOS-Swift-Sources.zip';
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);

      setZipSuccess(true);
      setTimeout(() => setZipSuccess(false), 3000);
    } catch (err) {
      console.error('Failed to create ZIP:', err);
    } finally {
      setIsZipping(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/75 backdrop-blur-md p-4 animate-in fade-in duration-200">
      <div className="w-full max-w-5xl h-[640px] bg-slate-900 border border-white/20 rounded-2xl shadow-2xl flex flex-col overflow-hidden text-slate-100">
        {/* Header */}
        <div className="h-12 bg-slate-800/90 border-b border-white/10 px-4 flex items-center justify-between select-none shrink-0">
          <div className="flex items-center space-x-2.5">
            <div className="w-7 h-7 rounded-lg bg-blue-600/30 border border-blue-500/40 flex items-center justify-center text-blue-400">
              <Code2 className="w-4 h-4" />
            </div>
            <div>
              <h2 className="text-xs font-bold text-white flex items-center space-x-1.5">
                <span>ZeroDrive macOS Swift 5.9+ Source Codebase</span>
                <span className="text-[10px] font-mono px-1.5 py-0.2 rounded bg-sky-500/20 text-sky-300 border border-sky-500/30">
                  Universal Binary (arm64 + x86_64)
                </span>
              </h2>
              <p className="text-[10px] text-slate-400">
                100% production-ready native implementation & .dmg installer script
              </p>
            </div>
          </div>

          <div className="flex items-center space-x-2">
            <button
              onClick={handleDownloadZip}
              disabled={isZipping}
              className="py-1 px-3 rounded-lg bg-blue-600 hover:bg-blue-500 text-white font-medium text-xs transition-colors flex items-center space-x-1.5 shadow-sm disabled:opacity-50"
            >
              <Download className="w-3.5 h-3.5" />
              <span>{isZipping ? 'Generating ZIP...' : zipSuccess ? 'Downloaded!' : 'Download Full Codebase (.zip)'}</span>
            </button>

            <button
              onClick={onClose}
              className="p-1.5 rounded-lg hover:bg-white/10 text-slate-400 hover:text-white transition-colors"
            >
              <X className="w-4 h-4" />
            </button>
          </div>
        </div>

        {/* Content: File Tree on left + Code Viewer on right */}
        <div className="flex-1 flex overflow-hidden">
          {/* File Explorer Tree */}
          <div className="w-64 bg-slate-950/70 border-r border-white/10 p-3 flex flex-col justify-between shrink-0 select-none overflow-y-auto">
            <div className="space-y-3">
              <div className="text-[10px] font-bold uppercase tracking-wider text-slate-400 px-2 flex items-center justify-between">
                <span>Project Files ({SWIFT_CODEBASE_FILES.length})</span>
                <FolderTree className="w-3 h-3 text-slate-500" />
              </div>

              <div className="space-y-1">
                {SWIFT_CODEBASE_FILES.map((file) => {
                  const isSelected = selectedFile.path === file.path;
                  return (
                    <button
                      key={file.path}
                      onClick={() => setSelectedFile(file)}
                      className={`w-full text-left px-2.5 py-1.5 rounded-lg text-xs flex items-center space-x-2 transition-all ${
                        isSelected
                          ? 'bg-blue-600/30 text-white font-medium border border-blue-500/40 shadow-sm'
                          : 'text-slate-300 hover:bg-white/5 hover:text-white'
                      }`}
                    >
                      <FileCode className={`w-3.5 h-3.5 shrink-0 ${isSelected ? 'text-sky-400' : 'text-slate-400'}`} />
                      <span className="truncate font-mono text-[11px]">{file.filename}</span>
                    </button>
                  );
                })}
              </div>
            </div>

            {/* Quick Terminal Guide */}
            <div className="p-2.5 rounded-xl bg-slate-900 border border-white/10 text-[10px] space-y-1.5">
              <span className="font-semibold text-slate-300 flex items-center space-x-1">
                <Terminal className="w-3 h-3 text-sky-400" />
                <span>Build on your Mac:</span>
              </span>
              <code className="block bg-slate-950 p-1.5 rounded font-mono text-emerald-400 text-[9px] overflow-x-auto">
                bash build_installer.sh
              </code>
            </div>
          </div>

          {/* Code Viewer */}
          <div className="flex-1 bg-slate-950 flex flex-col overflow-hidden">
            {/* File Info Bar */}
            <div className="h-9 bg-slate-900/60 border-b border-white/10 px-3.5 flex items-center justify-between text-xs shrink-0">
              <div className="flex items-center space-x-2">
                <span className="font-mono text-sky-300 text-[11px] font-semibold">
                  {selectedFile.path}
                </span>
                <span className="text-slate-500">•</span>
                <span className="text-[10px] text-slate-400 truncate max-w-md">
                  {selectedFile.description}
                </span>
              </div>

              <button
                onClick={handleCopyCode}
                className="flex items-center space-x-1 px-2 py-0.5 rounded bg-white/10 hover:bg-white/15 text-slate-200 text-[11px] font-medium transition-colors"
              >
                {copied ? (
                  <>
                    <Check className="w-3 h-3 text-emerald-400" />
                    <span className="text-emerald-400">Copied</span>
                  </>
                ) : (
                  <>
                    <Copy className="w-3 h-3 text-slate-400" />
                    <span>Copy Code</span>
                  </>
                )}
              </button>
            </div>

            {/* Code Body */}
            <div className="flex-1 p-4 overflow-auto font-mono text-xs leading-relaxed text-slate-200 select-text">
              <pre className="whitespace-pre">
                <code>{selectedFile.content}</code>
              </pre>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
