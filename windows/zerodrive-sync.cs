// ZeroDrive Cloud Files Sync Client for Windows
// Native integration with Windows Cloud Filter API (cfapi.dll) & ZeroDrive REST/SSE backend.
// Compatible with .NET 8 / .NET 9 and .NET Framework 4.8 (csc.exe).

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ZeroDrive.Windows
{
    public class Program
    {
        public static async Task<int> Main(string[] args)
        {
            Console.OutputEncoding = Encoding.UTF8;
            Console.WriteLine("==================================================");
            Console.WriteLine(" ZeroDrive Cloud Files Native Sync Client (Windows)");
            Console.WriteLine("==================================================");

            string userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string syncRoot = Path.Combine(userProfile, "ZeroDrive");
            string apiBase = Environment.GetEnvironmentVariable("ZERODRIVE_API_BASE") ?? "https://api.zerodrive.dev";
            string updateApiBase = Environment.GetEnvironmentVariable("ZERODRIVE_UPDATE_ENDPOINT") ?? apiBase;
            string apiToken = Environment.GetEnvironmentVariable("ZERODRIVE_API_TOKEN") ?? "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633";
            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string installDir = string.IsNullOrEmpty(localAppData)
                ? Path.Combine(userProfile, ".zerodrive-win")
                : Path.Combine(localAppData, "ZeroDrive");

            for (int i = 0; i < args.Length; i++)
            {
                if ((args[i] == "--path" || args[i] == "-p") && i + 1 < args.Length)
                {
                    syncRoot = Path.GetFullPath(args[++i]);
                }
                else if ((args[i] == "--token" || args[i] == "-t") && i + 1 < args.Length)
                {
                    apiToken = args[++i];
                }
                else if (args[i] == "--endpoint" && i + 1 < args.Length)
                {
                    apiBase = args[++i];
                    updateApiBase = apiBase;
                }
                else if (args[i] == "--install-dir" && i + 1 < args.Length)
                {
                    installDir = Path.GetFullPath(args[++i]);
                }
                else if (args[i] == "--version" || args[i] == "-v")
                {
                    Console.WriteLine($"ZeroDrive Windows Sync v{WindowsAutoUpdater.GetInstalledVersion(installDir)}");
                    return 0;
                }
                else if (args[i] == "--check-update")
                {
                    return await WindowsAutoUpdater.CheckOnlyAsync(updateApiBase, installDir);
                }
                else if (args[i] == "--changelog")
                {
                    return await WindowsAutoUpdater.PrintChangelogAsync(updateApiBase, installDir);
                }
                else if (args[i] == "--update")
                {
                    return await WindowsAutoUpdater.DownloadAndApplyUpdateAsync(updateApiBase, installDir, false, false);
                }
                else if (args[i] == "--verify-auto-update")
                {
                    if (i + 1 < args.Length && !args[i + 1].StartsWith("-"))
                    {
                        installDir = Path.GetFullPath(args[++i]);
                    }
                    bool badSha = Array.Exists(args, a => a == "--simulate-bad-sha");
                    bool badSig = Array.Exists(args, a => a == "--simulate-bad-sig");
                    return await WindowsAutoUpdater.DownloadAndApplyUpdateAsync(updateApiBase, installDir, badSha, badSig);
                }
                else if (args[i] == "--unregister")
                {
                    Console.WriteLine($"Unregistering sync root: {syncRoot}");
                    CloudFilterNative.UnregisterSyncRoot(syncRoot);
                    Console.WriteLine("Unregistered successfully.");
                    return 0;
                }
                else if (args[i] == "--help" || args[i] == "-h")
                {
                    Console.WriteLine("Usage: zerodrive-sync [options]");
                    Console.WriteLine("  --path, -p <dir>       Sync root directory (default: %USERPROFILE%\\ZeroDrive)");
                    Console.WriteLine("  --token, -t <token>    ZeroDrive Bearer token");
                    Console.WriteLine("  --endpoint <url>       ZeroDrive API base URL (default: https://api.zerodrive.dev)");
                    Console.WriteLine("  --version, -v          Show installed ZeroDrive version");
                    Console.WriteLine("  --check-update         Check for available Windows updates");
                    Console.WriteLine("  --update               Download, verify, and install the latest update");
                    Console.WriteLine("  --changelog            Show ZeroDrive release notes and changelog");
                    Console.WriteLine("  --unregister           Unregister Windows Cloud Filter sync root and exit");
                    return 0;
                }
            }

            if (!Directory.Exists(syncRoot))
            {
                Directory.CreateDirectory(syncRoot);
                Console.WriteLine($"Created sync root folder: {syncRoot}");
            }

            using var cts = new CancellationTokenSource();
            Console.CancelKeyPress += (s, e) =>
            {
                Console.WriteLine("\nStopping ZeroDrive sync engine...");
                e.Cancel = true;
                cts.Cancel();
            };

            var syncClient = new CloudFilterSyncClient(syncRoot, apiBase, apiToken);
            try
            {
                await syncClient.StartAsync(cts.Token);
            }
            catch (OperationCanceledException)
            {
                Console.WriteLine("ZeroDrive sync engine stopped cleanly.");
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Fatal sync engine error: {ex.Message}");
                Console.Error.WriteLine(ex.ToString());
                return 1;
            }

            return 0;
        }
    }

    public class CloudFilterSyncClient : IDisposable
    {
        private readonly string _syncRoot;
        private readonly string _apiBase;
        private readonly string _apiToken;
        private readonly HttpClient _http;
        private readonly ConcurrentDictionary<string, byte> _suppressedPaths = new(StringComparer.OrdinalIgnoreCase);
        private readonly ConcurrentDictionary<string, DateTime> _recentUploads = new(StringComparer.OrdinalIgnoreCase);
        private CloudFilterNative.CF_CONNECTION_KEY _connectionKey;
        private FileSystemWatcher _watcher;
        private bool _cfApiAvailable = false;
        private CloudFilterNative.CF_CALLBACK _fetchDataCallback;
        private CloudFilterNative.CF_CALLBACK _cancelFetchCallback;

        public CloudFilterSyncClient(string syncRoot, string apiBase, string apiToken)
        {
            _syncRoot = syncRoot.TrimEnd('\\', '/');
            _apiBase = apiBase.TrimEnd('/');
            _apiToken = apiToken;

            _http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", _apiToken);
            _http.DefaultRequestHeaders.Add("User-Agent", "ZeroDrive-WindowsSync/3.0");
        }

        public async Task StartAsync(CancellationToken ct)
        {
            Console.WriteLine($"[Init] ZeroDrive Sync Root : {_syncRoot}");
            Console.WriteLine($"[Init] Remote API Endpoint : {_apiBase}");

            // 1. Initialize Cloud Filter API (cfapi.dll) if supported
            InitCloudFilter();

            // 2. Perform initial scan of remote files and create placeholders
            Console.WriteLine("[Sync] Building initial placeholder tree from cloud...");
            await PopulateRemotePlaceholdersAsync(ct);

            // 3. Start local FileSystemWatcher to capture Windows edits
            StartLocalWatcher();

            // 4. Start concurrent sync workers:
            //    A) Server-Sent Events (SSE) listener (/v1/events)
            //    B) Polling fallback for ledger activities (/v1/activity)
            //    C) Auto-update check on startup & every 4 hours
            var sseTask = RunSseEventStreamAsync(ct);
            var pollTask = RunActivityPollAsync(ct);
            var updateTask = WindowsAutoUpdater.RunPeriodicUpdateMonitorAsync(_apiBase, ct);

            Console.WriteLine("[Ready] ZeroDrive Windows Sync is ACTIVE. Waiting for changes...");
            await Task.WhenAll(sseTask, pollTask, updateTask);
        }

        private void InitCloudFilter()
        {
            try
            {
                int hr = CloudFilterNative.RegisterSyncRoot(_syncRoot, "ZeroDrive", "3.0.0");
                if (hr == 0 || hr == unchecked((int)0x800700B7)) // 0 or ERROR_ALREADY_EXISTS
                {
                    _fetchDataCallback = OnFetchData;
                    _cancelFetchCallback = OnCancelFetchData;

                    var callbacks = new CloudFilterNative.CF_CALLBACK_REGISTRATION[]
                    {
                        new CloudFilterNative.CF_CALLBACK_REGISTRATION
                        {
                            Type = CloudFilterNative.CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_FETCH_DATA,
                            Callback = Marshal.GetFunctionPointerForDelegate(_fetchDataCallback)
                        },
                        new CloudFilterNative.CF_CALLBACK_REGISTRATION
                        {
                            Type = CloudFilterNative.CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_CANCEL_FETCH_DATA,
                            Callback = Marshal.GetFunctionPointerForDelegate(_cancelFetchCallback)
                        },
                        new CloudFilterNative.CF_CALLBACK_REGISTRATION
                        {
                            Type = CloudFilterNative.CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_NONE,
                            Callback = IntPtr.Zero
                        }
                    };

                    int connectHr = CloudFilterNative.CfConnectSyncRoot(
                        _syncRoot,
                        callbacks,
                        IntPtr.Zero,
                        CloudFilterNative.CF_CONNECT_FLAGS.CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH,
                        out _connectionKey);

                    if (connectHr == 0)
                    {
                        _cfApiAvailable = true;
                        Console.WriteLine("[CloudFilter] Windows Cloud Files API (cfapi.dll) connected successfully.");
                        return;
                    }
                    Console.WriteLine($"[CloudFilter] CfConnectSyncRoot returned 0x{connectHr:X8}. Falling back to sparse mode.");
                }
                else
                {
                    Console.WriteLine($"[CloudFilter] CfRegisterSyncRoot returned 0x{hr:X8}. Running in standard sync mode.");
                }
            }
            catch (DllNotFoundException)
            {
                Console.WriteLine("[CloudFilter] cfapi.dll not present on this Windows OS version. Running in sparse sync mode.");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[CloudFilter] Cloud filter init notice: {ex.Message}. Running in standard mode.");
            }
        }

        private void OnFetchData(in CloudFilterNative.CF_CALLBACK_INFO callbackInfo, in CloudFilterNative.CF_CALLBACK_PARAMETERS callbackParameters)
        {
            string fullPath = Marshal.PtrToStringUni(callbackInfo.NormalizedPath);
            long reqOffset = callbackParameters.FetchData.RequiredFileOffset;
            long reqLength = callbackParameters.FetchData.RequiredLength;
            var connKey = callbackInfo.ConnectionKey;
            var transferKey = callbackInfo.TransferKey;

            Console.WriteLine($"[Hydrate] App requested hydration: {fullPath} (Offset: {reqOffset}, Length: {reqLength})");

            Task.Run(async () =>
            {
                try
                {
                    string relativePath = GetRelativeVaultPath(fullPath);
                    string downloadUrl = $"{_apiBase}/vault/download?path={Uri.EscapeDataString(relativePath)}";

                    using var req = new HttpRequestMessage(HttpMethod.Get, downloadUrl);
                    using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead);
                    resp.EnsureSuccessStatusCode();

                    byte[] fileBytes = await resp.Content.ReadAsByteArrayAsync();
                    GCHandle pinned = GCHandle.Alloc(fileBytes, GCHandleType.Pinned);
                    try
                    {
                        var opInfo = new CloudFilterNative.CF_OPERATION_INFO
                        {
                            StructSize = (uint)Marshal.SizeOf<CloudFilterNative.CF_OPERATION_INFO>(),
                            Type = CloudFilterNative.CF_OPERATION_TYPE.CF_OPERATION_TYPE_TRANSFER_DATA,
                            ConnectionKey = connKey,
                            TransferKey = transferKey
                        };

                        var opParams = new CloudFilterNative.CF_OPERATION_PARAMETERS
                        {
                            ParamSize = (uint)Marshal.SizeOf<CloudFilterNative.CF_OPERATION_PARAMETERS>(),
                            TransferData = new CloudFilterNative.CF_OPERATION_PARAMETERS.TRANSFER_DATA_STRUCT
                            {
                                Flags = 0,
                                CompletionStatus = 0, // STATUS_SUCCESS
                                Buffer = pinned.AddrOfPinnedObject(),
                                Offset = 0,
                                Length = fileBytes.Length
                            }
                        };

                        int execHr = CloudFilterNative.CfExecute(in opInfo, ref opParams);
                        if (execHr == 0)
                        {
                            Console.WriteLine($"[Hydrate] Hydration complete: {relativePath} ({fileBytes.Length} bytes)");
                        }
                        else
                        {
                            Console.Error.WriteLine($"[Hydrate] CfExecute returned 0x{execHr:X8}");
                        }
                    }
                    finally
                    {
                        pinned.Free();
                    }
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[Hydrate] Failed to stream data: {ex.Message}");
                }
            });
        }

        private void OnCancelFetchData(in CloudFilterNative.CF_CALLBACK_INFO callbackInfo, in CloudFilterNative.CF_CALLBACK_PARAMETERS callbackParameters)
        {
            Console.WriteLine("[Hydrate] Read canceled by caller.");
        }

        private async Task PopulateRemotePlaceholdersAsync(CancellationToken ct)
        {
            try
            {
                string url = $"{_apiBase}/v1/files?recursive=true&limit=1000";
                var resp = await _http.GetAsync(url, ct);
                if (!resp.IsSuccessStatusCode)
                {
                    Console.WriteLine($"[Sync] Failed to enumerate remote files: HTTP {(int)resp.StatusCode}");
                    return;
                }

                string json = await resp.Content.ReadAsStringAsync(ct);
                using var doc = JsonDocument.Parse(json);
                var root = doc.RootElement;

                if (root.TryGetProperty("directories", out var dirs))
                {
                    foreach (var dir in dirs.EnumerateArray())
                    {
                        string path = dir.GetProperty("path").GetString();
                        if (string.IsNullOrWhiteSpace(path)) continue;
                        string localDir = Path.Combine(_syncRoot, NormalizeToWindowsPath(path));
                        if (!Directory.Exists(localDir))
                        {
                            Directory.CreateDirectory(localDir);
                        }
                    }
                }

                if (root.TryGetProperty("files", out var files))
                {
                    foreach (var file in files.EnumerateArray())
                    {
                        string relPath = file.GetProperty("path").GetString();
                        if (string.IsNullOrWhiteSpace(relPath)) continue;

                        long size = 0;
                        if (file.TryGetProperty("size", out var sizeEl))
                        {
                            size = sizeEl.GetInt64();
                        }

                        string modifiedStr = file.TryGetProperty("modified", out var modEl) ? modEl.GetString() : null;
                        DateTime modified = DateTime.UtcNow;
                        if (!string.IsNullOrEmpty(modifiedStr))
                        {
                            DateTime.TryParse(modifiedStr, out modified);
                        }

                        CreateOrUpdateLocalPlaceholder(relPath, size, modified);
                    }
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[Sync] Error populating placeholders: {ex.Message}");
            }
        }

        private void CreateOrUpdateLocalPlaceholder(string relativeVaultPath, long size, DateTime modified)
        {
            string localPath = Path.Combine(_syncRoot, NormalizeToWindowsPath(relativeVaultPath));
            string dir = Path.GetDirectoryName(localPath);
            if (!Directory.Exists(dir))
            {
                Directory.CreateDirectory(dir);
            }

            if (File.Exists(localPath))
            {
                // File already exists locally. If size matches or already hydrated, leave intact.
                return;
            }

            _suppressedPaths.TryAdd(localPath, 0);
            try
            {
                if (_cfApiAvailable)
                {
                    int hr = CloudFilterNative.CreatePlaceholder(dir, Path.GetFileName(localPath), relativeVaultPath, size, modified);
                    if (hr == 0)
                    {
                        Console.WriteLine($"[Placeholder] Native Cloud Placeholder created: {relativeVaultPath} ({size} bytes)");
                        return;
                    }
                }

                // Fallback: Create lightweight 0-byte or sparse placeholder with metadata tag
                using (var fs = new FileStream(localPath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite))
                {
                    // Created 0-byte placeholder
                }
                File.SetLastWriteTimeUtc(localPath, modified);
                Console.WriteLine($"[Placeholder] Sparse placeholder created: {relativeVaultPath} ({size} bytes)");
            }
            finally
            {
                Task.Delay(500).ContinueWith(_ => { _suppressedPaths.TryRemove(localPath, out byte _); });
            }
        }

        private void StartLocalWatcher()
        {
            _watcher = new FileSystemWatcher(_syncRoot)
            {
                IncludeSubdirectories = true,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size
            };

            _watcher.Created += (s, e) => OnLocalFileChanged(e.FullPath, "created");
            _watcher.Changed += (s, e) => OnLocalFileChanged(e.FullPath, "modified");
            _watcher.Deleted += (s, e) => OnLocalFileDeleted(e.FullPath);
            _watcher.Renamed += (s, e) => OnLocalFileRenamed(e.OldFullPath, e.FullPath);

            _watcher.EnableRaisingEvents = true;
            Console.WriteLine("[Watcher] Monitoring local filesystem changes in sync root...");
        }

        private void OnLocalFileChanged(string fullPath, string action)
        {
            if (ShouldIgnoreFile(fullPath)) return;
            if (_suppressedPaths.ContainsKey(fullPath)) return;

            Task.Run(async () =>
            {
                await Task.Delay(350); // Debounce rapid writes
                if (_suppressedPaths.ContainsKey(fullPath)) return;

                // Check recent upload debounce
                if (_recentUploads.TryGetValue(fullPath, out var lastUpload) && (DateTime.UtcNow - lastUpload).TotalMilliseconds < 1500)
                {
                    return;
                }

                await UploadFileWithLockRetryAsync(fullPath);
            });
        }

        private void OnLocalFileDeleted(string fullPath)
        {
            if (ShouldIgnoreFile(fullPath)) return;
            if (_suppressedPaths.ContainsKey(fullPath)) return;

            Task.Run(async () =>
            {
                string relVaultPath = GetRelativeVaultPath(fullPath);
                try
                {
                    string url = $"{_apiBase}/v1/files?path={Uri.EscapeDataString(relVaultPath)}";
                    var resp = await _http.DeleteAsync(url);
                    if (resp.IsSuccessStatusCode)
                    {
                        Console.WriteLine($"[Cloud] Deleted remote item: {relVaultPath}");
                    }
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[Cloud] Error deleting {relVaultPath}: {ex.Message}");
                }
            });
        }

        private void OnLocalFileRenamed(string oldFullPath, string newFullPath)
        {
            if (ShouldIgnoreFile(newFullPath)) return;
            Task.Run(async () =>
            {
                string oldRel = GetRelativeVaultPath(oldFullPath);
                string newRel = GetRelativeVaultPath(newFullPath);

                try
                {
                    string moveUrl = $"{_apiBase}/v1/files/move";
                    var body = JsonSerializer.Serialize(new { source = oldRel, destination = newRel });
                    using var content = new StringContent(body, Encoding.UTF8, "application/json");
                    var resp = await _http.PostAsync(moveUrl, content);
                    if (resp.IsSuccessStatusCode)
                    {
                        Console.WriteLine($"[Cloud] Renamed: {oldRel} -> {newRel}");
                    }
                    else
                    {
                        // Fallback: re-upload new path
                        await UploadFileWithLockRetryAsync(newFullPath);
                    }
                }
                catch
                {
                    await UploadFileWithLockRetryAsync(newFullPath);
                }
            });
        }

        private async Task UploadFileWithLockRetryAsync(string fullPath)
        {
            if (!File.Exists(fullPath)) return;

            string relVaultPath = GetRelativeVaultPath(fullPath);
            byte[] fileData = null;

            // Exponential backoff for locked files (ERROR_SHARING_VIOLATION)
            int[] delays = { 100, 250, 500, 1000, 2000 };
            for (int attempt = 0; attempt <= delays.Length; attempt++)
            {
                try
                {
                    using (var fs = new FileStream(fullPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    {
                        fileData = new byte[fs.Length];
                        int bytesRead = 0;
                        while (bytesRead < fileData.Length)
                        {
                            int read = await fs.ReadAsync(fileData, bytesRead, fileData.Length - bytesRead);
                            if (read == 0) break;
                            bytesRead += read;
                        }
                    }
                    break; // Successfully read
                }
                catch (IOException ex) when (IsSharingViolation(ex))
                {
                    if (attempt == delays.Length)
                    {
                        Console.WriteLine($"[Lock] File locked by another process after {delays.Length} retries: {relVaultPath}");
                        return;
                    }
                    await Task.Delay(delays[attempt]);
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[Read] Read error on {relVaultPath}: {ex.Message}");
                    return;
                }
            }

            if (fileData == null) return;

            try
            {
                string uploadUrl = $"{_apiBase}/vault/upload?path={Uri.EscapeDataString(relVaultPath)}";
                using var content = new ByteArrayContent(fileData);
                content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");

                var resp = await _http.PostAsync(uploadUrl, content);
                if (resp.IsSuccessStatusCode)
                {
                    _recentUploads[fullPath] = DateTime.UtcNow;
                    Console.WriteLine($"[Cloud] Uploaded to cloud: {relVaultPath} ({fileData.Length} bytes)");
                }
                else
                {
                    Console.Error.WriteLine($"[Cloud] Upload failed for {relVaultPath}: HTTP {(int)resp.StatusCode}");
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[Cloud] Network upload error for {relVaultPath}: {ex.Message}");
            }
        }

        private async Task RunSseEventStreamAsync(CancellationToken ct)
        {
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    string sseUrl = $"{_apiBase}/v1/events";
                    using var req = new HttpRequestMessage(HttpMethod.Get, sseUrl);
                    req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));

                    using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
                    if (!resp.IsSuccessStatusCode)
                    {
                        await Task.Delay(5000, ct);
                        continue;
                    }

                    using var stream = await resp.Content.ReadAsStreamAsync(ct);
                    using var reader = new StreamReader(stream);

                    Console.WriteLine("[SSE] Connected to real-time sync event stream.");
                    while (!reader.EndOfStream && !ct.IsCancellationRequested)
                    {
                        string line = await reader.ReadLineAsync();
                        if (string.IsNullOrWhiteSpace(line)) continue;

                        if (line.StartsWith("data:", StringComparison.OrdinalIgnoreCase))
                        {
                            string payload = line.Substring(5).Trim();
                            HandleRemoteEvent(payload);
                        }
                    }
                }
                catch (OperationCanceledException) { break; }
                catch (Exception ex)
                {
                    Console.WriteLine($"[SSE] Connection dropped ({ex.Message}), reconnecting in 3s...");
                    await Task.Delay(3000, ct);
                }
            }
        }

        private async Task RunActivityPollAsync(CancellationToken ct)
        {
            string lastProcessedId = null;

            while (!ct.IsCancellationRequested)
            {
                try
                {
                    await Task.Delay(2500, ct);
                    string url = $"{_apiBase}/v1/activity?limit=10";
                    var resp = await _http.GetAsync(url, ct);
                    if (!resp.IsSuccessStatusCode) continue;

                    string json = await resp.Content.ReadAsStringAsync(ct);
                    using var doc = JsonDocument.Parse(json);
                    if (!doc.RootElement.TryGetProperty("activities", out var activities)) continue;

                    foreach (var act in activities.EnumerateArray())
                    {
                        string id = act.GetProperty("id").GetString();
                        if (id == lastProcessedId) break;

                        string action = act.TryGetProperty("action", out var actEl) ? actEl.GetString() : "";
                        string path = act.TryGetProperty("path", out var pEl) ? pEl.GetString() : null;

                        if (!string.IsNullOrEmpty(path))
                        {
                            long size = act.TryGetProperty("size", out var sEl) ? sEl.GetInt64() : 0;
                            if (action.Contains("write") || action.Contains("upload") || action.Contains("create"))
                            {
                                CreateOrUpdateLocalPlaceholder(path, size, DateTime.UtcNow);
                            }
                            else if (action.Contains("delete"))
                            {
                                DeleteLocalItem(path);
                            }
                        }
                    }

                    foreach (var act in activities.EnumerateArray())
                    {
                        lastProcessedId = act.GetProperty("id").GetString();
                        break;
                    }
                }
                catch (OperationCanceledException) { break; }
                catch { /* Ignore background poll glitch */ }
            }
        }

        private void HandleRemoteEvent(string jsonPayload)
        {
            try
            {
                using var doc = JsonDocument.Parse(jsonPayload);
                var root = doc.RootElement;
                string action = root.TryGetProperty("event", out var eEl) ? eEl.GetString() : "";
                string path = root.TryGetProperty("path", out var pEl) ? pEl.GetString() : "";

                if (string.IsNullOrEmpty(path)) return;

                long size = root.TryGetProperty("size", out var sEl) ? sEl.GetInt64() : 0;
                string modifiedStr = root.TryGetProperty("modified", out var mEl) ? mEl.GetString() : null;
                DateTime modified = DateTime.UtcNow;
                if (!string.IsNullOrEmpty(modifiedStr)) DateTime.TryParse(modifiedStr, out modified);

                if (action == "file_written" || action == "file_created")
                {
                    Console.WriteLine($"[Event] Remote change from Mac: {path} ({size} bytes)");
                    CreateOrUpdateLocalPlaceholder(path, size, modified);
                }
                else if (action == "file_deleted")
                {
                    Console.WriteLine($"[Event] Remote delete from Mac: {path}");
                    DeleteLocalItem(path);
                }
            }
            catch { }
        }

        private void DeleteLocalItem(string relativeVaultPath)
        {
            string localPath = Path.Combine(_syncRoot, NormalizeToWindowsPath(relativeVaultPath));
            if (File.Exists(localPath))
            {
                _suppressedPaths.TryAdd(localPath, 0);
                try { File.Delete(localPath); }
                finally { Task.Delay(500).ContinueWith(_ => { _suppressedPaths.TryRemove(localPath, out byte _); }); }
            }
            else if (Directory.Exists(localPath))
            {
                _suppressedPaths.TryAdd(localPath, 0);
                try { Directory.Delete(localPath, true); }
                finally { Task.Delay(500).ContinueWith(_ => { _suppressedPaths.TryRemove(localPath, out byte _); }); }
            }
        }

        private string NormalizeToWindowsPath(string path)
        {
            return path.Replace('/', '\\').Trim('\\');
        }

        private string GetRelativeVaultPath(string fullWindowsPath)
        {
            string rel = fullWindowsPath.Substring(_syncRoot.Length).TrimStart('\\', '/');
            return rel.Replace('\\', '/');
        }

        private bool ShouldIgnoreFile(string path)
        {
            string fileName = Path.GetFileName(path);
            if (string.IsNullOrEmpty(fileName)) return true;
            if (fileName.Equals("desktop.ini", StringComparison.OrdinalIgnoreCase)) return true;
            if (fileName.Equals("Thumbs.db", StringComparison.OrdinalIgnoreCase)) return true;
            if (fileName.StartsWith("~$")) return true; // Temporary Office lock file
            if (fileName.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase)) return true;
            if (fileName.EndsWith(".crdownload", StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        private static bool IsSharingViolation(IOException ex)
        {
            int hr = Marshal.GetHRForException(ex);
            return hr == unchecked((int)0x80070020) || hr == unchecked((int)0x80070021); // ERROR_SHARING_VIOLATION or ERROR_LOCK_VIOLATION
        }

        public void Dispose()
        {
            _watcher?.Dispose();
            if (_connectionKey.Internal != IntPtr.Zero)
            {
                CloudFilterNative.CfDisconnectSyncRoot(_connectionKey);
            }
            _http?.Dispose();
        }
    }

    /// <summary>
    /// P/Invoke bindings for Windows Cloud Filter API (cfapi.dll)
    /// </summary>
    public static class CloudFilterNative
    {
        private const string CFAPI = "cfapi.dll";

        public enum CF_CALLBACK_TYPE
        {
            CF_CALLBACK_TYPE_FETCH_DATA = 0,
            CF_CALLBACK_TYPE_VALIDATE_DATA = 1,
            CF_CALLBACK_TYPE_CANCEL_FETCH_DATA = 2,
            CF_CALLBACK_TYPE_FETCH_PLACEHOLDERS = 3,
            CF_CALLBACK_TYPE_CANCEL_FETCH_PLACEHOLDERS = 4,
            CF_CALLBACK_TYPE_NOTIFY_FILE_OPEN_COMPLETION = 5,
            CF_CALLBACK_TYPE_NOTIFY_FILE_CLOSE_COMPLETION = 6,
            CF_CALLBACK_TYPE_NOTIFY_DEHYDRATE = 7,
            CF_CALLBACK_TYPE_NOTIFY_DEHYDRATE_COMPLETION = 8,
            CF_CALLBACK_TYPE_NOTIFY_DELETE = 9,
            CF_CALLBACK_TYPE_NOTIFY_DELETE_COMPLETION = 10,
            CF_CALLBACK_TYPE_NOTIFY_RENAME = 11,
            CF_CALLBACK_TYPE_NOTIFY_RENAME_COMPLETION = 12,
            CF_CALLBACK_TYPE_NONE = 0xFFFFFFF
        }

        public enum CF_OPERATION_TYPE
        {
            CF_OPERATION_TYPE_TRANSFER_DATA = 0,
            CF_OPERATION_TYPE_RETRIEVE_DATA = 1,
            CF_OPERATION_TYPE_ACK_DATA = 2,
            CF_OPERATION_TYPE_RESTART_HYDRATION = 3,
            CF_OPERATION_TYPE_TRANSFER_PLACEHOLDERS = 4,
            CF_OPERATION_TYPE_ACK_DEHYDRATE = 5,
            CF_OPERATION_TYPE_ACK_DELETE = 6,
            CF_OPERATION_TYPE_ACK_RENAME = 7
        }

        [Flags]
        public enum CF_CONNECT_FLAGS
        {
            CF_CONNECT_FLAG_NONE = 0,
            CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH = 1,
            CF_CONNECT_FLAG_REQUIRE_PROCESS_INFO = 2
        }

        [Flags]
        public enum CF_PLACEHOLDER_CREATE_FLAGS
        {
            CF_PLACEHOLDER_CREATE_FLAG_NONE = 0,
            CF_PLACEHOLDER_CREATE_FLAG_DISABLE_ON_DEMAND_POPULATION = 1,
            CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC = 2,
            CF_PLACEHOLDER_CREATE_FLAG_SUPERSEDE = 4,
            CF_PLACEHOLDER_CREATE_FLAG_ALWAYS_FULL = 8
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct CF_CONNECTION_KEY
        {
            public IntPtr Internal;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct CF_CALLBACK_REGISTRATION
        {
            public CF_CALLBACK_TYPE Type;
            public IntPtr Callback;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct CF_CALLBACK_INFO
        {
            public uint StructSize;
            public CF_CONNECTION_KEY ConnectionKey;
            public IntPtr CallbackContext;
            public IntPtr ProcessInfo;
            public IntPtr NormalizedPath;
            public long TransferKey;
            public long FileId;
            public long VolumeId;
            public IntPtr FileIdentity;
            public uint FileIdentityLength;
        }

        [StructLayout(LayoutKind.Explicit)]
        public struct CF_CALLBACK_PARAMETERS
        {
            [FieldOffset(0)]
            public uint ParamSize;

            [FieldOffset(8)]
            public FETCH_DATA_STRUCT FetchData;

            [StructLayout(LayoutKind.Sequential)]
            public struct FETCH_DATA_STRUCT
            {
                public uint Flags;
                public long RequiredFileOffset;
                public long RequiredLength;
                public long OptionalFileOffset;
                public long OptionalLength;
                public long LastExecutedOffset;
                public long LastExecutedLength;
            }
        }

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        public delegate void CF_CALLBACK(
            in CF_CALLBACK_INFO callbackInfo,
            in CF_CALLBACK_PARAMETERS callbackParameters);

        [StructLayout(LayoutKind.Sequential)]
        public struct CF_OPERATION_INFO
        {
            public uint StructSize;
            public CF_OPERATION_TYPE Type;
            public CF_CONNECTION_KEY ConnectionKey;
            public long TransferKey;
            public IntPtr CorrelationVector;
            public IntPtr SyncStatus;
            public IntPtr RequestKey;
        }

        [StructLayout(LayoutKind.Explicit)]
        public struct CF_OPERATION_PARAMETERS
        {
            [FieldOffset(0)]
            public uint ParamSize;

            [FieldOffset(8)]
            public TRANSFER_DATA_STRUCT TransferData;

            [StructLayout(LayoutKind.Sequential)]
            public struct TRANSFER_DATA_STRUCT
            {
                public uint Flags;
                public int CompletionStatus;
                public IntPtr Buffer;
                public long Offset;
                public long Length;
            }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct CF_SYNC_REGISTRATION
        {
            public uint StructSize;
            public string ProviderName;
            public string ProviderVersion;
            public IntPtr SyncRootIdentity;
            public uint SyncRootIdentityLength;
            public IntPtr FileIdentity;
            public uint FileIdentityLength;
            public Guid ProviderId;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct CF_HYDRATION_POLICY
        {
            public ushort Primary;
            public ushort Modifier;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct CF_POPULATION_POLICY
        {
            public ushort Primary;
            public ushort Modifier;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct CF_SYNC_POLICIES
        {
            public uint StructSize;
            public CF_HYDRATION_POLICY Hydration;
            public CF_POPULATION_POLICY Population;
            public uint InSyncPolicy;
            public uint HardLinkPolicy;
            public uint PlaceholderManagementPolicy;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct CF_FS_METADATA
        {
            public long BasicInfo_CreationTime;
            public long BasicInfo_LastAccessTime;
            public long BasicInfo_LastWriteTime;
            public long BasicInfo_ChangeTime;
            public uint BasicInfo_FileAttributes;
            public long FileSize;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct CF_PLACEHOLDER_CREATE_INFO
        {
            public string RelativeFileName;
            public CF_FS_METADATA FsMetadata;
            public IntPtr FileIdentity;
            public uint FileIdentityLength;
            public CF_PLACEHOLDER_CREATE_FLAGS Flags;
            public int Result;
            public long CreateUsn;
        }

        [DllImport(CFAPI, CharSet = CharSet.Unicode)]
        public static extern int CfRegisterSyncRoot(
            string SyncRootPath,
            in CF_SYNC_REGISTRATION Registration,
            in CF_SYNC_POLICIES Policies,
            uint RegisterFlags);

        [DllImport(CFAPI, CharSet = CharSet.Unicode)]
        public static extern int CfUnregisterSyncRoot(string SyncRootPath);

        [DllImport(CFAPI, CharSet = CharSet.Unicode)]
        public static extern int CfConnectSyncRoot(
            string SyncRootPath,
            CF_CALLBACK_REGISTRATION[] CallbackTable,
            IntPtr CallbackContext,
            CF_CONNECT_FLAGS ConnectFlags,
            out CF_CONNECTION_KEY ConnectionKey);

        [DllImport(CFAPI)]
        public static extern int CfDisconnectSyncRoot(CF_CONNECTION_KEY ConnectionKey);

        [DllImport(CFAPI, CharSet = CharSet.Unicode)]
        public static extern int CfCreatePlaceholders(
            string BaseDirectoryPath,
            [In, Out] CF_PLACEHOLDER_CREATE_INFO[] PlaceholderArray,
            uint PlaceholderCount,
            uint CreateFlags,
            out uint EntriesProcessed);

        [DllImport(CFAPI)]
        public static extern int CfExecute(
            in CF_OPERATION_INFO OpInfo,
            ref CF_OPERATION_PARAMETERS OpParams);

        public static int RegisterSyncRoot(string path, string providerName, string version)
        {
            var reg = new CF_SYNC_REGISTRATION
            {
                StructSize = (uint)Marshal.SizeOf<CF_SYNC_REGISTRATION>(),
                ProviderName = providerName,
                ProviderVersion = version,
                ProviderId = Guid.Parse("A4644062-094D-4A23-86B6-C9E62C88998D")
            };

            var policies = new CF_SYNC_POLICIES
            {
                StructSize = (uint)Marshal.SizeOf<CF_SYNC_POLICIES>(),
                Hydration = new CF_HYDRATION_POLICY { Primary = 0 /* CF_HYDRATION_POLICY_PARTIAL */, Modifier = 0 },
                Population = new CF_POPULATION_POLICY { Primary = 1 /* CF_POPULATION_POLICY_PARTIAL */, Modifier = 0 },
                InSyncPolicy = 1,
                HardLinkPolicy = 0,
                PlaceholderManagementPolicy = 0
            };

            return CfRegisterSyncRoot(path, in reg, in policies, 0);
        }

        public static int UnregisterSyncRoot(string path)
        {
            try
            {
                return CfUnregisterSyncRoot(path);
            }
            catch
            {
                return -1;
            }
        }

        public static int CreatePlaceholder(string dirPath, string fileName, string fileIdentity, long fileSize, DateTime modifiedUtc)
        {
            byte[] identityBytes = Encoding.UTF8.GetBytes(fileIdentity);
            GCHandle pinnedIdentity = GCHandle.Alloc(identityBytes, GCHandleType.Pinned);
            try
            {
                var placeholder = new CF_PLACEHOLDER_CREATE_INFO
                {
                    RelativeFileName = fileName,
                    FsMetadata = new CF_FS_METADATA
                    {
                        FileSize = fileSize,
                        BasicInfo_FileAttributes = 0x20, // FILE_ATTRIBUTE_ARCHIVE
                        BasicInfo_LastWriteTime = modifiedUtc.ToFileTimeUtc(),
                        BasicInfo_CreationTime = modifiedUtc.ToFileTimeUtc(),
                        BasicInfo_LastAccessTime = modifiedUtc.ToFileTimeUtc(),
                        BasicInfo_ChangeTime = modifiedUtc.ToFileTimeUtc()
                    },
                    FileIdentity = pinnedIdentity.AddrOfPinnedObject(),
                    FileIdentityLength = (uint)identityBytes.Length,
                    Flags = CF_PLACEHOLDER_CREATE_FLAGS.CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC
                };

                var array = new[] { placeholder };
                int hr = CfCreatePlaceholders(dirPath, array, 1, 0, out uint processed);
                return hr;
            }
            finally
            {
                pinnedIdentity.Free();
            }
        }
    }

    /// <summary>
    /// Cross-platform verified auto-updater for ZeroDrive Windows Sync Client.
    /// Supports launch/periodic update checks, Range resume downloads, SHA-256 + ECDSA P-256 verification,
    /// atomic backup & rollback replacement, and cumulative What's New changelogs.
    /// </summary>
    public static class WindowsAutoUpdater
    {
        public const string CurrentVersion = "3.1.0";
        public const string EmbeddedPublicKeyPem =
            "-----BEGIN PUBLIC KEY-----\n" +
            "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE/JM4b2aY9Rt903bl8CDZt3kbcV5c\n" +
            "I75mfIZAxtzNsSuNxNVLGvRoZ3kwUZ5UtigFOmBfoFkAtA4CgBRi+q9OMQ==\n" +
            "-----END PUBLIC KEY-----";

        public static string GetInstalledVersion(string installDir)
        {
            try
            {
                string cfgPath = Path.Combine(installDir, "config.json");
                if (File.Exists(cfgPath))
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(cfgPath));
                    if (doc.RootElement.TryGetProperty("version", out var vEl))
                    {
                        string ver = vEl.GetString();
                        if (!string.IsNullOrWhiteSpace(ver)) return ver.Trim();
                    }
                }
            }
            catch { }
            return CurrentVersion;
        }

        public static int CompareSemver(string a, string b)
        {
            int[] pa = ParseSemver(a);
            int[] pb = ParseSemver(b);
            for (int i = 0; i < 3; i++)
            {
                if (pa[i] != pb[i]) return pa[i] > pb[i] ? 1 : -1;
            }
            return 0;
        }

        private static int[] ParseSemver(string raw)
        {
            string clean = (raw ?? "0.0.0").Trim();
            if (clean.StartsWith("v", StringComparison.OrdinalIgnoreCase)) clean = clean.Substring(1);
            clean = clean.Split('-', '+')[0];
            string[] parts = clean.Split('.');
            int[] nums = new int[3];
            for (int i = 0; i < 3 && i < parts.Length; i++)
            {
                int.TryParse(parts[i], out nums[i]);
            }
            return nums;
        }

        public static async Task RunPeriodicUpdateMonitorAsync(string apiBase, CancellationToken ct)
        {
            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string installDir = string.IsNullOrEmpty(localAppData)
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".zerodrive-win")
                : Path.Combine(localAppData, "ZeroDrive");

            try
            {
                await Task.Delay(TimeSpan.FromSeconds(5), ct);
                await CheckOnlyAsync(apiBase, installDir, quietIfUpToDate: true);

                while (!ct.IsCancellationRequested)
                {
                    await Task.Delay(TimeSpan.FromHours(4), ct);
                    await CheckOnlyAsync(apiBase, installDir, quietIfUpToDate: true);
                }
            }
            catch (OperationCanceledException) { }
            catch { }
        }

        public static async Task<int> CheckOnlyAsync(string apiBase, string installDir, bool quietIfUpToDate = false)
        {
            string currentVer = GetInstalledVersion(installDir);
            string url = $"{apiBase.TrimEnd('/')}/v1/releases/latest?platform=windows&current_version={Uri.EscapeDataString(currentVer)}";
            try
            {
                using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
                http.DefaultRequestHeaders.Add("User-Agent", $"ZeroDrive-WindowsSync/{currentVer}");
                string json = await http.GetStringAsync(url);
                using var doc = JsonDocument.Parse(json);
                var root = doc.RootElement;

                string latestVer = root.TryGetProperty("latest_version", out var lvEl) ? lvEl.GetString() : currentVer;
                bool available = root.TryGetProperty("update_available", out var uaEl) && uaEl.GetBoolean() && CompareSemver(latestVer, currentVer) > 0;

                if (available)
                {
                    Console.WriteLine($"[Updater] Update available: v{currentVer} -> v{latestVer}");
                    if (root.TryGetProperty("missed_releases", out var missedEl))
                    {
                        foreach (var rel in missedEl.EnumerateArray())
                        {
                            string rv = rel.GetProperty("version").GetString();
                            string rt = rel.GetProperty("title").GetString();
                            Console.WriteLine($"  * v{rv}: {rt}");
                        }
                    }
                    return 0;
                }

                if (!quietIfUpToDate)
                {
                    Console.WriteLine($"[Updater] ZeroDrive is up to date (v{currentVer}).");
                }
                return 0;
            }
            catch (Exception ex)
            {
                if (!quietIfUpToDate)
                {
                    Console.WriteLine($"[Updater] Offline or server unreachable ({ex.Message}). Current v{currentVer} remains active.");
                }
                return 0;
            }
        }

        public static async Task<int> PrintChangelogAsync(string apiBase, string installDir)
        {
            string currentVer = GetInstalledVersion(installDir);
            string localNotes = Path.Combine(installDir, "release-notes.json");
            string json = null;

            try
            {
                using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
                json = await http.GetStringAsync($"{apiBase.TrimEnd('/')}/v1/releases/changelog");
            }
            catch
            {
                if (File.Exists(localNotes)) json = File.ReadAllText(localNotes);
            }

            if (string.IsNullOrWhiteSpace(json))
            {
                Console.WriteLine($"ZeroDrive Windows Sync v{currentVer}");
                return 0;
            }

            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var releasesEl = root.TryGetProperty("all_releases", out var allEl) ? allEl : root.GetProperty("releases");
            Console.WriteLine($"ZeroDrive Release History (Installed: v{currentVer})");
            Console.WriteLine(new string('=', 56));
            foreach (var rel in releasesEl.EnumerateArray())
            {
                string ver = rel.GetProperty("version").GetString();
                string date = rel.GetProperty("date").GetString();
                string title = rel.GetProperty("title").GetString();
                Console.WriteLine($"\nv{ver} ({date}) — {title}");
                if (rel.TryGetProperty("highlights", out var hlEl))
                {
                    foreach (var item in hlEl.EnumerateArray())
                    {
                        Console.WriteLine($"  * {item.GetString()}");
                    }
                }
            }
            return 0;
        }

        public static bool VerifyArtifactSignature(string filePath, string version, long expectedSize, string expectedSha256, string signatureBase64, string publicKeyPem)
        {
            var fi = new FileInfo(filePath);
            if (!fi.Exists) throw new FileNotFoundException("Downloaded artifact missing.", filePath);
            if (expectedSize > 0 && fi.Length != expectedSize)
            {
                throw new InvalidDataException($"Size mismatch: got {fi.Length} bytes, expected {expectedSize} bytes.");
            }

            string actualSha256;
            using (var sha = SHA256.Create())
            using (var stream = File.OpenRead(filePath))
            {
                byte[] hash = sha.ComputeHash(stream);
                actualSha256 = BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
            }

            string normalizedExpected = (expectedSha256 ?? "").Trim().ToLowerInvariant();
            if (string.IsNullOrEmpty(normalizedExpected) || actualSha256 != normalizedExpected)
            {
                throw new CryptographicException($"SHA-256 verification failed ({actualSha256} != {normalizedExpected}).");
            }

            byte[] sigBytes = Convert.FromBase64String((signatureBase64 ?? "").Trim());
            string canonical = $"zerodrive-release-v1:windows:{version}:{actualSha256}:{fi.Length}";
            byte[] payloadBytes = Encoding.UTF8.GetBytes(canonical);

            using var ecdsa = ECDsa.Create();
            ecdsa.ImportFromPem((publicKeyPem ?? EmbeddedPublicKeyPem).Trim());
            bool valid = ecdsa.VerifyData(payloadBytes, sigBytes, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
            if (!valid)
            {
                throw new CryptographicException("ECDSA P-256 signature verification failed!");
            }

            return true;
        }

        private static async Task DownloadWithResumeAsync(HttpClient http, string url, string partPath, long expectedSize)
        {
            const int maxAttempts = 3;
            for (int attempt = 1; attempt <= maxAttempts; attempt++)
            {
                try
                {
                    long existing = File.Exists(partPath) ? new FileInfo(partPath).Length : 0;
                    if (expectedSize > 0 && existing == expectedSize) return;
                    if (expectedSize > 0 && existing > expectedSize)
                    {
                        File.Delete(partPath);
                        existing = 0;
                    }

                    using var req = new HttpRequestMessage(HttpMethod.Get, url);
                    if (existing > 0)
                    {
                        req.Headers.Range = new RangeHeaderValue(existing, null);
                    }

                    using var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead);
                    if ((int)resp.StatusCode == 416 && expectedSize > 0 && existing == expectedSize)
                    {
                        return;
                    }
                    resp.EnsureSuccessStatusCode();

                    bool isResume = resp.StatusCode == HttpStatusCode.PartialContent && existing > 0;
                    FileMode mode = isResume ? FileMode.Append : FileMode.Create;

                    using var inStream = await resp.Content.ReadAsStreamAsync();
                    using var outStream = new FileStream(partPath, mode, FileAccess.Write, FileShare.None);
                    await inStream.CopyToAsync(outStream);
                    return;
                }
                catch when (attempt < maxAttempts)
                {
                    await Task.Delay(attempt * 1500);
                }
            }
        }

        public static async Task<int> DownloadAndApplyUpdateAsync(string apiBase, string installDir, bool simulateBadSha, bool simulateBadSig)
        {
            string currentVer = GetInstalledVersion(installDir);
            string checkUrl = $"{apiBase.TrimEnd('/')}/v1/releases/latest?platform=windows&current_version={Uri.EscapeDataString(currentVer)}";
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
            http.DefaultRequestHeaders.Add("User-Agent", $"ZeroDrive-WindowsSync/{currentVer}");

            string json = await http.GetStringAsync(checkUrl);
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            string latestVer = root.GetProperty("latest_version").GetString();
            bool available = root.GetProperty("update_available").GetBoolean() && CompareSemver(latestVer, currentVer) > 0;
            if (!available)
            {
                Console.WriteLine($"[Updater] Already on latest version v{currentVer}.");
                return 0;
            }

            var artifact = root.GetProperty("platform_artifact");
            string filename = artifact.GetProperty("filename").GetString();
            string dlUrl = artifact.GetProperty("url").GetString();
            long size = artifact.GetProperty("size").GetInt64();
            string sha256 = simulateBadSha ? new string('0', 64) : artifact.GetProperty("sha256").GetString();
            string sig = simulateBadSig ? Convert.ToBase64String(Encoding.UTF8.GetBytes("bad_signature")) : artifact.GetProperty("signature").GetString();
            string pubKey = root.TryGetProperty("public_key", out var pkEl) && !string.IsNullOrWhiteSpace(pkEl.GetString())
                ? pkEl.GetString()
                : EmbeddedPublicKeyPem;

            var missedList = new List<string>();
            if (root.TryGetProperty("missed_releases", out var missedEl))
            {
                foreach (var rel in missedEl.EnumerateArray())
                {
                    missedList.Add($"v{rel.GetProperty("version").GetString()}: {rel.GetProperty("title").GetString()}");
                }
            }

            string partPath = Path.Combine(Path.GetTempPath(), $"{filename}.part.{Guid.NewGuid():N}");
            string stageDir = Path.Combine(Path.GetTempPath(), $"zerodrive-win-stage-{Guid.NewGuid():N}");
            string backupDir = $"{installDir.TrimEnd('\\', '/')}.backup.{Guid.NewGuid():N}";

            try
            {
                Console.WriteLine($"[Updater] Downloading {filename} (v{currentVer} -> v{latestVer})...");
                await DownloadWithResumeAsync(http, dlUrl, partPath, size);

                VerifyArtifactSignature(partPath, latestVer, size, sha256, sig, pubKey);
                Console.WriteLine("[Updater] Cryptographic SHA-256 + ECDSA P-256 verification PASSED.");

                Directory.CreateDirectory(stageDir);
                ZipFile.ExtractToDirectory(partPath, stageDir, overwriteFiles: true);

                // Backup existing install directory for atomic rollback
                if (Directory.Exists(installDir))
                {
                    CopyDirectory(installDir, backupDir, overwrite: true);
                }

                // Read existing user config to preserve sync_root and api_base
                string existingSyncRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "ZeroDrive");
                string existingApiBase = apiBase;
                string cfgPath = Path.Combine(installDir, "config.json");
                if (File.Exists(cfgPath))
                {
                    try
                    {
                        using var cfgDoc = JsonDocument.Parse(File.ReadAllText(cfgPath));
                        if (cfgDoc.RootElement.TryGetProperty("sync_root", out var srEl) && !string.IsNullOrWhiteSpace(srEl.GetString()))
                            existingSyncRoot = srEl.GetString();
                        if (cfgDoc.RootElement.TryGetProperty("api_base", out var abEl) && !string.IsNullOrWhiteSpace(abEl.GetString()))
                            existingApiBase = abEl.GetString();
                    }
                    catch { }
                }

                try
                {
                    Directory.CreateDirectory(installDir);
                    CopyDirectory(stageDir, installDir, overwrite: true, skipFiles: new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "config.json", "update-state.json" });

                    string updatedConfig = JsonSerializer.Serialize(new
                    {
                        sync_root = existingSyncRoot,
                        api_base = existingApiBase,
                        version = latestVer,
                        previous_version = currentVer,
                        updated_at = DateTime.UtcNow.ToString("o")
                    }, new JsonSerializerOptions { WriteIndented = true });
                    File.WriteAllText(cfgPath, updatedConfig, Encoding.UTF8);

                    var sb = new StringBuilder();
                    sb.AppendLine($"# ZeroDrive Changelog (Installed: v{latestVer})");
                    if (root.TryGetProperty("all_releases", out var allEl))
                    {
                        foreach (var rel in allEl.EnumerateArray())
                        {
                            sb.AppendLine($"\n## v{rel.GetProperty("version").GetString()} ({rel.GetProperty("date").GetString()}) — {rel.GetProperty("title").GetString()}");
                            if (rel.TryGetProperty("highlights", out var hlEl))
                            {
                                foreach (var h in hlEl.EnumerateArray())
                                {
                                    sb.AppendLine($"- {h.GetString()}");
                                }
                            }
                        }
                    }
                    File.WriteAllText(Path.Combine(installDir, "CHANGELOG.md"), sb.ToString(), Encoding.UTF8);

                    string updateStateJson = JsonSerializer.Serialize(new
                    {
                        last_checked_at = DateTime.UtcNow.ToString("o"),
                        previous_version = currentVer,
                        last_seen_changelog_version = latestVer,
                        missed_releases = missedList
                    }, new JsonSerializerOptions { WriteIndented = true });
                    File.WriteAllText(Path.Combine(installDir, "update-state.json"), updateStateJson, Encoding.UTF8);

                    if (Directory.Exists(backupDir))
                    {
                        Directory.Delete(backupDir, recursive: true);
                    }
                }
                catch
                {
                    if (Directory.Exists(backupDir))
                    {
                        if (Directory.Exists(installDir)) Directory.Delete(installDir, recursive: true);
                        Directory.Move(backupDir, installDir);
                    }
                    throw;
                }

                Console.WriteLine($"[Updater] PASS: Upgraded {installDir} from v{currentVer} to v{latestVer}.");
                Console.WriteLine($"[Updater] What's New ({missedList.Count} release(s)): {string.Join(" | ", missedList)}");
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[Updater] Rejected / failed safely (v{currentVer} preserved): {ex.Message}");
                return 1;
            }
            finally
            {
                try { if (File.Exists(partPath)) File.Delete(partPath); } catch { }
                try { if (Directory.Exists(stageDir)) Directory.Delete(stageDir, recursive: true); } catch { }
            }
        }

        private static void CopyDirectory(string sourceDir, string destDir, bool overwrite, HashSet<string> skipFiles = null)
        {
            Directory.CreateDirectory(destDir);
            foreach (string file in Directory.GetFiles(sourceDir))
            {
                string name = Path.GetFileName(file);
                if (skipFiles != null && skipFiles.Contains(name)) continue;
                File.Copy(file, Path.Combine(destDir, name), overwrite);
            }
            foreach (string dir in Directory.GetDirectories(sourceDir))
            {
                string name = Path.GetFileName(dir);
                CopyDirectory(dir, Path.Combine(destDir, name), overwrite, skipFiles);
            }
        }
    }
}
