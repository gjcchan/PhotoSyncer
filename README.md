# PhotoSyncer

Used to help maintain iCloud capacity limits by automatically offloading photos and media to a location(s) of your choice (and optionally deleting them afterwards.) 

Requres MacOS, use at your own risk.

## Setup & Requirements

- **Grant Photos Access**: Allow PhotoSyncer full access to your Photos library (**System Settings › Privacy & Security › Photos**), as it relies on macOS Photos to retrieve your photos and videos.
- **Download Originals in Photos**: In the **Photos** app, go to **Photos › Settings › iCloud** and select **Download Originals to this Mac** so full-resolution originals are available to sync.
- **Automation (Optional Fallback)**: If PhotoKit cannot download an iCloud original directly, PhotoSyncer can ask the **Photos** app to export it via AppleScript. If prompted, allow PhotoSyncer to control **Photos** in **System Settings › Privacy & Security › Automation**.
- **Other Optional Prompts**: Enabling **Launch at Login** may prompt for approval under **System Settings › General › Login Items**, and connecting to a LAN NAS/SFTP server may prompt for **Local Network** access. Destination folder access is granted automatically when you pick a folder.

## Features

- **Menu-Bar Background Sync**: Runs quietly from the macOS menu bar on a configurable schedule (1, 4, 12, or 24 hours) with Launch at Login, Pause/Resume, and recovery across sleep/wake, network changes, and drive reconnects.
- **Full Library Asset Support**: Exports original photos and videos along with edited renders, RAW/JPEG pairs, and Live Photo paired videos.
- **Multiple Destinations (Folders & SFTP)**: Syncs to local disks, USB drives, mounted NAS shares (via security-scoped bookmarks), and SFTP servers (with Keychain-stored passwords and trust-on-first-use SSH host-key pinning).
- **Cross-Destination Sync**: Optional copy-only mirroring keeps multiple destinations eventually consistent by copying missing files between them based on SHA-256 content hashes.
- **Verification & Deduplication**: Validates exported originals (decoding, format, and full pixel dimensions), deduplicates by SHA-256 hash, and verifies every written file with uncached read-back checks.
- **Optional iCloud Deletion & Data Budget**: Optionally deletes synced items from iCloud (either newly synced items or oldest items above a configurable GB library budget), gated on verified copies across all enabled destinations and macOS confirmation.
- **Fallback for Stuck iCloud Downloads**: Uses adaptive retry backoff, optionally saves the best local space-saving copy (`-preview.<ext>`, replaced automatically when the original arrives and never eligible for iCloud deletion), and moves persistently stuck items to **Settings › Failed** for manual retry (`Retry Selected`, `Retry All`) or preview inspection.
- **Activity, Logs & Maintenance**: Built-in **Settings** tabs for live sync activity and errors, searchable persistent logs, and full ledger/index rebuilds.
