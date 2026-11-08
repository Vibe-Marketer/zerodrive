# CLI verification on 2026-11-07

## Result

Version 1.0.1 at commit `19d3d39` fixes several original defects but does not pass the full audit. This record covers the CLI and its manual only. No CLI source, installation, routing document or skill was changed during this verification.

The repository source and installed binaries on both Macs have SHA256 `3897b02ca2e5ea1bc95e1ecf7f72559ee83b7bf9fbbb83cc555c0d6bdf364fd7`. Both installations report version 1.0.1. The repository was clean before verification. On the Mac mini, an interactive login shell resolves `zd` to `/Users/admin/.local/bin/zd`. A plain noninteractive SSH shell did not resolve it, so remote automation should use the full path or set PATH explicitly.

## Checks that passed

1. Unknown command `zd stauts` returned exit code 2.
2. `zd raw not-a-command` propagated the engine's exit code 2.
3. Plain `zd cat` on a missing cloud object returned exit code 1.
4. `zd cat ROUTER.md --head 3` returned the expected text and exited successfully.
5. `zd ls _SKILLS/_BRANDING -R --json` returned 12 entries, including 11 nested paths.
6. Copying a disposable local file into an existing local folder succeeded and preserved its bytes. A missing explicit local source returned exit code 1.
7. `zd refresh Course --json` returned `My Drive/Course` with status `OK`.
8. Current live status reported the mount and daemon online. This is a current observation, not proof of all failure cases.
9. An isolated move test left a remaining source file alone and did not call directory removal.

## Remaining defects reproduced

| Finding | Evidence | Required correction |
|---|---|---|
| Filtered reads conceal missing files | Live cloud reads of `__zd_audit_missing_20261107__.txt` with `--head 5`, `--lines 1-5`, and `--tail 5` each returned exit code 0 with no error | Distinguish deliberate early termination from read failure. Tail must also check the child exit status |
| Byte output is not preserved | A local four byte binary fixture made `cat --bytes 0-3` raise `UnicodeDecodeError`. A ten byte CRLF fixture returned eight bytes with LF endings | Keep byte range output binary throughout the subprocess and stdout path |
| Vault root syntax selects local root | Calling the actual classifier with `/` returned `LOCAL`, `/`, true | Define and enforce root semantics consistently with the manual. Do not silently run cloud queries against the local root |
| Mount detection matches sibling folders | `/Users/Naegele/ZeroDrive/My Drive-backup/file.txt` classified as a remote path containing `../My Drive-backup/file.txt` | Compare path components rather than string prefixes |
| Missing VFS statistics appear idle | An isolated test with successful `core/stats` and unavailable `vfs/stats` returned `Idle (0 pending VFS uploads)` | Require valid VFS queue fields before reporting an idle queue. Otherwise report unknown |
| Incomplete shortcut operation returns success | An isolated move test with a leftover file returned exit code 0 after declining to create the shortcut | Return a distinguishable incomplete operation result when the requested shortcut is absent |
| Shortcut creation accepts an incompatible remote | An isolated move to `other_remote:folder` attempted a shortcut targeting `/Users/Naegele/ZeroDrive/My Drive/other_remote:folder` | Reject unsupported shortcut destinations before transferring any source data |
| Refresh rewrites valid names and mishandles endpoint syntax | Isolated calls converted `MAIN/My Drive notes` to `My Drive/MAIN/ notes`, `vault:Course` to `My Drive/vault:Course`, and the mounted Course path to `My Drive/Users/Naegele/ZeroDrive/Course` | Normalize supported endpoints through one resolver and preserve literal folder names |
| Formatted listing crashes on a legal filename | Listing a disposable directory containing `semi;colon.txt` raised `ValueError` when parsing its size | Build formatted output from structured listing data |
| Numeric options lack validation | `cat --head -1` returned success with no output. `cat --tail -1` raised an uncaught `ValueError` | Validate ranges and counts before launching the engine and return an argument error |

The isolated checks imported the actual CLI and replaced only external operations with test doubles. No real source folder was moved or removed, no other remote was contacted, and no shortcut ledger was changed by those checks.

## Additional code and manual findings

1. The move failure message says `Source files untouched`. A multiple file move can transfer and remove some files before another fails. The message must describe partial progress without promising rollback. This was found in code, not reproduced against user data.
2. A shortcut or ledger write exception is printed but the move still returns success. Local to local moves silently ignore `--symlink`. These need explicit supported operation checks and outcome reporting.
3. `cat` still reads stderr only after streaming stdout. A child producing enough error output can block on that pipe. It also waits for another line before recognizing a reached head or line limit. These remaining hang risks were identified from code, not reproduced in this audit.
4. The manual documents `--no-color` under status, but `zd status --no-color` returns exit code 2. The accepted position is before the subcommand.
5. The manual says `find --json` returns an array. The implementation returns an object containing `pattern`, `target`, `count`, and `matches`.
6. The manual omits `tree`, describes `os.path.islink()` as proving an active shortcut, and says an idle upload queue means the cache is clear. A symlink can be dangling, and cached data can remain with no pending uploads.
7. The exit code table says engine codes greater than 2 apply only to `raw`, but several normal commands also return engine codes unchanged.
8. The parser does not enforce the manual's stated sharing expiry range. Share accessibility and actual expiry were not tested.

## Scope and next action

Disposable local fixtures remain at `/var/folders/hn/cqdk966s5r79c3fp9fp9p5lh0000gn/T/zd-cli-audit-66ajfm1z`. No cloud test content was created or deleted. Cloud to cloud copies, live moves, public sharing, and broad recursive refreshes were not repeated. Their earlier reported tests remain statements from the supplied repair report.

Repair the remaining CLI defects and rerun these regression cases before describing the CLI as fully repaired or building the global skill around its behavior. Keep routing cleanup separate from this repair list.
