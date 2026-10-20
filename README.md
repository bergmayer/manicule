<p align="center">
  <img src="manicule-icon.png" width="192" alt="Manicule app icon">
</p>

# Manicule

**Manicule** is named for the pointing-hand mark readers historically drew in a book's margin to call attention to a passage. It is the reader companion to [Pilcrow](https://github.com/bergmayer/pilcrow), the text editor.

## What it is

A document reader for macOS, iOS, and iPadOS. Like Preview.app, but for ePubs, comic books (CBZ/CBR), and plain text/Markdown, in addition to PDFs.

Double-click a file in Finder, and it opens.

On iPhone and iPad it's the same: a document-based app that opens files through the system file picker and supports open-in-place from the Files app.

## Why is it?

Most ebook apps have some special "library" that you have to import books into.  I would rather have an app that just uses the already-existing file system.  The app still keeps track of your last-read position for recently-read books by a hash of its contents, and you can add a manual bookmark.  These sync via iCloud.  Per-book display settings also sync.

The iOS/iPad app shows a list of recently-open books so it's kind of like a library, though when a book has been opened on one device, you have to manually open it via the document picker on another device, before the recents shortcut works on that device.  It's a sandboxing thing.

Last-read position is saved automatically for the 12 recent books and restored when you reopen them. Books with manual bookmarks or custom settings are remembered and never age out of the recent list (arbitrary cap of 60).

The app also offers interactive (not just the cover) Quick Look plugins for iOS/iPadOS and Mac, for all supported formats (epubs, comics, PDF).  

Other things that app does:  There are optional features to render Markdown files or display them as raw text, and it will not display the manual linebreaks in Project Gutenberg-type text files.  (I like that PG treats plain text as the baseline format, and just like a lot of PDFs should be ePubs instead, a lot of ePubs could probably just be plain text files instead.  But I think there is little reason to continue with the manual linebreaks. Get rid of them PG!)

There is also a built-in narration feature on iOS/iPad where the app will use built-in voices, and highlight the text that is being read aloud.  

## Building

Open `Manicule.xcodeproj` in Xcode and install it on your devices.  I don't want to put this in the app store since I don't want to provide tech support; that said, it's sort of annoying that an app with this exact feature set is not already in the app store.  In fact I think Apple's Preview should just have most of these features.  On Apple devices by default if you try to open a DRM-free ebook it copies it over into Apple Books.  Stupid!

The macOS Debug and Release configurations use “Sign to Run Locally,” so they do not require an Apple Developer account or provisioning profile. These local builds remain sandboxed but omit the iCloud key-value-store entitlement; bookmarks and settings therefore stay local. `Manicule-macOS.entitlements` retains the iCloud capability as an opt-in entitlement file if provisioned builds are ever needed.

## Third-party code

EPUB, plain text, and Markdown layout use [foliate-js](https://github.com/johnfactotum/foliate-js) by John Factotum, vendored in `Manicule/Resources/foliate-js/`. It handles EPUB parsing and shared pagination, scrolling, navigation, and search. Text and Markdown are supplied as generated HTML sections; they do not need to be converted into EPUB archives. MIT licensed; see `Manicule/Resources/foliate-js/LICENSE`.

Swift package dependencies, resolved by Xcode:

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (MIT) -- ZIP extraction for ePub and CBZ files
- [Unrar.swift](https://github.com/mtgto/Unrar.swift) (MIT) -- RAR extraction for CBR files

## AI Use

Lots!

## License

MIT.
