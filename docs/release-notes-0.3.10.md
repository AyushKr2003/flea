# Flea 0.3.10

- Tags in Omarchy's colours, shared with Dolphin. T tags the selection, 1 to 7 pick a colour, the menus gain a Tags row and flyout, a TAGS section can show in the sidebar (off by default), and search finds files by tag, such as the red tag.
- Pasting a folder onto one with the same name can merge the two, and undo puts both back as they were.
- Hovering a drag over a folder can open it (off by default), lists scroll while you drag near their edges, names that a stick's exFAT cannot hold are fixed before the copy, and an image on the clipboard pastes as a file.
- A run card shows what a script, program or AppImage will run and asks before starting it (#174, @dedeanth; #71, @nate8199).
- Bulk rename edits every selected name at once in your terminal editor, with swaps, bad lines and undo handled (#183, @muellan).
- Archives take a password for 7z, refuse to extract onto a drive without room, and open ISO images and package files.
- Encrypted drives unlock and relock in Flea, and flea --unlock does it from a terminal.
- A new image flasher writes an ISO or disk image to a USB stick and verifies every byte.
- An unlocked encrypted volume appears in the sidebar with its eject mark (#200, @akitaonrails).
- Back and forward return the cursor to the row it was on (#235, @t1nk333r).
- Listing a phone or network share no longer holds up the rest of Flea (#144, @mfilm77; #247, @itsmunzir).
- A WebDAV share's breadcrumb shows the name you saved it under (#237, @bthome; #246, @aholbreich).
- A refused WebDAV sign-in says the server did not accept the password, and a failure is no longer guessed as a TLS handshake failure from the address (#238, @bthome; #241, @GreyforgeLabs).
- Unmount is offered on every mounted volume, so a mounted NTFS drive can be unmounted from the sidebar (#232, @MiguelDebruyne).
- NFS and SMB shares that the system mounts appear under NETWORK in the sidebar, beside the shares Flea mounts (#257, @citizen-why).
- The file picker takes a typed path (#191, @dyedfox; #206, @akitaonrails; #256, @karacas).
- A drop on the Shelf's edge rail lands even after the rail has opened the card (#255, @liri2006).
- Flea skips Vulkan drivers for graphics cards the machine does not have (#248, @t1nk333r).
- Properties shows a folder's size and item count (#172, @nerdislb).
- A thumbnailer installed outside /usr, such as one under ~/.local, now runs inside Flea's thumbnail sandbox (#171, @matirossi93).
- Quick Look on an image that cannot decode and has no thumbnail yet waits for the row thumbnail and draws it, instead of showing "This image could not be read." (#263, @kevinbsr).
- Quick Look works when Flea was started with a relative path (#290, @fishandsheep).
- A copy or move onto a FAT or exFAT drive goes on past links, special files and names it cannot hold, and names what it skipped (#271, @jotapesse).
- Moving a folder onto an rclone mount that refuses no-replace renames no longer fails, and the move copies across with progress, cancel and the journal (#282, @protoavatar).
- Replacing a file on phone storage, where there is no Trash, works and Undo restores the old file (#261, @kosmicus).
- Copy, move or link follows the keys held at the drop, not at the start of the drag (#259, @muellan).
- The "/" filter narrows the rows in Columns view too (#260, @demostenex).
- A Shift range made after a scroll starts at the lone selected row, not at the cursor (#286, @dyedfox).
- Ctrl+V and Shift+Insert paste the first line of the clipboard into the filter and search lines (#287, @dyedfox).
- A bare digit switches to that tab (#284, @joebaus).
- With hidden files sorted last, a click on a file picker column header keeps them last, as every view does (#291, @KelpyShades).
- Grid view's selection band starts from the margin between tiles (#292, @KelpyShades).
- Flea can remember the view mode of each folder (#293, @carldx).
- The file picker remembers its sort (#281, @pedrosatin).
- The window can fade its background alone, leaving text and icons fully opaque (#274, @erikrjohansson).
- The system disk's other partitions, such as a Windows or second Linux install, show in the sidebar and follow Show unmounted drives, while boot and recovery partitions and the one holding / stay hidden (#215, @AyushKr2003; #217, @fsrodrig).
- Dual view's divider can be dragged and remembered, Tab reaches the rail, and Right on a rail row ejects it.
- Redo is also Ctrl+Shift+Z, the Tags flyout stays open while you pick, and a multi-selection's menu row reads "Rename N items…".
- Muted text meets 4.5 to 1 contrast, and a row that errored shows its state in words.
- A newer navigation cancels a listing that has stalled, so a slow folder no longer holds up the one you went to next.
- Search shows ranked results as you type: f opens it, Esc returns to the folder and the row you were on, and Enter keeps the results.
- Quick Look zooms an image with + and -, 0 returns to fit, and the media strip gains a volume track (#208, @iccodes).
- Properties shows a video's codecs and bit rate, and a photo's camera, lens, exposure and capture time (#208, @iccodes).
- A damaged volume that will not mount says why, with the system's reason as the detail (@maeandrew).
- In a pane without focus, selected rows keep a muted fill, and the sidebar lights the place that holds the current folder.
- Dialogs, panels and menus fade in and out the same way, and a long dialog keeps its title and buttons in view while its body scrolls.
- Window corners follow a Hyprland config reload without restarting Flea.

Known issues

- Deselect all is not in 0.3.10. There is no menu row or key for it, and Escape clears the selection instead (#164).
- Dragging a file onto Trash in the sidebar is not in 0.3.10. The Trash row has no drop target, so it moves to a later release (#235).
- Mounted ISO images do not appear in the sidebar yet. Unlocked volumes do, and image rows move to a later release (#200).
- The thumbnail stall reported in #268 is not fixed in 0.3.10. PR #268 changes only the thumbnail test harness.
- HFS+ eject could not be reproduced, so it is not claimed for 0.3.10 (#232).
- The memory growth and crash in #151 have not been reproduced; the report stays open.
- On a folder whose first row is a video the field run drew Flea's window about 28 ms after 0.3.9's, 530 against 502 ms on 2,000 mixed files and 541 against 513 on 1,700 (medians of 3 runs, with 0.3.10 launched first every time). Rerun with each version launched first in half of 10 runs, the medians are 502.5 against 502.5 ms on 2,000 files and 507.5 against 503.5 on 1,700. On 100,000 text files the field run had them level, 505 against 510.
- PCManFM's window appears first on all three folders (448, 420 and 416 ms), and in the field run Thunar's also appeared before Flea's on the two media folders (513 and 507 ms against 530 and 541).
- On the two media folders Flea's window uses 93.5 and 93.6 MiB, fifth for window PSS after Thunar, PCManFM, Nemo and Strata (34.2 to 87.5 MiB). On 100,000 files it uses the least, 80.7 MiB.
- On the media folders Thunar, and on 1,700 files Nemo, settle sooner and use less CPU than Flea, but the bench measured no thumbnail work from either, so those columns are not ranked.

Thanks to @dedeanth, @nate8199, @muellan, @akitaonrails, @t1nk333r, @mfilm77, @itsmunzir, @bthome, @aholbreich, @GreyforgeLabs, @MiguelDebruyne, @citizen-why, @dyedfox, @karacas, @liri2006, @nerdislb, @matirossi93, @kevinbsr, @fishandsheep, @jotapesse, @protoavatar, @kosmicus, @demostenex, @joebaus, @KelpyShades, @carldx, @pedrosatin, @erikrjohansson, @AyushKr2003, @fsrodrig, @iccodes and @maeandrew.

Source revision: f1c46dbf758dc93338f0d6e4bcbdcc829c4edc1b (v0.3.10).
