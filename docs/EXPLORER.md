# Windows 11 File Explorer: what Burrow copies

Research notes behind the design. Structure and behavior only; no Microsoft
icons, text, or branding.

## Window, top to bottom

1. **Tabs** in the title bar. `+` adds a tab (opens to Home). Ctrl+T new, Ctrl+W close, Ctrl+Tab next.
2. **Header row**: Back, Forward, Up, Refresh, then the address bar, then the search box.
   - Address bar: location icon, then breadcrumbs separated by chevrons. Each
     chevron opens a list of that folder's subfolders. Clicking empty space (or
     Ctrl+L / Alt+D / F4) turns it into a text path.
   - Search box on the right ("Search Documents"), magnifier inside. Ctrl+E / Ctrl+F / F3.
3. **Command bar**: New (folder, text document) | Cut Copy Paste Rename Share Delete |
   Sort (Name, Date modified, Type, Size; Ascending/Descending) |
   View (Large icons, Details; Show: Details pane, Hidden items) |
   See more (Select all, Select none, Invert selection, Pin, Copy path, Options).
   Far right: Details, which toggles the details pane.
4. **Navigation pane** (left): Home, Gallery, pinned folders (Desktop, Downloads,
   Documents, Pictures, Music, Videos, each with a pin), OneDrive, This PC (drives,
   expandable tree), Network.
5. **Content**: Details view (Name, Date modified, Type, Size; folders first,
   rounded selection, no zebra stripes) or icon views with thumbnails.
6. **Details pane** (right, Alt+Shift+P): big thumbnail, name, type, size, dates, location.
7. **Status bar**: "12 items | 1 item selected 2.3 KB"; on the right, two buttons
   switch between Details and Large icons.

## Pages

- **Home** (default start page): Quick access (pinned folders as tiles), Favorites, Recent files (name, date, location).
- **This PC**: known folders, then Devices and drives with a used-space bar.
- **Search results**: same list, plus the folder each hit lives in; crumb reads
  "Search Results in Documents". Searches the current folder and every subfolder.
  Indexed locations answer at once; unindexed ones are crawled ("Working on it").

## Keys (Microsoft's list, Windows 11)

Alt+D, Ctrl+L, F4 address bar · Ctrl+E, Ctrl+F, F3 search · Alt+Left, Backspace back ·
Alt+Right forward · Alt+Up up · F2 rename · F5 refresh · Ctrl+Shift+N new folder ·
Ctrl+D, Delete to Recycle Bin · Shift+Delete delete forever · Alt+Enter properties ·
Alt+P preview pane · Alt+Shift+P details pane · Ctrl+Shift+2 large icons ·
Ctrl+Shift+6 details · Ctrl+T / Ctrl+W / Ctrl+Tab tabs · Ctrl+N new window ·
Home / End first and last item · Shift+F10 context menu.

## Mac mapping

- Recycle Bin is the Trash. Shift+Delete is left out on purpose: nothing deletes forever.
- This PC is This Mac. Drives sit under **Locations**; pinned folders under **Favorites**.
- The index is Spotlight (`mdfind`). Folders Spotlight skips are crawled.
- The Mac Delete key (Backspace) moves to the Trash, since Mac laptops have no Delete key.

## Sources

- [Keyboard shortcuts in Windows, Microsoft Support](https://support.microsoft.com/en-us/windows/keyboard-shortcuts-in-windows-dcc61a57-8ff0-cffe-9796-cb9706c75eec)
- [File Explorer (24H2), Thurrott](https://www.thurrott.com/books/windows-11-field-guide/archived-22h2/312540/file-explorer-24h2)
- [Details pane and tab dragging, Pureinfotech](https://pureinfotech.com/file-explorer-new-details-pane-tab-drag-windows-11/)
- [New header, Home, Gallery changes, Pureinfotech](https://pureinfotech.com/file-explorer-new-header-ui-home-gallery-changes-windows-11/)
- [Home, Quick access and Favorites naming, Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/3911750/files-explorer-missing-recent-files-and-more-on-th)
- [How File Explorer search uses the index](https://filelocator-net.pages.dev/windows/)
