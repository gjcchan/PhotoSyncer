# PhotoSyncer

Used to help maintain iCloud capacity limits by automatically offloading photos and media to a location(s) of your choice (and optionally deleting them afterwards.) 

Requires MacOS, use at your own risk.

## Setup & Requirements

- **Grant Photos Access**: Allow PhotoSyncer full access to your Photos library (**System Settings › Privacy & Security › Photos**), as it relies on macOS Photos to retrieve your photos and videos.
- **Download Originals in Photos**: In the **Photos** app, go to **Photos › Settings › iCloud** and select **Download Originals to this Mac** so full-resolution originals are available to sync.
- **Automation (Optional Fallback)**: If PhotoKit cannot download an iCloud original directly, PhotoSyncer can ask the **Photos** app to export it via AppleScript. If prompted, allow PhotoSyncer to control **Photos** in **System Settings › Privacy & Security › Automation**.
- **Other Optional Prompts**: Enabling **Launch at Login** may prompt for approval under **System Settings › General › Login Items**, enabling **Wake Mac from sleep for scheduled sync** asks once for Administrator approval to configure macOS's `pmset` wake timer, and connecting to a LAN NAS, SMB, or SFTP server may prompt for **Local Network** access. Destination folder access is granted automatically when you pick a folder.

## Features

- **Menu-Bar Background Sync**: Runs quietly from the macOS menu bar on a configurable schedule (every 1, 4, 12, or 24 hours, or daily at a set time with optional macOS wake-from-sleep) with Launch at Login, Pause/Resume, live status and deletion-queue (`count (size)`) readout, and recovery across sleep/wake, network changes, and drive reconnects.
- **Full Library Asset Support**: Exports original photos and videos along with edited renders, RAW/JPEG pairs, and Live Photo paired videos.
- **Multiple Destinations (Folders, SMB & SFTP)**: Syncs to local disks, USB drives, mounted NAS shares (via security-scoped bookmarks), SMB network shares (via macOS's built-in SMB client with Keychain-stored passwords or guest access), and SFTP servers (with Keychain-stored passwords and trust-on-first-use SSH host-key pinning).
- **Cross-Destination Sync**: Optional copy-only mirroring keeps multiple destinations eventually consistent by copying missing files between them based on SHA-256 content hashes.
- **Verification & Deduplication**: Validates exported originals (decoding, format, and full pixel dimensions), deduplicates by SHA-256 hash, and verifies every written file with uncached read-back checks.
- **Optional iCloud Deletion & Data Budget**: Optionally deletes verified synced items from iCloud—either **Files that were just synced** or **Oldest synced files** when your library exceeds a configurable GB budget (with confirmation warnings before lowering the budget or enabling retroactive oldest-first deletion). Every deletion is re-verified with uncached SHA-256 checks across all enabled destinations and requires macOS confirmation, which moves the batch to **Recently Deleted** (auto-purged by iCloud after 30 days).
- **Held Deletion Queue (Fewer Prompts)**: To avoid repeated macOS deletion prompts during background syncs, **Settings › Delete** can hold eligible items silently in the queue until you click **Delete … Queued from iCloud…** in the menu bar (or until the queue reaches an optional GB threshold), letting you confirm an entire accumulated batch in one click.
- **Fallback for Stuck iCloud Downloads**: Uses adaptive retry backoff, optionally saves the best local space-saving copy (`-preview.<ext>`, replaced automatically when the original arrives and never eligible for iCloud deletion), and moves persistently stuck items to **Settings › Failed** for manual retry (`Retry Selected`, `Retry All`) or preview inspection.
- **Activity, Logs & Maintenance**: Built-in **Settings** tabs for live sync activity and errors, searchable persistent logs, and full ledger/index rebuilds.
