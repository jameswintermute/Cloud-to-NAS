# Cloud-to-NAS

Cloud-to-NAS is a Bash utility for preparing cloud photo exports, organising them into an ISO-dated archive, transferring them to a NAS with `rsync`, verifying the transfer, and safely retiring the local import copy.

It is designed for phone-photo archives downloaded from services such as Proton Drive, iCloud and similar cloud backup services.

## Workflow

Cloud-to-NAS uses three stages.

### Stage 1 — Prepare

**1) Rename — dry run**

Performs a non-destructive pre-flight. Large imports are summarised rather than dumped to the terminal. A live spinner/count/percentage is shown while the recursive rename plan is analysed, then the screen shows counts, date range, files by month and the first 10 proposed changes. The full plan is saved under `var/` for optional inspection.

**2) Rename**

Recursively scans the import inbox, including wrapper folders created by extracted cloud downloads. Files are renamed **in place** using their filesystem modification date and the extension is normalised to uppercase. Existing Cloud-to-NAS monthly archive folders are skipped. Large runs use a compact spinner, count and percentage rather than printing thousands of rename lines:

```text
IMG_23456.jpg
-> 2026-06-06-IMG_23456.JPG
```

**3) Folder Move — month per year**

Prompts for a context such as `ProtonDrive` or `iCloud` and immediately asks the user to confirm the exact `YYYY-MM-00 - <context>` template before performing the more expensive recursive scan. After confirmation, a live pre-flight progress indicator is shown while ISO-renamed files are discovered and checked. The resulting preview must then be confirmed before any files move. Nested export wrappers are deliberately flattened into the monthly archive folders. A mistyped context can be edited either before or after the full preview.

```text
2026-08-00 - ProtonDrive/
```

The day is deliberately `00` because the folder represents a month rather than a single day.


### Recursive cloud exports

Cloud providers often extract downloads inside a wrapper directory, for example:

```text
cloud-IN/
└── Download 2026-08-20T13-35-14-564Z/
    ├── IMG_1234.JPG
    └── IMG_1235.JPG
```

Cloud-to-NAS processes these without requiring the user to move files up a level. Rename operates in place, then Folder Move gathers the renamed files into top-level monthly folders. Empty wrapper directories are removed only when `rmdir` confirms they are genuinely empty.

The recursive scanner ignores `.gitkeep`, `.DS_Store`, `Thumbs.db`, AppleDouble `._*` files and `__MACOSX/`, and does not follow symlinked directories.

The **Show import / transfer status** view also scans recursively. For large archives it displays a live spinner and running file count while calculating file totals, size and nesting depth, rather than appearing idle during the scan.

Before flattening nested files, Folder Move checks the complete planned destination set. If two files from different subfolders would produce the same final filename, the move is blocked and both source paths are shown. Cloud-to-NAS never overwrites a collision or invents a suffix automatically.

### Stage 2 — Transfer

**4) Rsync to destination NAS**

Presents the configured NAS destinations as a numbered menu and transfers the prepared monthly folders using archive mode and protected arguments:

```bash
rsync -avhs --progress
```

Every real transfer receives a transfer ID and records:

- source and NAS destination
- start/completion time
- file, folder and byte counts
- rsync exit status
- exact monthly-folder manifest
- verification state
- post-transfer archive/delete state

Human-readable logs are stored under `logs/`. Machine-readable transfer state and manifests are stored under `var/transfers/`.

After rsync returns successfully, Cloud-to-NAS automatically runs a **standard verification** using an rsync dry run. No pending size/timestamp changes means the batch is marked `[Verified]`.

The user may optionally perform a slower deep checksum verification.

**5) Verify last transfer**

Reruns verification against the NAS. Two modes are available:

1. Standard — size/timestamp comparison.
2. Deep — checksum comparison.

A transfer must be verified before it is eligible for the post-transfer archive stage.

### Stage 3 — Post-transfer

**6) Move verified transfer to `transferred/`**

Moves only the top-level folders recorded in the successful transfer manifest. The batch is placed under:

```text
transferred/<transfer-id>/
```

For example:

```text
transferred/20260820-143503/
├── 2026-01-00 - ProtonDrive/
├── 2026-02-00 - ProtonDrive/
└── 2026-03-00 - ProtonDrive/
```

Before the move, Cloud-to-NAS runs a fresh standard NAS verification. This provides a local safety buffer before deletion. Items outside the recorded transfer folders are left untouched.

**7) DELETE selected archived batch**

Lists only verified `ARCHIVED` batches whose paths are safely beneath the application's `transferred/` directory. The user selects one batch at a time for deletion.

Deletion is deliberately difficult:

- the warning is displayed in red
- the selected batch, file count and size are shown
- the user must type the exact word `DELETE`
- any other input cancels

**b) Batch manager**

Browses all recorded transfer states, newest first. From a selected batch the user can inspect its state, manifest and log, re-run verification, archive an older verified batch, or selectively delete a verified archived batch.

If an archived batch fails a later re-verification it becomes `ARCHIVED_UNVERIFIED`; deletion remains blocked until verification passes again.

**Cloud-to-NAS never deletes files directly from `cloud-IN` or from the configured source path.** The deletion routine only targets verified, archived batch directories under `transferred/`.

