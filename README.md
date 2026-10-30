# diskfull

[![CI](https://github.com/hubastard/diskfull/actions/workflows/ci.yml/badge.svg)](https://github.com/hubastard/diskfull/actions/workflows/ci.yml)

Disk space treemap for macOS, Linux and Windows, written in Odin + raylib. Every box
is a file or folder, sized by the space it really takes on disk.

## Download

Prebuilt apps for macOS (Apple Silicon), Windows (x64) and Linux (x64, arm64) are on the
[Releases page](https://github.com/hubastard/diskfull/releases).

The macOS app is not notarized: the first time, allow it in System Settings ›
Privacy & Security › Open Anyway, or run `xattr -dr com.apple.quarantine DiskFull.app`.

## Build & run

You need the [Odin compiler](https://odin-lang.org/docs/install/).

```sh
# macOS / Linux
./build.sh                # macOS also gets DiskFull.app
./diskfull                # scan the whole disk (/)
./diskfull ~/Downloads    # scan one folder
```

```bat
:: Windows
build.bat
diskfull.exe              :: scans C:\
diskfull.exe D:\
```

You can also drop a folder on the window to scan it.

On Linux, the window needs X11 (Wayland desktops run it through XWayland).

## See everything

Folders the scan cannot read are counted at the bottom of the side panel.

- **macOS**: System Settings › Privacy & Security › Full Disk Access, add your
  terminal (or `DiskFull.app`). Some folders are root-only: `sudo ./diskfull`.
- **Linux**: `sudo ./diskfull`.
- **Windows**: run `diskfull.exe` as administrator.

When you scan a whole disk, the side panel compares what the scan found with what
the disk says is used. The difference ("Hidden from scan") is space no folder
shows: APFS snapshots and purgeable space on macOS (the "System Data" mystery),
btrfs/zfs snapshots on Linux, restore points and shadow copies on Windows, plus
folders that could not be read.

## Controls

| Action | |
|---|---|
| Hover | path, size, and what well-known folders are (caches, Docker, Xcode, WinSxS, journald...) |
| Click | show in Finder / file manager / Explorer |
| Right-click / scroll up | zoom into the folder |
| Backspace / Esc / scroll down | zoom out |
| Breadcrumbs (top) | jump to a parent |
| Tab | side panel: folder contents ↔ largest files |
| C | color by folder ↔ by file type |
| R | rescan |

## Accuracy

- Sizes are space allocated on disk, so sparse and compressed files count for what
  they really use (e.g. `Docker.raw`, online-only OneDrive files).
- Hard links are counted once (WinSxS ↔ System32 on Windows, pnpm stores...).
- Only one disk is scanned: other drives, network shares, disk images and pseudo
  filesystems (`/proc`, tmpfs...) are skipped. Windows junctions and symlinks are
  not followed.
- macOS: APFS firmlinks (`/Users` ↔ `/System/Volumes/Data/Users`) and clones are
  counted once; all volumes of the APFS container are scanned (Preboot, VM...).
- Linux: btrfs subvolumes and zfs datasets of the same pool are included.

## Development

```sh
odin test tests     # unit tests, including a scan of a generated folder tree
./diskfull --screenshot out.png ~/some/folder   # scan, save the window as PNG, quit
```

CI (`.github/workflows/ci.yml`) checks, tests and builds on Linux (x64, arm64),
Windows and macOS for every push and pull request, and saves a screenshot of the
running app for each platform as a workflow artifact. Pushing a `v*` tag publishes
the builds as a GitHub release:

```sh
git tag v1.0.0 && git push origin v1.0.0
```

## License

MIT, see [LICENSE](LICENSE).
