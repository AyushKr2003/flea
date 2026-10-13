<p align="center">
  <img src="docs/images/icon.svg" width="72" height="72" alt="Flea">
</p>

<h1 align="center">Flea</h1>

<p align="center">
  <strong>The fastest GUI file manager on Linux.</strong><br>
  Keyboard-first. Built for Omarchy.
</p>

<p align="center">
  <a href="https://github.com/tcballard/omarchy-badges"><img src="https://raw.githubusercontent.com/tcballard/omarchy-badges/85f859029e236e784e7b05ada6dbe73506d07a91/badges/v1/built-for-omarchy.svg" alt="Built for Omarchy"></a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#views">Views</a> ·
  <a href="#performance">Performance</a> ·
  <a href="#keyboard">Keyboard</a> ·
  <a href="https://github.com/thisisgm/flea/releases">Releases</a>
</p>

<p align="center">
  <img src="docs/images/release-0.3.0-themes.gif" alt="Flea 0.3.0 cycling through ten Omarchy themes, with the iPhone on the Devices rail and a photo in the preview column">
</p>

Flea combines a Rust backend with a Quickshell interface that follows your Omarchy theme.
Large directories stay responsive: the window loads rows and requests thumbnails as you need them.

- **Four views.** List, columns, grid and two panes side by side, with tabs and natural filename sorting.
- **Quick Look.** Press Space for images, PDFs, text, media, 3D model thumbnails and archive contents.
- **File operations.** Copy, move, rename, trash, compress and extract, with an undo journal. Several selected names rename in one card. A folder pasted onto a folder of the same name merges into it, and undo takes the merge back.
- **Tags.** Seven tags in your theme's colours, set with `T` and the keys 1 to 7, listed in the sidebar and found with `tag:red`.
- **Search.** Ranked results replace the listing as you type. Esc returns to the folder and the cursor; Enter keeps the results.
- **Network and sharing.** SMB, SFTP, FTPS, WebDAV, NFS, Dropbox and Taildrop.
- **Devices.** USB drives, phones and cameras over MTP, PTP and AFC, mounted from the rail. An encrypted drive unlocks from its rail row and locks again when you unmount it.
- **Disk images.** Write an ISO or IMG, plain or compressed, or a zip holding one, to a USB drive; Flea reads every byte back to check it.
- **Desktop integration.** Default file manager, “Show in folder” and Open/Save dialogs.
- **Your settings.** Omarchy text sizes, configurable menus and Default, Vim, Mac or Windows keys.

The newest navigation wins. Back, Forward, Up, a tab, the sidebar and the path bar replace a listing that
is still loading. Tab walks the listing, the sidebar, the chrome bar and the tab strip, and
Shift+Tab walks back. Muted text is lifted to a 4.5:1 contrast against its background, a menu row that
cannot act says why in one word beside its label (offline, signed out, no devices), and a long dialog
keeps its title and buttons in place while its body scrolls. Opening a script, a program or an AppImage
asks first: Run, Run in terminal or Open as text. Properties on a folder counts its size and items.

An iPhone lists once it has been unlocked and trusted on this machine: AFC needs the pairing record
that leaves behind, not an unlocked screen every time. Pairing also puts the phone on its tethering
USB configuration, so iOS shows Personal Hotspot as active while it is plugged in, and Flea never
uses it. If this machine should never route through the phone, tell NetworkManager so with a
`conf.d` drop-in carrying `unmanaged-devices=driver:ipheth`; that is your call, not the package's.

## Install

Install Flea and make it your default file manager, file chooser and the app opened by
**Super+Shift+F**:

```bash
omarchy pkg aur add flea-bin && flea --default
```

`flea-bin` is the tagged release, prebuilt for x86_64 and aarch64, and it reaches you minutes after it
ships. To let Omarchy's own repository review, build and sign it instead, a day or more behind:

```bash
omarchy pkg add flea && flea --default
```

Install one of the two, never both.

Run it at a terminal inside your session: `flea --default` restarts xdg-desktop-portal itself there,
so file dialogs follow at once. To only try Flea, run the install alone and leave your defaults as
they are; `flea --default off` hands everything back later, and Settings, About can switch it either
way.

