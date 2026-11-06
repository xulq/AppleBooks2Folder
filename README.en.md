# AppleBooks2Floder

[简体中文](README.md) · English

AppleBooks2Floder is a macOS app for personal use. It exports downloaded, DRM-free PDFs and EPUBs from Apple Books to a folder synced by Nutstore or another cloud client. After the files sync, you can open them on Android, a tablet, or a compatible e-reader.

## Download and install

[**Download for macOS**](https://github.com/xulq/AppleBooks2Floder/releases/latest/download/AppleBooks2Floder-macOS.zip) · [View releases](https://github.com/xulq/AppleBooks2Floder/releases)

Requires macOS 14 or later and supports Apple silicon and Intel Macs. Unzip the download, drag `AppleBooks2Floder.app` to Applications, and open it.

This release has no Apple notarization. If macOS says it cannot verify the developer, confirm you downloaded the ZIP from the GitHub link above, then go to **System Settings → Privacy & Security → Open Anyway**. [Apple's instructions for opening the app](https://support.apple.com/en-us/102445)

## Getting started

1. Download the books you want to export in Apple Books. AppleBooks2Floder finds the catalog and the standard local and iCloud Books folders automatically. If macOS asks for access to another app's data on the first read, allow access.
2. Click **Choose Folder…** and select an existing cloud sync folder or a subfolder. Nutstore users can find Cloud Bridge folders under **Locations** in the Finder sidebar. A regular local folder also works.
3. Under **Export Scope**, choose all books or the first N books. Click **Export Now**, or turn on **Automatic Sync** and select an interval. The app stays in the menu bar after you close the window, where you can pause automatic sync or export immediately.
4. After the cloud client uploads the files, open the same folder on Android or another device and open or import the files in a reader. An e-reader needs access to that folder or a way to import the downloaded files.

See the [Apple Books download guide](https://support.apple.com/en-gb/guide/books/ibks5f526382/mac), [macOS folder access documentation](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox), and [Nutstore Cloud Bridge guide in Chinese](https://help.jianguoyun.com/?p=6334).

## Interface language

The app supports English and Simplified Chinese. By default, it follows your macOS language preferences. To set the app's language independently, add AppleBooks2Floder under **System Settings → General → Language & Region → Applications**, choose a language, then quit and reopen the app. English is the fallback. [Apple's per-app language instructions](https://support.apple.com/en-us/guide/mac-help/mh26684/mac)

## Folder access

The app runs in the macOS App Sandbox. Read-only Books access is limited to the standard catalog, iCloud Books, and legacy Books folders. The destination selected through the system picker receives read and write access. The app briefly copies the Books catalog and its write-ahead log, when present, into its private temporary folder before reading the catalog.

If macOS denies access without showing a prompt, click **Allow Books Library Access…** or the access button for the affected folder in Export Results. If the system panel opens elsewhere, click **Copy Books Path**. Press **⌘ Command + ⇧ Shift + G** to open Go to Folder, then paste the path and press Return. Click **Allow Access** once the panel is at the Books folder. The app saves read-only access and retries the export.

The app reuses the saved destination after an upgrade. If its permission expires, select the destination again. If you granted an earlier version Full Disk Access, you can turn it off for AppleBooks2Floder under **System Settings → Privacy & Security → Full Disk Access**.

## Export scope and sync frequency

- **All Books** is the default. With **First N Books**, enter 1–2,000 and click **Apply**. By default, the app follows the order of **All** in Apple Books. You can also select **Recent**, **Title**, **Author**, or **Manual Order**. Books that need downloading or are protected count toward the limit, so the number of exported files may be lower. Narrowing the scope keeps earlier exports.
- Automatic sync runs every **1, 5, 15, 30, or 60 minutes** and defaults to **15 minutes**. The interval controls when the Mac checks and exports books. The cloud client manages upload timing. **Export Now** is available while automatic sync is off.

## Export behavior

- PDFs and EPUB archives are copied as-is. EPUBs stored as folders by Apple Books are repackaged as single `.epub` files.
- Export runs one way from Apple Books to the selected folder. Reading progress, notes, bookmarks, and collections stay in Apple Books.
- The app skips identical files it already finds at the destination. Books with matching names and different contents are saved with a suffix. Removing a book from Apple Books keeps its exported copy. Moving a copy out of the destination lets the next export recreate it.
- DRM-protected or encrypted books are skipped. Download originals in Apple Books before retrying. **Export Results** lists books waiting for download, skipped books, and failures.
- Your cloud client handles uploads and downloads. AppleBooks2Floder runs locally and uses the selected folder. Check your cloud client for transfer status.
- Destination permissions, scope, sort order, sync frequency, and the export cache are stored in the app's sandbox. If the app cannot recognize the sort order of **All** in Apple Books, select the matching order manually.

## Building from source

This directory is a standalone Swift package. With Xcode 15 or later, run these commands from the package directory.

```sh
swift test
./scripts/build-app.sh
```

The app archive is written to `dist/AppleBooks2Floder-macOS.zip`. The build uses an ad hoc signature by default. You can specify a signing identity through `APPLEBOOKS_SIGN_IDENTITY`. macOS may ask you to select the destination again after an upgrade that changes the signing identity.

## License

Starting with 0.4.4, the AppleBooks2Floder app and its project-owned source use the **Komorebi License 1.0.0**. You may use the app for personal, noncommercial purposes such as private study and entertainment, and make private modifications and builds for those purposes. Commercial use, organizational use, and redistribution of the source, app, or modified versions require separate permission. Earlier copies retain the terms under which they were obtained. [Full license](LICENSE)

The bundled ZIPFoundation code retains its MIT license. The app's read-only catalog discovery and EPUB packaging were informed by BookAlong Sync. [ZIPFoundation license](Vendor/ZIPFoundation/LICENSE)
