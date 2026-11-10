# ZeroDrive verification on 2026-11-09

## Result

Another agent implemented CLI repairs in commit `d76160f` and made later CLI, MCP and documentation changes. The current repository head is `40e19d9`. The original global skill and routing request is still incomplete. This check changed no CLI source, installation, skill or routing instructions.

## CLI checks

Live checks passed for missing cloud files with head and tail selection, an empty local file, exact binary and CRLF byte output, formatted listing of a filename containing a semicolon, and rejection of a negative head count. Direct cloud reads retrieved the drive root AGENTS.md, ROUTER.md and CONTEXT.md.

Isolated checks of the actual classifier now resolve `/` to the vault and keep `My Drive-backup` outside the mount. A simulated missing VFS response now produces an unknown queue state. Current source also has explicit shortcut preconditions and nonzero results for incomplete shortcut creation.

An isolated child process failure test still returned success for both tail and byte reads after partial output. The simulated storage process returned exit code 7, but both CLI calls returned 0. These branches return before checking the process failure. No live failure or source move was induced.

The installed local CLI matches repository source with SHA256 `a09cf93587468cfcd4ac009bb10883fa77ef7955bf3b681a2354ef1750bc17ea`. The Mac mini binary has SHA256 `03e9ea10f2221aaa0aae23a307045e9fd30f1ae1e9e5a9a95430bfcf0f02469e`. Both report version 1.0.1, so the version string cannot establish that both Macs run the same code.

## Mount mismatch

The home ZeroDrive link now points to `/Users/Naegele/.zerodrive-mount/My Drive`. The file `/Users/Naegele/ZeroDrive/ROUTER.md` exists. The former address `/Users/Naegele/ZeroDrive/My Drive/ROUTER.md` does not.

The CLI still sets MOUNT_DIR to the former address. Its classifier treats `/Users/Naegele/ZeroDrive/Course` as local, even though it is under the current mounted vault. Its shortcut creation and reported mount path also use the old address. The CLI manual and drive router still document the old address.

## Global instructions and skill

1. Home ROUTER.md still routes cloud collections through Fabric. Home CONTEXT.md still explicitly tells agents to use Fabric paths and the Fabric path checker.
2. All seven inspected home shortcuts still point into Fabric. These are `_CONTENT`, `_SKILLS`, `_SORT`, `_BUSINESS`, `_LIBRARY`, `_PERSONAL` and `_CAPTURES`.
3. The drive CONTEXT.md still contains those Fabric instructions. Its ROUTER.md still has the old mount address and the inaccurate claim that line slices are cloud byte ranges.
4. Home AGENTS.md has no ZeroDrive skill entry. The ZeroDrive project still lacks AGENTS.md and CONTEXT.md. Its STATUS.md still lists CLI creation as future work despite the installed implementation.
5. No ZeroDrive skill was found in the global `.agents/skills`, `.codex/skills` or `.claude/skills` directories by name or matching SKILL.md content. Their direct symlink targets were also inspected. The cloud `_SKILLS` root listing contains no ZeroDrive skill folder. The new agent quickstart documents a built in MCP skill resource, and deploy/worker.js contains `use-zerodrive-vault` as that resource. This is a different discovery mechanism. That hosted resource was not tested in this check.
6. No ZeroDrive alignment mechanism was found in the inspected project instructions, global entry files or system decision entries. This was a scoped check, not a scan of every scheduler on the Mac.

## Evidence limits and next action

Only selected cloud files were read. This does not prove every file in every collection is readable. No cloud files were created or deleted, no transfers or source moves were run, and no public links were generated.

Disposable local fixtures remain in `/var/folders/hn/cqdk966s5r79c3fp9fp9p5lh0000gn/T/zd-check-2026-11-09-0349cwf8`.

Finish the remaining CLI failure handling and mount agreement, reconcile deployment between Macs, then install the global skill and repair the routing documents as the separate requested workstream. Discuss ongoing alignment after those repairs as Andrew requested.