Transfer logs, state files and manifests are retained after local photographs are deleted, providing an audit trail of what was transferred and verified.

## First-time run

On first launch the application creates a default photo inbox beside the script:

```text
cloud-IN/
```

The source prompt is pre-filled with this directory. Press **Enter** to accept it or edit/type another local path. Interactive Bash terminals support normal Tab completion.

One or more NAS destinations can then be configured using SSH/rsync syntax:

```text
user@host:/absolute/path
```

Public-safe examples:

```text
user@10.0.0.2:/user/Photographs/Personal
user@10.0.0.2:/family/Photographs
```

The first-time wizard can test each destination with:

1. SSH connection, directory-existence and writability checks.
2. An `rsync --dry-run` probe that writes nothing to the NAS.

Failed destinations can be edited, retried, removed or deliberately kept unverified without leaving setup.

## Menu

```text
Stage 1 - Prepare

  1) Rename - dry run
  2) Rename
  3) Folder Move - month per year

Stage 2 - Transfer

  4) Rsync to destination NAS
  5) Verify last transfer

Stage 3 - Post-transfer

  6) Move verified transfer to transferred/
  7) DELETE selected archived batch
  b) Batch manager

Configuration

  c) Show configured paths
  r) Reconfigure paths
  t) Test NAS destination paths

Other

  s) Show import / transfer status
  l) View transfer logs

  0) Exit
```

## Import and transfer status

Option `s` gives a read-only summary of:

- the configured import directory
- recursive file/folder counts, maximum nesting depth and size
- the first 20 top-level import entries, including file counts for nested folders
- the `transferred/` staging area
- the last recorded transfer destination, status and verification result

`.gitkeep` and common cloud/macOS extraction metadata are hidden from normal archive processing and status counts.

## Transfer logs and state

Each transfer creates a human-readable log such as:

```text
logs/transfer-20260820-143503.log
```

Option `l` displays recent logs and opens a selected log with `less` when available.

The corresponding machine state is stored as:

```text
var/transfers/20260820-143503.state
var/transfers/20260820-143503.manifest
```

The manifest is critical to the safety model: post-transfer movement operates on the recorded folders rather than simply assuming everything currently present in the import directory belongs to the last transfer.

## Repository layout

```text
Cloud-to-NAS/
├── cloud-to-nas.sh
├── cloud-IN/
│   └── .gitkeep
├── transferred/
│   └── .gitkeep
├── logs/
│   └── .gitkeep
├── var/
│   ├── .gitkeep
│   └── transfers/
│       └── .gitkeep
├── local/
│   └── paths/
│       ├── .gitkeep
│       ├── source.txt.example
│       └── nas-destinations.txt.example
├── README.md
├── version-history.md
├── LICENSE
└── .gitignore
```

Live configuration, photographs, logs and runtime state are ignored by Git. Placeholder `.gitkeep` files are included in every structural directory that may otherwise be empty, and the application recreates them on startup if needed.

## Requirements

Cloud-to-NAS targets Linux with Bash 4.3 or later.

Required commands include:

- `bash`
- `find`
- `stat`
- `date`
- `mv`
- `mkdir`
- `rm`
- `rsync`
- `ssh`

Recommended:

- `less` for paging plans and logs
- `numfmt` for human-readable sizes
- SSH key authentication for NAS transfers

On Ubuntu:

```bash
sudo apt install rsync openssh-client
```

## Installation

```bash
chmod +x cloud-to-nas.sh
./cloud-to-nas.sh
```

The first-time-run wizard creates the live configuration.

## Archive convention

Files:

```text
YYYY-MM-DD-original-filename.EXT
```

Monthly folders:

```text
YYYY-MM-00 - Context
```

Example:

```text
2026-08-00 - ProtonDrive/
├── 2026-08-01-IMG_23456.JPG
├── 2026-08-07-IMG_23510.MOV
└── 2026-08-19-IMG_23777.PNG
```

## Date source

Cloud-to-NAS uses the filesystem modification timestamp returned by GNU `stat` as its date source. It reads the numeric epoch value (`stat -c %Y`) and converts it to `YYYY-MM-DD` with `LC_ALL=C date`, avoiding locale-dependent formatted timestamp parsing. This gives a consistent method across photographs, screenshots and videos where EXIF metadata may not be present in every file.

Users should spot-check source timestamps before a large archive migration.

## Safety principles

Cloud-to-NAS is intentionally conservative:

- dry-run/pre-flight before mass rename
- move preview before monthly organisation
- no `rsync --delete`
- post-transfer verification before local retirement
- exact transfer manifest retained
- verified files moved to a separate `transferred/` safety area first
- permanent deletion requires typing `DELETE`
- deletion only operates on individually selected, verified `ARCHIVED` batches
- failed re-verification blocks archived-batch deletion
- **the import/source directory, built-in `cloud-IN`, and anything beneath either path are never deletion targets**

## Licence

Copyright (C) 2026 James Wintermute.

Cloud-to-NAS is licensed under the GNU General Public License v3.0 or later. See `LICENSE` for the full licence text.

This program comes with ABSOLUTELY NO WARRANTY.
