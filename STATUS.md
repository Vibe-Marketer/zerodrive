# ZeroDrive status

## Mount and terminal access checked November 6, 2026

Andrew asked whether ZeroDrive can live under his home folder and support terminal access.

The live macOS mount table showed `localhost:/` mounted through NFS at `/Users/Naegele/.zerodrive-mount`. `/Users/Naegele/ZeroDrive` is a symbolic link to that mount. A fresh zsh process successfully entered both `/Users/Naegele/ZeroDrive` and `/Users/Naegele/ZeroDrive/My Drive` and listed their contents. The latter contained the cloud collections.

`ZeroDriveProject/Sources/Core/RcloneDaemonSupervisor.swift` defines these paths, creates the link, mounts with `nobrowse` and pins the My Drive folder into Finder Favorites. The Finder extension also references the hidden mount. Moving the mount itself would require coordinating those references and the sleep and recovery paths.

Terminal access is working with the existing layout. No mount, app, transfer or cloud data was changed during this assessment. Existing uncommitted work was preserved. This was a focused mount assessment, not a complete code audit or verification of the reported storage savings and RAM usage.

Use `cd "$HOME/ZeroDrive/My Drive"` to enter the cloud collections. No repair is needed for the terminal access tested here. A direct mount at the visible path remains an optional implementation change if Andrew wants that appearance.


## Storage assessment on November 6, 2026

Andrew asked what terminal access means for video editing, coding agents and the claim that ZeroDrive solves Mac storage limits. This was a read only assessment of runtime settings, selected source and public documentation. No transfers, settings, mount state or cloud objects were changed.

The live mount table showed NFS at `/Users/Naegele/.zerodrive-mount`. The running bundled rclone used `serve nfs`, `--vfs-cache-mode=full`, `--cache-dir=/Users/Naegele/.zerodrive-cache`, `--vfs-cache-max-size=250G`, `--vfs-write-back=15s` and `--vfs-cache-max-age=24h`. Its command line had no `--vfs-cache-min-free-space` setting. A filesystem walk measured about 9.72 GiB allocated in that cache. `df -h /System/Volumes/Data` reported about 98 GiB available. These are changing snapshots.

`ZeroDriveProject/Sources/Core/RcloneDaemonSupervisor.swift` lines 170 to 198 matched the cache settings and enabled `--vfs-links`. The mount command at line 220 used `nolocks`. `SpoolAndGuardManager.swift` has disk space warnings and checks for its drop workflow. This inspection does not establish an enforced reserve for arbitrary writes from editors or terminal tools. Its `purgeLocally` function at line 219 calls file removal on `item.localCachePath`, which elsewhere can point into the mounted drive. Whether this action can delete a remote object needs a focused review using disposable data before presenting it as safe local cache removal. No deletion test was run.

The supported interpretation is a local filesystem interface to cloud objects, with local caching. R2 supplies storage rather than execution or RAM. Entering a folder proves navigation, not complete editor, build, database, file locking, upload durability or recovery compatibility. No full video project, code build, disconnect or restart test was performed. Provider upload completion and actual reclaimed storage were not verified.

[Official rclone documentation](https://rclone.org/commands/rclone_mount/) describes partial read caching, delayed uploads and soft cache limits that can be exceeded. [NFS documentation](https://rclone.org/commands/rclone_serve_nfs/) describes the experimental NFS implementation. [Cloudflare pricing](https://developers.cloudflare.com/r2/pricing/) lists Standard storage at $0.015 per GB month, request charges and free direct egress. [Mountain Duck](https://mountainduck.io/) establishes an existing product category for mounted cloud storage.

Next work, if requested, is a disposable project test in Andrew's actual editor. Measure cold and cached playback, save and cloud readback, cache growth, free disk space, export and recovery. Retain local originals and avoid changing the active transfer. Evaluate the cache budget and local purge behavior before making a general promise that the Mac cannot fill up.
