# Flea 0.3.11

- Markdown and HTML open rendered in Quick Look and the preview column, and r switches Quick Look to Source and back (#204, @fsrodrig).
- HTML pages preview as still pictures, with scripts and remote content blocked.
- CSV and TSV files preview as tables in Quick Look and the preview column, and long files page in as you scroll (requested on X).
- Camera RAW files preview from their embedded JPEG, and the facts line and Properties show the camera, lens, exposure and capture time.
- Tall previews fill the column above one facts line, and i switches to the full facts table (#208, @iccodes).
- Quick Look uses the available height for text, code and PDFs, and keeps portrait images in proportion.
- PDFs scroll as a continuous stack of pages in the preview column.
- Code previews use theme colours, including Markdown source and fenced code in List and Columns views (#204, @fsrodrig).
- Language icons are on by default in List, Grid, Columns and Quick Look, and the menu can turn them off.
- JSON previews format their contents for reading.
- GIF previews animate while visible.
- AppImages show their own icons.
- Quick Look shows font samples and facts.
- Compare two files in Quick Look, and press y to copy their unified patch.
- F and B page text and Markdown previews without moving the file cursor.
- Drag the preview column edge to resize it, and Flea remembers the width.
- Media keys control a playing preview, and video playback keeps the screen awake.
- Downloads, Pictures and Videos open newest first until you choose a sort there.
- A save dialog starts with the file name focused, so Enter saves into the folder shown (#191, @dyedfox).
- Columns view keeps matching neighbouring columns drawn during navigation and replaces their rows when the new listing arrives.
- Drag a file onto Trash in the sidebar to trash it, and Undo restores it (#235, @t1nk333r).
- A mounted ISO image appears in the sidebar with an eject mark, and ejecting it detaches its loop device (#196, @MISTERNEGATIVE21; #234, @martythedev-tech).
- Visible thumbnail requests wait their turn when every thumbnail worker is busy (#268, @mrphonk).
- Grid tiles scrolled into view after the window shrinks draw and take clicks again (#294, @dyedfox).
- Program files, including PIE executables, show the program icon and offer Run on a double-click (#301, @Heus-Sueh).
- Trash failures say what happened and what was left in place, with technical detail kept in the log.
- Compare becomes available when the selected file types finish loading.
- Cancel stops waiting for a blocked FUSE source read and removes the partial copy (#144, @mfilm77; #247, @itsmunzir).
- Powering off a removable drive checks every mounted sibling volume, including hidden rows (#232, @MiguelDebruyne).
- The file picker starts with the saved hidden-file setting and honours a per-request override (#313, @choirib).
- Glassy mode gives file lists their own background opacity while keeping glass on the sidebar and window chrome.
- Files can be dropped onto favourites and mounted drives in the sidebar, with Undo for moves and copies.
- Settings keep the newest saved choice when an older refresh finishes later.

## Known issues

- Local-list startup uses 0.82-0.91 seconds of CPU, compared with 0.77-0.80 seconds in 0.3.10.
- Long sessions can retain render resources (#151, @marvreichmann).
- Some office documents fail to preview inside the sandbox.
- First previews from network shares, large-copy progress and Dual scrolling still have latency work pending.
- Physical-phone copying and the original HFS+ remount reports still need hardware verification (#144, @mfilm77; #247, @itsmunzir; #232, @MiguelDebruyne).

Thanks to @iccodes, @fsrodrig, @dyedfox, @MISTERNEGATIVE21, @martythedev-tech, @t1nk333r, @mrphonk, @Heus-Sueh, @mfilm77, @itsmunzir, @MiguelDebruyne and @choirib.
