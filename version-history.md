# Version History

## v1.4.4 — 2026-08-20

- Added explicit `.gitkeep` placeholders to every structural directory that may otherwise be empty.
- Added `local/paths/.gitkeep` so the configuration directory remains represented even if example files are removed in a downstream fork.
- Startup now recreates `.gitkeep` placeholders for `cloud-IN/`, `transferred/`, `logs/`, `var/`, `var/transfers/` and `local/paths/`.
- Updated the README repository tree to show the placeholder files explicitly.

## v1.4.3 — 2026-08-20

- Added live spinner/count/percentage feedback while the rename dry-run builds its recursive pre-flight plan.
- Added an early folder-context confirmation before the expensive Folder Move recursive scan begins.
- The context confirmation shows the exact `YYYY-MM-00 - <context>` folder template and allows immediate edit or cancel.
- Added progress feedback while Folder Move builds its recursive pre-flight plan.
- Retained the second full-preview confirmation before any file movement, providing both an early typo check and a final safety gate.
- Added live scanning feedback to `s) Show import / transfer status` so large imports no longer appear idle while statistics are calculated.
- Optimised import-status calculation to collect recursive file count, byte total, maximum depth and top-level folder counts in a single import-tree pass.
- Optimised transferred-status calculation to collect file and byte totals in a single pass.

## v1.4.2 — 2026-08-20

- Added recursive discovery of cloud-photo files beneath the configured import folder.
- Extracted cloud-download wrapper directories no longer need to be manually flattened before processing.
- Rename now operates in place inside nested source folders while preserving the existing ISO filename convention.
- Existing top-level Cloud-to-NAS monthly archive folders are skipped by recursive prepare stages.
- Folder Move now recursively gathers ISO-renamed files into top-level `YYYY-MM-00 - <context>` folders.
- Added full pre-flight collision detection for the flattened destination set, including duplicate final filenames originating from different subfolders.
- Collision matching is case-insensitive and blocks the entire move; Cloud-to-NAS never overwrites or invents a suffix.
- Folder Move preview now reports recursive file count, input groups, maximum nesting depth and monthly destination counts.
- Successfully emptied source wrapper directories are removed using `rmdir`; non-empty directories are left untouched.
- Import status now reports recursive file counts, top-level folders and maximum nesting depth, and shows per-folder file counts in its preview.
- Recursive import scanning ignores `.gitkeep`, `.DS_Store`, `Thumbs.db`, AppleDouble `._*` files and `__MACOSX/`.
- Recursive scanning continues to avoid following symlinked directories.

## v1.4.1 — 2026-08-20