Update through Omarchy:

```bash
omarchy update
```

Already on `flea` from Omarchy's repository? Switch to `flea-bin` with the interactive command and
answer `y` when pacman asks to remove `flea`:

```bash
yay -S flea-bin
```

`omarchy pkg aur add flea-bin` cannot make that swap: it passes `--noconfirm`, which takes each prompt's
default, and pacman's "Remove flea?" defaults to No.

<details>
<summary>File chooser only, development package and removal</summary>

Use Flea for portal Open/Save dialogs without changing your default file manager:

```bash
flea --picker
```

For the development build, which follows `main` and compiles on your machine, answer `y` if pacman
asks to remove an installed Flea:

```bash
yay -S flea-git
```

It updates with `yay -Sua --devel`.

Before removing Flea, undo its desktop integration, then drop whichever package you installed:

```bash
flea --default off
omarchy pkg drop flea
```

If you previously pinned another directory handler, restore that handler explicitly.
[Installation details](docs/install.md) cover dependencies, desktop integration and removal.

</details>

## Views

**List** for file details. **Grid** for photos and clips. **Columns** for browsing folders with a preview beside them.
**Two panes** show two folders side by side (`Ctrl+4`). Drag the divider to resize them, double-click it to make them equal, and Flea remembers the split. A setting can remember each folder's own List, Columns or Grid.

<p align="center">
  <img src="docs/images/grid.png" width="49%" alt="Grid view with image and video thumbnails">
  <img src="docs/images/list.png" width="49%" alt="Columns view with the preview column, file details and the iPhone on the Devices rail">
</p>

**Space** opens Quick Look from any view. Page through a PDF, play media or inspect an archive. `+` and `-` zoom an image, `0` returns it to fit, and media has a volume track beside its seek bar. Archive contents list for 7z, ISO images and packages, and a password archive asks for its password.

<p align="center">
  <img src="docs/images/pdf.png" alt="PDF preview with page navigation">
</p>

**The shelf** lives in the Omarchy bar: send files there from any menu, drag them out into any app, pin the ones you keep coming back to. **Phones** are Devices rows over MTP, AFC and PTP.

**Dragging** moves when the source and the destination are on the same device, and copies when they are on different devices. Hold Ctrl to copy anyway. Hold Shift to move anyway. Hold Ctrl with Shift to link instead, through the Paste as links card. Those keys are read when the drag starts; once the drag is up, a key pressed after that cannot change it. A plain drag into another app offers copy alone, as the file addresses and the plain paths. Ctrl at the lift offers copy alone, Shift offers move alone, and Ctrl with Shift offers a link alone, so that app cannot pick another verb. That app moves, copies or links the files itself. Flea does not also delete them, because the acceptance arrives before the other app has finished reading the addresses, and deleting then would put the files in Trash. The copy-only offer is the one a browser uploader takes; offering move is what made Chromium refuse the drag. The target has to be on screen before you lift; a terminal gets the path. Switching workspace mid-drag ends it, because Hyprland releases every mouse button on a workspace change, so bring the target workspace up first. See "A drag does not survive a workspace switch" in `AGENTS.md`.

<p align="center">
  <img src="docs/images/shelf.png" width="49%" alt="The shelf card open over Flea, with thumbnails, pins and the last three screenshots">
  <img src="docs/images/iphone.png" width="49%" alt="An iPhone camera roll browsed over AFC, with HEIC thumbnails and a preview">
</p>

**Background opacity** comes from a theme's `shell.toml`, or from `~/.config/omarchy/shell.toml` for every theme:

```toml
[flea]
background-alpha = 0.34
```

Values run from 0 to 1, and the default is 1. The listing, the rail and the bars let the desktop through at exactly that value; text, icons, thumbnails, menus, dialogs and Quick Look stay opaque. With Auto-hide sidebar on, the rail stays opaque, because it opens over the listing. Flea picks up a value set while it is open, except after it opened on an opaque theme, where the value applies the next time it opens.

## Performance