- Added `b) Batch manager` to browse every recorded transfer batch, not only the last transfer.
- Batch manager shows transfer ID, state, file count, size and NAS destination.
- Verified historical batches can be re-verified or archived from the batch manager.
- Archived batches can be selectively deleted one at a time.
- Option 7 now selects a single eligible archived batch instead of deleting all archived batches together.
- Selective permanent deletion still requires typing the exact word `DELETE`.
- Strengthened deletion safety so neither the configured import source, built-in `cloud-IN`, nor anything beneath those paths can be a deletion target.
- Re-verification failure of an archived batch changes it to `ARCHIVED_UNVERIFIED`, blocking deletion until it passes again.
- Added a fresh standard verification immediately before a verified batch is moved into `transferred/`.
- Hardened file-date extraction by reading GNU `stat` epoch time (`%Y`) and converting it with `LC_ALL=C date`.
- Added compact `| / - \` spinner/progress feedback for large real rename, monthly move and post-transfer archive operations.
- Retained explicit `STATE_*` variables for readability and auditability.

## v1.4.0 — 2026-08-20

- Added persistent human-readable transfer logs under `logs/`.
- Added machine-readable transfer state and exact folder manifests under `var/transfers/`.
- Every rsync transfer now records source, destination, timestamps, counts, byte total and exit status.
- Added automatic standard post-transfer verification using an rsync dry run.
- Added optional deep checksum verification for important archives.
- Added menu option 5 to verify the last recorded transfer on demand.
- Added Stage 3 post-transfer workflow.
- Added option 6 to move only manifest-confirmed verified folders into `transferred/<transfer-id>/`.
- New/unrelated files in the import directory are left untouched by post-transfer movement.
- Added option 7 to permanently delete only state-confirmed `ARCHIVED` batches.
- Permanent deletion requires the exact confirmation word `DELETE` and displays a red warning.
- Added explicit path-safety checks around deletion.
- Cloud-to-NAS will never delete the configured import/source directory or `cloud-IN`.
- Transfer logs, manifests and state records are retained after local transferred files are deleted.
- Expanded `s) Show import / transfer status` with import counts, transferred-batch totals and last-transfer state.
- Added `l) View transfer logs`.
- Reorganised the main menu into Prepare, Transfer and Post-transfer stages.
- Moved configuration actions to letter shortcuts (`c`, `r`, `t`).

## v1.3.3 — 2026-08-20

- Reworked rename dry-run output into a concise pre-flight summary for large photo imports.
- Added files-scanned, would-rename, already-renamed, ignored, collision and error counts.
- Added rename date range and per-month file counts.
- Added a chronologically sorted preview of the first 10 proposed rename changes.
- Added full rename-plan files under `var/`, with interactive view and `less` paging options.
- Added full collision/error attention output while keeping normal dry-run output concise.
- Added folder-move pre-flight before any files are moved.
- Added monthly destination-folder counts and a first-10 move preview.
- Added `e) Edit folder context` so a typo can be corrected without leaving the move workflow.
- Added full folder-move plans under `var/`, with view and pager options.
- Folder-move collisions now block execution rather than allowing a partial move.
- Added a green `[Complete]` confirmation after a successful folder move.
- Added compact move progress rather than printing hundreds or thousands of individual move lines.

## v1.3.2 — 2026-08-20

- Improved first-time NAS validation so failed destinations can be corrected without leaving setup.
- Added an in-place recovery menu for failed destinations: edit, retry, remove, or keep unverified.
- Edited NAS destinations are saved and immediately retested.
- Moved the `Configuration complete` confirmation to the end of the first-time validation workflow.
- Added `s) Show import folder` to the main menu.
- Added a read-only import-folder view with file and folder counts.
- Suppressed `cloud-IN/.gitkeep` from the import-folder display.
- Excluded `.gitkeep` from rename and folder-move operations.

## v1.3.1 — 2026-08-20

- Added green `[Verified]` confirmation for successful SSH path checks.
- Added green `[Verified]` confirmation for successful rsync dry-run simulations.
- Added a per-destination `[Verified]` message after both connection checks pass.
- Added a green `[Verified]` summary when all configured destinations pass.
- Made the main menu section headings bold to match the Hasher-style interface.

## v1.3.0 — 2026-08-20

- Added release metadata to the banner: version, month/year and James Wintermute.
- Added dynamic host and Bash-version information to the banner.
- Replaced personal NAS examples with generic `user@10.0.0.2:/...` examples suitable for a public repository.
- Added validation of NAS destination syntax during first-time setup.
- Added an optional NAS path test at the end of first-time setup.
- Added SSH preflight checks for connectivity, remote-path existence and writability.
- Added a safe `rsync --dry-run` simulation using a temporary local probe file.
- Added menu option 7 to rerun NAS destination tests at any time.
- Added rsync protected-argument mode (`-s`) for safer handling of paths containing spaces.
- Updated README and example configuration for the new connection-test workflow.

## v1.2.0 — 2026-08-20

- Added a default `cloud-IN/` photo inbox relative to the application directory.
- First-time run now creates `cloud-IN/` automatically.
- Source-path prompt is pre-filled with the default inbox.
- Added interactive Bash Readline path editing and Tab completion.
- Users can still enter any alternative local source directory.
- Added an offer to create a custom source directory when it does not already exist.
- Added Cloud-to-NAS ASCII-art banner.
- Added Git protection for files placed in `cloud-IN/`.

## v1.1.0 — 2026-08-20

- Added first-time-run configuration wizard.
- Added support for one or more NAS destinations.
- Added numbered destination selection before rsync.
- Added `Show configured paths` menu option.
- Added `Reconfigure paths` menu option.
- Added automatic migration from the v1.0.0 `nas-destination.txt` configuration file.
- Added public-repository-safe example path files.
- Updated project documentation for multi-destination configuration.

## v1.0.0 — 2026-08-20

Initial release.

- Added ISO date prefixing for loose archive files.
- Added dry-run rename mode.
- Added uppercase extension normalisation.
- Added monthly archive folder organisation using `YYYY-MM-00 - <context>`.
- Added configurable cloud-source context such as ProtonDrive or iCloud.
- Added rsync transfer to a configured NAS destination.
- Added collision protection for rename and folder move operations.
- Added local path configuration under `local/paths/`.
- Added README, version history and GNU GPLv3-or-later licensing.