Measured on **12 October 2026**, using the **0.3.10** source tree.
Cold caches, 3 runs per app, medians below. 7 GUI apps on the same machine.

### Speed

#### btrfs, 100000 visible entries, filesystem btrfs

| File manager | Version | First window | Settled |
|---|---|---:|---:|
| **Flea** | 0.3.10, source 5816ab88 | 505 ms | 1.00 s |
| Dolphin | 26.08.2-1 | 752 ms | 5.07 s |
| Nautilus | 51.0.1-2 | 921 ms | 6.59 s |
| Nemo | 6.6.4-1 | 857 ms | 21.78 s |
| PCManFM | 1.4.0-2 | 448 ms | 33.54 s |
| Strata | v1.0.0 | 588 ms | 1.84 s |
| Thunar | 4.20.10-1 | 518 ms | 19.45 s |

#### btrfs, 1700 visible entries, filesystem btrfs

| File manager | Version | First window | Settled | Thumbnails |
|---|---|---:|---:|---:|
| **Flea** | 0.3.10, source 5816ab88 | 541 ms | 1.83 s | 43 |
| Dolphin | 26.08.2-1 | 733 ms | 13.18 s | 500 |
| Nautilus | 51.0.1-2 | 876 ms | 18.19 s | 641 |
| Nemo | 6.6.4-1 | 842 ms | 1.71 s | not measured |
| PCManFM | 1.4.0-2 | 416 ms | 114.99 s | 700 |
| Strata | v1.0.0 | 656 ms | 3.26 s | not measured |
| Thunar | 4.20.10-1 | 507 ms | 0.93 s | not measured |

Note: Nemo, Thunar: "unranked: nothing reached the thumbnail cache so its work was not measured".
Note: Strata: "unranked: its watches saw 0 renders for 86 opened fixture files so neither is a count".

#### btrfs, 2000 visible entries, filesystem btrfs

| File manager | Version | First window | Settled | Thumbnails |
|---|---|---:|---:|---:|
| **Flea** | 0.3.10, source 5816ab88 | 530 ms | 1.77 s | 43 |
| Dolphin | 26.08.2-1 | 747 ms | 13.76 s | 642 |
| Nautilus | 51.0.1-2 | 897 ms | 19.29 s | 641 |
| Nemo | 6.6.4-1 | 862 ms | 3.40 s | 60 |
| PCManFM | 1.4.0-2 | 420 ms | Timed out | 690 |
| Strata | v1.0.0 | 599 ms | 3.45 s | not measured |
| Thunar | 4.20.10-1 | 513 ms | 1.00 s | not measured |

Note: Strata: "unranked: its watches saw 0 renders for 86 opened fixture files so neither is a count".
Note: Thunar: "unranked: nothing reached the thumbnail cache so its work was not measured".

### Memory and CPU

#### btrfs, 100000 visible entries, filesystem btrfs

| File manager | Version | Window PSS | CPU |
|---|---|---:|---:|
| **Flea** | 0.3.10, source 5816ab88 | 80.7 MiB | 0.75 s |
| Dolphin | 26.08.2-1 | 202.6 MiB | 7.67 s |
| Nautilus | 51.0.1-2 | 321.4 MiB | 8.27 s |
| Nemo | 6.6.4-1 | 472.8 MiB | 25.00 s |
| PCManFM | 1.4.0-2 | 123.0 MiB | 23.05 s |
| Strata | v1.0.0 | 130.6 MiB | 1.53 s |
| Thunar | 4.20.10-1 | 358.5 MiB | 19.33 s |

#### btrfs, 1700 visible entries, filesystem btrfs

| File manager | Version | Window PSS | CPU |
|---|---|---:|---:|
| **Flea** | 0.3.10, source 5816ab88 | 93.6 MiB | 5.04 s |
| Dolphin | 26.08.2-1 | 99.3 MiB | 64.30 s |
| Nautilus | 51.0.1-2 | 176.4 MiB | 114.32 s |
| Nemo | 6.6.4-1 | 45.1 MiB | 1.66 s |
| PCManFM | 1.4.0-2 | 42.0 MiB | 171.36 s |
| Strata | v1.0.0 | 86.3 MiB | 7.61 s |
| Thunar | 4.20.10-1 | 34.2 MiB | 0.90 s |

#### btrfs, 2000 visible entries, filesystem btrfs

| File manager | Version | Window PSS | CPU |
|---|---|---:|---:|
| **Flea** | 0.3.10, source 5816ab88 | 93.5 MiB | 4.82 s |
| Dolphin | 26.08.2-1 | 102.8 MiB | 68.07 s |
| Nautilus | 51.0.1-2 | 176.4 MiB | 120.73 s |
| Nemo | 6.6.4-1 | 54.7 MiB | 9.38 s |
| PCManFM | 1.4.0-2 | 39.6 MiB | 154.08 s |
| Strata | v1.0.0 | 87.5 MiB | 7.32 s |
| Thunar | 4.20.10-1 | 35.2 MiB | 0.95 s |

"First window" records compositor registration. "Settled" means 500 ms without process-tree CPU activity; neither measures input readiness.
PSS covers the window process, excluding helpers and GPU memory. CPU is everything the app started, counted from a control group of its own, so sandboxed thumbnailers are in it. Shared libraries affect PSS. Results describe this machine and workload.
Settled time and CPU are not ranked against an app whose thumbnail work was not measured; the notes under each speed table name those apps.

[Method](docs/benchmarks.md) · [Local CSV](docs/bench/local-0.3.10-20261012.csv) · [Local manifest](docs/bench/local-0.3.10-20261012.manifest.md) · [Matched CSV](docs/bench/matched-0.3.10-20261012.csv) · [Matched manifest](docs/bench/matched-0.3.10-20261012.manifest.md) · [Media CSV](docs/bench/media-0.3.10-20261012.csv) · [Media manifest](docs/bench/media-0.3.10-20261012.manifest.md)

## Keyboard

Press **?** for the full keymap, or **,** to change settings.

| Action | Keys |
|---|---|
| Move / parent / enter | `j` `k` / `h` / `l` |
| Open with the default app | `Enter` |
| Quick Look | `Space` |
| Select / extend selection | `v` / `Shift` + arrows |
| Copy / cut / paste | `y` `x` `p`, or `Ctrl+C` `Ctrl+X` `Ctrl+V` |
| Rename / trash / undo / redo | `r` or `F2` / `dd` or `Delete` / `z` / `Ctrl+Shift+Z` |
| Tag the selection | `T`, then `1`–`7` |
| New folder | `Ctrl+Shift+N` |
| Search / filter the list | `f` / `/` |
| Enter a path, or jump to a folder by name | `:` or `Ctrl+L`, then a path or a name |
| List / columns / grid / two panes | `Ctrl+1` / `Ctrl+2` / `Ctrl+3` / `Ctrl+4` |
| Next / previous area | `Tab` / `Shift+Tab` |
| New tab / close tab / switch tab | `t` / `w` / `1`–`9` |
| Open terminal / context menu | `Ctrl+T` / `m` |
| Show hidden files | `.` |
| Zoom an image in Quick Look / fit | `+` `-` / `0` |

The Windows preset uses `Ctrl+Shift+1/2/3/4` for views and `Ctrl+Y` for redo. Menu visibility does not disable shortcuts.
See [the full key table](keys.toml) for preset bindings and pointer actions.

## Build

Requires Omarchy, Quickshell 0.3.1 or newer, and Rust. See
[installation details](docs/install.md) for runtime and optional dependencies.

```bash
cargo build --release
FLEA_UI="$PWD/ui" ./target/release/flea --gui
```

Pass a directory to open it, or `--select <path>` to reveal a file. The terminal interface
is not implemented yet.

```bash
./tests/run-all.sh
```

The headless runner builds both profiles and reports suites that need a display, credentials
or a package. [The test suites](tests/) cover file operations, previews, persistence and input;
[the protocol guide](docs/protocol.md) documents the backend.

## Support

If this saved you an afternoon, you can
[sponsor me on GitHub](https://github.com/sponsors/thisisgm) or
[buy me a coffee](https://buymeacoffee.com/thisisgm).

## Licence

[MIT](LICENSE).
