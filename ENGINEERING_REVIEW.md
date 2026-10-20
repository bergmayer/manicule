# Engineering review — September 4, 2026; follow-up September 5

The September 5 follow-up and its verification results appear at the end of this report. The preceding sections record the September 4 review.

Reviewed the clean working tree at `69eb08b`. Changes are intentionally uncommitted. No dependencies, document formats, deployment targets, or signing settings were changed.

## Scope and execution paths

The Xcode project declares macOS 26, iOS/iPadOS 26, and visionOS 26 support. The Quick Look extension declares visionOS 26.4. Tests target Mac and iOS; no visionOS test destination is configured. The app uses SwiftUI, AppKit/UIKit representables, PDFKit, WebKit, Vision, and AVSpeechSynthesizer. ZIPFoundation 0.9.20 and Unrar 0.5.3 remain necessary for archive formats.

- **Launch/open:** `ManiculeApp` uses a viewing-only `DocumentGroup` on Mac/visionOS and `IOSRootView` on iOS. The iOS picker opens in place; Recents resolves bookmarks, provider identifiers, and path hints. `ReaderDocument` owns the bytes, full-content hash, and parsed content. `DocumentContent.parse` dispatches PDF, EPUB, CBZ, CBR, plain text, and Markdown, including generic-UTI fallback detection.
- **Render/navigation:** `DocumentViewer` selects the reader. PDFKit displays PDFs; foliate-js renders EPUBs; generated HTML or native chunks display text; native scroll/page containers display extracted comics. Page arithmetic is centralized in `PageNavigation`. View-local state owns reading position, viewport, search, and chrome. `WebViewCoordinator` translates native/JavaScript callbacks and weak proxy actions.
- **Persistence/restoration:** `BookmarkStore` owns bookmarks/automatic positions and device-local access references. `ReadingPreferences` owns global defaults and per-book overrides, including cloud merge/tombstone logic. Hash migration preserves older saved identities. EPUB uses CFI/fraction; PDFs/comics use page indices; text uses a quantized fraction. Temporary extraction leases own archive resources.
- **Background work/close:** parsing, OCR, image work, and cover generation use background work; native views/coordinators own delegate callbacks. Closing saves reading position and dismantles WebKit handlers. Source documents are read-only: `fileWrapper` throws `notWritable`; there is no document editing, autosave-to-source, or undo/redo path. PDF cropping affects only the display document, never the source bytes.
- **Quick Look:** a separate data-based preview extension parses its own snapshots and returns HTML/PDF previews. Its format/rendering contracts differ from the app's interactive WebKit readers. Existing ZIP traversal, symlink, extraction-size, and temporary-directory safeguards were preserved.

## Prioritized findings and implemented changes

1. **Confirmed: cancellation covered individual iOS reads, not a whole Recents operation.** A superseded attempt could proceed to another fallback and obtain a new request ID, replacing a newer selection or presenting a stale picker. One `DocumentOpenRequest` now owns the whole lookup through SwiftUI's task lifetime. The loading overlay derives from that request instead of a second boolean. Cancellation and request identity are checked across suspensions and before publishing a result. Reopening the same URL gets a new session identity. `DocumentViewer` also resets reader state when `DocumentGroup` delivers different content at the same URL.

2. **Confirmed: security access was manually balanced across success, failure, replacement, and close, with no lifetime ownership on window destruction.** `SecurityScopedFile` now retains one acquisition until all session/loading/provider-capture users release it. `ReaderDocument.read` coordinates the provider read and creates one data snapshot off the main actor. Cancellation checks prevent a cancelled parse from being published. Synchronous provider I/O is still not forcibly interruptible mid-call.

3. **Confirmed: cancelled PDF trimming could apply a crop after restoring original bounds.** The incremental path lacked a cancellation check after awaiting detection. It now checks before every result application. The two processing loops became one loop with explicit incremental/batch application. Nearest-first traversal no longer requires a second deduplication set. The always-true `usesCropBoxTrimming` flag and its branches were deleted.

4. **Confirmed: PDF rendering used inconsistent ownership.** Initial loading and trimming could reopen a source URL while identity/positions referred to the earlier bytes. Sidebar thumbnail tasks also accessed the same PDFKit object the UI could mutate. Display loading now uses the original snapshot. A `PDFPageRenderer` actor owns a separate snapshot for crop detection and sidebar thumbnails; only rectangles/images cross to the UI. This also replaces one detached task per crop calculation and avoids recreating the background document on each trim restart. The initial PDFKit transfer still has one explicitly documented unchecked Sendable wrapper: its newly created object is handed to the main actor and is not reused by the producing task.

5. **Confirmed: PDF OCR used shared temporary filenames for concurrent searches of the same book.** One task could remove a thumbnail another task was reading. The PNG write/read/delete handoff was removed. OCR accepts an image directly and caches by document hash plus page index, retaining reuse across queries/windows. PDF/comic searches are cancelled immediately when queries change and when readers disappear, including pending debounce work.

6. **Structural: platform WebView updates duplicated callbacks and almost all document synchronization.** One representable declaration and one shared update implementation now handle file identity, scheme roots, styles, margins, and columns. Native focus, scroll configuration, gesture attachment, construction, and dismantling remain in platform adapters. The existing engines and proxy/coordinator boundary were retained.

7. **Confirmed: failed temporary render writes were treated as successful loads.** Text generation suppressed write errors, and EPUB preparation could leave a permanent spinner. Both now publish only successfully written files, use the existing directory lease for cleanup, and report preparation failures with retry. Text retains the previous successful render if a replacement cannot be written. EPUB cancellation releases a completed but unpublished directory. The immutable app-side directory lease now uses checked Sendable conformance. Text-script evaluation failures now retain a diagnostic instead of disappearing silently.

8. **Confirmed: declared visionOS support did not compile.** Bookmark code selected Mac-only security-scope options; WebView/comic code excluded required UIKit implementations; app scenes included Mac-only Settings/toolbar APIs. Conditions now select the intended platform APIs. The previously empty visionOS scrolling-comic branch uses the UIKit implementation. The platform and deployment-target declarations were preserved.

9. **Structural: reader identity was needlessly optional.** Every construction site already supplies `ReaderDocument.fileHash`. All four readers now require that identity, removing four custom initializers, fallback hashing, empty-hash keys, and unreachable nil guards. The document model remains the single source of identity.

10. **Boundary check:** restored/manual PDF and comic page positions now reject negative indices before assigning reader state, as well as positions beyond the end.

11. **Confirmed: cloud collection replacement lost independent edits and treated bad data as an empty library.** `SyncedCollection` now merges per-identity dated records and explicit deletion tombstones, with deterministic equal-clock resolution. `SyncedCollectionStorage` keeps a device-local recovery copy, reads legacy arrays, preserves unreadable bytes, and stops outgoing writes when remote data cannot be decoded. Bookmark and position stores share this implementation. Preference merging now handles equal-time conflicts deterministically and surfaces malformed data and quota failures. Each window acknowledges a given persistence error once, preventing an alert on every autosave while retaining diagnostics. Reproducible cloud covers yield storage to reading records. Persistence tests use isolated defaults and fake cloud stores, never the user's actual library. Legacy bookmark IDs are stable across decoding; malformed access references are backed up and valid references salvaged.

12. **Confirmed: global narration callbacks could be replaced or dismissed by another window.** The existing single synthesizer now has an explicit reader-owner UUID. Claiming narration releases the prior owner's bridge and callbacks; a non-owner cannot dismiss it. EPUB bridge narration and search messages carry request identities, so queued results from an earlier operation cannot attach to a replacement. The single-active-narration behavior is preserved without creating competing synthesizers.

13. **Confirmed: expensive work and result state had inconsistent ownership.** PDF text search now runs on the private PDF actor and transfers character ranges back to the display document, preserving PDFKit matching. One result enum replaces native-selection/OCR-page arrays and the mode boolean. Text preparation and Unicode-aware search run in cancellable background workers owned by view tasks; generated HTML and native chunks derive from the same prepared text. Custom-scheme reads run on a serial resource actor, retain their directory lease, and cancel callbacks when WebKit stops a request. Cover extraction has one serial actor and owned jobs; provider prewarming uses a bounded structured group. OCR and crop caches are bounded. Synchronous native calls still finish their current call before observing cancellation; cancelled results are not published.

14. **Confirmed: rendering/OCR failures could disappear or leave an indefinite load.** Native navigation errors, process termination, fatal bridge errors, and a bounded readiness timeout reach a recoverable reader error with Retry. Automatic process-reload loops were removed. OCR now distinguishes empty recognition from unreadable images or Vision failures. EPUB search failures remain search errors rather than destroying a usable document. Scheme responses preserve the HTTP status and UTF-8 charset expected by foliate's fetch calls. Text's first paint explicitly clears its hidden style before reporting readiness.

15. **Confirmed: state snapshots and first-page rules made persistence unpredictable.** All four readers derive view mode/two-up overrides from `ReadingPreferences`; PDF/comic trim settings do likewise. Duplicate view state and repeated EPUB configuration calls were removed. Restoring settings therefore updates the active reader. Zero is now a valid autosaved position once the document is ready, so returning to page one replaces an older midpoint. Restored fractions and displayed page values are bounded. Text's autosave timer was replaced with a view-owned debounce task; EPUB's delayed restoration and refocus work have explicit view lifetimes.

16. **Missing workflow: iOS had no notification of external source changes.** An owned `NSFilePresenter` observation now offers Reload or Keep Current after change/move/deletion. Reload uses the existing coordinated opening pipeline; failure retains the readable snapshot. The presenter is explicitly unregistered when its window task ends. A focused test performs a coordinated replacement and checks event delivery and presenter release.

17. **Structural: Quick Look copied parsers and text decoding.** The extension now compiles the app's EPUB/comic models and parsers, archive extraction, document errors, temporary-directory lease, and text decoder through explicit target membership. Six duplicate files were deleted (868 physical lines), along with the separate Quick Look text decoder. Extension-specific preview generation remains separate. ZIP/RAR cancellation checks preserve traversal, symlink, extraction-size, and cleanup protections. Original generated fixtures now cover every supported extension on every test run, including an actual stored RAR comic; the optional external corpus can add coverage but no longer determines whether core format tests run.

## Complexity measurements

Measured the original and final production trees with **Lizard 1.24.0**, using the same command:

```sh
uvx --from 'lizard==1.24.0' lizard -l swift --csv Manicule ManiculeQuickLook
```

This is lexical per-function cyclomatic complexity, not a compiler control-flow graph or runtime profile. Both conditional-compilation branches are counted; closures are attributed to their containing functions. SwiftUI bodies are not comprehensively assessed, and embedded/vendored JavaScript, tests, and dependencies are excluded. Lizard suppresses byte-identical duplicate files: the original Quick Look EPUB model/parser already disappeared from its output, so deleting those copies reduces maintenance and physical lines without reducing its measured CCN. Baseline is reproducible at `69eb08b`; raw CSVs are `/tmp/manicule-complexity-before.csv` and `/tmp/manicule-complexity-final.csv`.

| Function/path | Before | Final |
| --- | ---: | ---: |
| PDF `startTrimFrom` | 23 | 16 |
| WebView `updateNSView` | 12 | 2 |
| WebView `updateUIView` | 17 | 7 |
| Shared WebView `update` | absent | 10 |
| iOS `openDocument` | 10 | 6 |
| PDF text and OCR search entry points, combined | 14 (4 + 10) | 12 (one path) |
| Comic search | 8 | 7 |
| Text search orchestration | 3 | 6, now owns cancellation/error transitions |
| Quick Look text decoding | 20 | deleted; uses existing shared decoder |
| WebView bridge dispatch | 20 | 25, including operation/error boundaries |
| Format dispatch `DocumentContent.parse` | 21 | 21 |
| Pixel content detection | 20 | 20 |

The WebView update family falls from summed CCN 29 to 19, including the shared function. These are entry-point measurements, not claims that all associated worker logic disappeared. Whole-source summed CCN rises from **1,753 / 570 functions to 1,783 / 595 functions**; subtracting each function's base of one gives **1,183 → 1,188 decision increments**. New recovery, merge, cancellation, and failure boundaries offset removed branches. Function NLOC falls **6,959 → 6,828**; physical production Swift lines fall **16,463 → 15,878** (585 fewer, including all new production files). This is a smaller application with simpler identified paths, not an overall cyclomatic-complexity reduction. Tests add code intentionally.

## Verification

Baseline: Mac passed 76 tests and iPhone passed 93, each with two optional-corpus skips. Several corpus loops also ran zero documents. Baseline visionOS compilation failed. Final tests use mandatory original temporary fixtures; no original user documents were used for testing. The system `xcode-select` still points at Command Line Tools; commands explicitly use `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` without changing that setting.

| Verification | Final result |
| --- | --- |
| macOS Debug, app + Quick Look + tests | 106 tests passed, zero skips/failures |
| iPad simulator, iOS 26.4 | 124 tests passed, zero skips/failures |
| iPhone simulator, iOS 26.4 | 124 tests passed, zero skips/failures after fixing the detached WebView test host |
| macOS static analyzer | Passed |
| iOS Release generic device, app + Quick Look | Build passed, signing disabled; no hardware installation |
| visionOS Simulator, app + Quick Look | Final build passed; execution unavailable |
| Formatting/lint | No project formatter/linter configuration or installed SwiftLint/SwiftFormat found; `git diff --check` and `node --check Manicule/Resources/bridge.js` passed |

Coverage includes coordinated source reads and replacements, source preservation, cancellation, temporary-resource cleanup, failed writes, ZIP traversal limits, all supported format families, real RAR extraction and corruption, Unicode/legacy text decoding, original-text Unicode search ranges, actual Vision recognition and blank/unreadable distinction, PDF text-range transfer and thumbnails, cloud merge/deletion/relaunch/conflict/recovery/quota behavior, preference persistence, narration ownership, WebKit replacement/HTTP response/cancellation/process-failure behavior, and visible EPUB/text rendering. Rendering tests host WebViews in native windows; DOM presence alone is insufficient to prove visible output. The final iPhone retry initially timed out in the older unattached EPUB test host after WebKit suspended its process. Giving it the same visible host as the pagination test fixed that harness defect; the complete suite then passed.

Current-build Mac interaction rendered a disposable 2.5 MB Markdown document (924 pages), searched 1,500 and 45,000 occurrences, navigated to the midpoint, and saved/reopened at page one. Earlier disposable Unicode Markdown interaction also checked raw/rendered switching and approximate restoration. These are interactive checks, not a throughput or peak-memory benchmark. Finder displayed a two-page stored-RAR fixture after registering the new extension. Multiple reader extensions are installed, and logs establish discovery but not which extension supplied that panel; therefore this does not prove current Manicule Quick Look invocation.

Logs: `/tmp/manicule-final-mac.log`, `/tmp/manicule-final-ipad.log`, `/tmp/manicule-final-iphone.log`, `/tmp/manicule-final-analyze.log`, `/tmp/manicule-followup-device.log`, `/tmp/manicule-final-vision.log`. XCTest result bundles are under `/tmp/manicule-review-{mac,ios}/Logs/Test`. The existing AppIntents metadata-extraction warning remains; final builds have no Swift source warnings. WebKit emits system sandbox/XPC diagnostics while tests pass.

## Retained design and limits of the evidence

The earlier deferred code findings have been implemented above. Native PDFKit/WebKit/text components, foliate-js, format dispatch, XML delegates, pixel detection, dependencies, and deployment scope remain because they provide necessary behavior; rewriting them merely for a score would add risk. The reader continues to hold a coordinated snapshot rather than writing source files. Snapshot copying can cost memory for large files; it protects a consistent document identity and rendering source.

Existing saved arrays are migrated to versioned per-record cloud collections; older binaries that only understand arrays should be updated on devices participating in this sync. Deletion records are retained to prevent offline resurrection. If storage reaches its limit, local recovery remains available and an error is surfaced; old deletions are not silently discarded to hide quota pressure.

Physical-device audio/background execution, real cross-device iCloud delivery, third-party FileProvider integration, visionOS runtime interaction, full VoiceOver/input-method coverage, compressed/solid/password-protected RAR variants, and adversarial large-corpus stress were not established by this environment. A stored RAR fixture and a large Markdown fixture are not substitutes for all those cases. Attempts to obtain a visionOS runtime failed in Xcode's simulator service. No app code can remove those external verification constraints, and no passing build or automated suite is presented as proof of them. No commit, distribution signing, upload, or publication was performed.


## September 5: list retention, file identity, and text positions

Scope follows the clarified product behavior: ebook files stay with their filesystem/provider, the existing iCloud key-value sync remains, and removing a book from the list removes its automatic position. No persistent catalog, book-version database, or CloudKit migration was introduced.

- **Removal now survives fresh autosaves from old windows, including offline devices.** Synced records distinguish membership changes (open/remove) from position changes. An ordinary update preserves its membership version; a removal supersedes that membership even when an offline device produces a later position timestamp. Deliberately opening the book creates a new membership. `DocumentViewer` supplies the resulting session through its environment; the four readers can update only that session's membership. Old windows cannot overwrite a later reopening. Deletion records contain no reading position. Evicting an unpinned book uses the same deletion behavior; the existing list limits remain.
- **Saved-file reopening validates identity before publishing a reader.** `ReaderDocument.read(from:expectedHash:)` verifies the coordinated bytes before parsing, then uses the computed hash as the document identity. Renaming/moving an identical file works; replacement contents are rejected. Existing prefix hashes remain accepted for legacy migration. The iOS stored-access, provider-reference, path-candidate, and Locate File paths all carry the expected fingerprint. Ordinary direct file opening remains unrestricted by a saved identity. One optional saved-book request replaces separate picker directory/name/hash state, keeping identity attached through sheet dismissal.
- **Text positions carry source and passage anchors.** Newly saved text/Markdown positions record an original source line, a short passage, and an offset within its block; percentage remains a fallback. The Markdown renderer can emit source markers without changing Quick Look's default output. Plain-text markers retain source-line mapping after whitespace reflow. WebKit captures a visible passage and restores it across raw/rendered Markdown, pagination, scrolling, and font changes. Legacy percentage records still decode and restore. Duplicate text-bookmark navigation paths now share one restoration implementation. Raw native scrolling retains its existing 100-line text components and selection behavior: its source anchors restore at chunk boundaries, rather than claiming character-level native scrolling precision. Geometry replaces lazy-prefetch `onAppear` events as the source of native reading progress, and restoration suppresses premature position writes.
- **Scrolling waits for layout before restoring.** The iPad integration test initially found the correct passage but observed scrollY=0: the native scroll area had not caught up with the first animation frame. Scrolling now shares pagination's stable-layout wait. The same visible-text geometry assertion then passed on Mac, iPad, and iPhone.

Seven focused tests were added: offline deletion/reopening/session revocation; deletion arriving during a save and relaunch; migration of existing record envelopes; renamed and replaced files with unchanged source bytes; reflow source mapping; anchor/legacy serialization; and actual WebKit passage visibility across Markdown modes and font sizes. All persistence tests use isolated defaults and in-memory cloud payloads.

| Final September 5 verification | Result |
| --- | --- |
| macOS app + Quick Look + tests | 113 passed, no skips/failures |
| iPad simulator, iOS 26.4 | 131 passed, no skips/failures |
| iPhone simulator, iOS 26.4 | 131 passed, no skips/failures, executing the final simulator build |
| macOS static analyzer | Passed |
| iOS Release, generic device, signing disabled | Passed |
| visionOS Simulator app + Quick Look build | Passed; no runtime execution |
| Swift whitespace / embedded reader JavaScript syntax | `git diff --check` and `node --check` passed |

Logs are `/tmp/manicule-retention-{mac,ipad,iphone,device,vision}.log`, with XCTest result bundles in the corresponding `/tmp/manicule-review-*` derived-data directories. The only build warning remains the existing AppIntents metadata-extraction warning. During implementation an iOS-only cover-loading call initially used an out-of-scope expected-hash variable; this was corrected before the successful final builds.

Manual Mac interaction on the disposable 2.5 MB Markdown fixture confirmed midpoint navigation and retention of Section 749 when switching rendered/raw modes despite changing page counts. Inspecting only that fixture's local record confirmed a persisted source/passage anchor. Background launches through UI automation sometimes left WebKit suspended until the document was activated and triggered the readiness timeout; retry/activation recovered rendering. Manual close/reopen verification was interrupted by the test-host/UI lifecycle, so the automated fresh-WebView restoration assertions are the stronger evidence for reopening. This is not a physical-device, live multi-device iCloud, or third-party-provider test. Simulated independent devices exercised membership convergence; coordinated temporary-file moves/replacements exercised file identity. Real service delivery and provider availability remain external verification limits.

Using the same Lizard 1.24.0 Swift command as above, this follow-up changes **595 functions / CCN 1,783 / 1,188 decision increments** to **609 / 1,835 / 1,226**. Production Swift totals **16,133 physical lines**, 255 more than September 4 and 330 fewer than the original checkout. New membership and anchor behavior adds necessary paths; this follow-up is not presented as an overall complexity reduction. `openRecentBook` falls 3→2, text `navigateToBookmark` 4→1 and `restoreScrollPosition` 8→4, with a shared `navigateToPosition` at 5. `savePosition` remains 8; explicit `beginReading` adds 9. These are function-level measurements, including the new entry points, not a claim that moved decisions disappeared. Raw files are `/tmp/manicule-retention-{before,after}.csv`.

The embedded reader JavaScript was also extracted and measured with Lizard's JavaScript parser. Against original `69eb08b`, it changes from 81 functions / CCN 286 to 84 / 311; this comparison spans both review days. The parser measures nested callbacks separately. New `captureTextAnchor` measures 5 and `restoreTextAnchor` 7, excluding its separately measured callback; `getVisibleRange` remains 12. Results are `/tmp/manicule-reader-js-complexity.csv`. Native read-only components, formats, dependencies, and deployment targets remain unchanged. New record fields and text-anchor cases require updated app instances to participate fully; legacy stored records are accepted, but older binaries cannot provide the new session-revocation guarantees.


## App-icon changes and Settings dismissal (September 10)

The reported Ochre freeze concerns Manicule, not Pilcrow. The current iOS source already serialized icon requests, but started `UIApplication.setAlternateIconName` while the Reading Settings sheet was still presented. A focused iPhone simulator test reproduced the reported interaction: after changing from Ochre to Indigo and acknowledging SpringBoard's icon notice, Done did not return an interactive library. The recorded baseline failure is `Done must dismiss Settings during an icon change` in `build/icon-freeze/baseline-done-summary.json`. Main-thread samples around the investigation showed a servicing run loop rather than an editor/parsing loop; they do not establish the internals of UIKit's presentation failure. Initial automation also needed corrections for an invalid XCTest toolbar hit point, virtualized form rows, and the system-owned icon notice. Those harness failures are not counted as application defects.

Selecting an app icon now dismisses Settings before the originating library window starts the system icon request. The sheet's dismissal callback queues a main-actor task, so UIKit's new presentation begins outside SwiftUI's dismissal callback. No arbitrary delay, timeout, private API, icon-service replacement, or document change was added. The chosen request stays with its originating window. Ordinary Reading Settings still use Done as before; choosing an icon closes Settings automatically.

Removed the shared icon-error property and its alert from Reading Settings. The icon model now throws failures while retaining the last confirmed icon and clearing its busy state. The originating library window owns the error alert, so a dismissed sheet cannot hide the failure and other windows do not share its error presentation. The existing guard against concurrent requests remains. The library Settings button also now has an explicit accessibility label and identifier.

The current Ochre Home Screen and in-app image files were already byte-identical white-hand artwork. The Burgundy and Indigo pairs also match. `build/icon-freeze/artwork-audit.json` records these comparisons; no artwork was regenerated. The UI regression checks that Ochre remains selected after relaunch. These checks do not establish which older icon image was cached on the user's physical device.

A separate **Manicule UI Tests** scheme and one focused UI test were added without changing the ordinary Mac/iOS unit-test scheme. The updated iPhone iOS 27 simulator workflow passed: Ochre → Indigo → Ochre, automatic Settings dismissal before the system notice, reopening Settings, using Done, and retaining Ochre after relaunch. No original books were opened or changed. The test runs on a disposable simulator. Physical-device installation/interaction and Mac/visionOS builds are not claimed for this iOS-specific follow-up; deployment targets and reader platforms remain unchanged.

Lizard 1.24.0, with the same Swift function scan before and after, measures `AppIconStore.change` at CCN 3 → 2; the new `changeAppIconAfterSettingsDismissal` measures 3. Error handling moved to its presenting window, so this is not a claim that total decision complexity decreased. The principal improvement is a sequential presentation lifetime and explicit error ownership. The scan does not fully model SwiftUI result-builder closures.

The four focused icon-state unit tests also passed: serialized requests, success-only selection changes, failure propagation with retry, and primary-icon/no-op/unsupported behavior. No unrelated unit suites were repeated. Scoped `git diff --check` passes. After extracting the result summaries, the temporary simulator, DerivedData, app binaries, and result bundles were removed. Only source/tests and text/image diagnostic evidence remain in this increment; no archive or device installation was created.

## Shared Foliate reader and engineering review (October 17, 2026)

EPUB, plain text, and Markdown now use `FlowingReaderView` and the same Foliate layout, settings, search, and narration bridge. `FlowingContent` distinguishes publication preparation. `TextPreparation` writes a small JSON manifest and complete HTML sections; `text-book.js` supplies those sections directly to Foliate's book interface. No synthetic EPUB archive or new dependency is required. PDFKit and native comic rendering retain their existing paths.

The review covered the changed reader, preparation, navigation, persistence integration, resource routing, and shared typography. The changes address these findings:

- **Duplicated behavior and state:** deleted the separate text reader UI, native text-chunk display path, custom text pagination JavaScript, text-only search implementation, alternate CSS generator, and obsolete bridge fields and methods. One reader owns shared controls and state. The app source falls from 21,269 to 19,111 physical lines across Swift, JavaScript, and HTML, including vendored JavaScript but excluding downloaded packages, tests, and Quick Look. This is a maintenance-size measurement, not a complexity or speed score.
- **Large-file layout:** generated text targets sections of about 64 KiB of HTML at complete block boundaries. Long raw lines are sliced with UTF-16 source offsets. Lists, tables, and fenced Markdown code remain complete even when an individual block exceeds the target. Foliate renders one section at a time. There is no whole-publication DOM cache; restoration may inspect additional sections one at a time when reflow moved the quoted passage. Generation remains off the main actor, checks cancellation between work units, and publishes only successfully written files under a temporary-directory lease.
- **Position compatibility:** text still saves source-line/passage anchors and reads legacy fractional positions. It does not persist Foliate CFIs for generated text, whose DOM changes between raw/rendered Markdown and reflow settings. Source offsets disambiguate slices of newline-free files. Repeated quotes prefer the occurrence nearest the saved offset to avoid cumulative backward drift. EPUB continues to use its existing CFI representation.
- **Resource ownership and origin:** generated publications share the trusted reader host's custom-scheme origin. Their route resolves within the active leased directory, using the existing traversal and symlink checks. Relative Markdown images retain the separately bounded source-document directory route. Generated documents retain a content security policy disabling publication scripts. Outstanding native resource reads retain their routing snapshot and lease.
- **Bridge arguments and lifecycle:** file selection, CSS, search strings, navigation targets, and source anchors pass as structured WebKit arguments. They do not require hand-escaped executable JavaScript. Completions from replaced or closed publications are ignored. Layout options are applied before initial restoration, and initial relocation messages are withheld until the requested navigation finishes.
- **Persistence traffic:** automatic positions are debounced for one second during navigation and flushed when the reader disappears. Existing reading-session revocation and cloud merge behavior remain in the persistence layer.
- **Uniform typography without flattening structure:** one CSS generator controls font, line height, justification, and theme across flowing formats. Headings keep relative sizes; inline spans inherit surrounding sizes. Foliate owns one/two-page margins, resizing, scrolling, and pagination. EPUB chapter controls are omitted for generated text sections.

Validation uses actual WebKit/Foliate frames through the native scheme handler. Tests cover visible passage restoration across raw/rendered Markdown, one/two-page and scrolling layouts, reflow, newline-free Unicode offsets, legacy percentages, typography, headings, themes, margins, search, narration text extraction, empty text, EPUB rendering and invalid-CFI fallback, cancellation, complete Markdown blocks, and resource traversal. The iPhone geometry assertion waits for the requested passage to become visible after asynchronous WebKit layout; an immediate first-relocation assertion was premature. It still fails if that passage does not become visible within eight seconds.

A 3,168,888-byte text fixture verifies multiple sections, one active rendered section, and navigation to 90 percent. In one macOS Debug run, preparation took 0.188 seconds and initial load plus navigation took 0.278 seconds. These are local observations, not comparative benchmarks or peak-memory measurements. Manual macOS checks used a disposable Markdown fixture to inspect live font size, line spacing, margins, justification, two-page layout, and repeated raw/rendered switching. Original books were not used for manual checks.

Remaining limits: generated text now uses Foliate's section-based scrolling and section navigation, including internal boundaries in long documents. A single very large Markdown block can still exceed the section target. EPUB is still parsed/extracted by Swift and separately opened from its archive by Foliate; removing that duplication is a separate change. Physical-device audio, real cross-device iCloud delivery, and visionOS runtime interaction were not verified. No dependency rewrite, commit, installation over the user's existing app, or distribution was performed.

Final checks:

| Check | Result |
| --- | --- |
| macOS Debug unit and integration suite | 119 tests passed |
| iPhone 17 Pro simulator, iOS 27.0, unit and integration suite | 141 tests passed |
| macOS Release app and Quick Look build | Passed |
| iOS simulator app and Quick Look build | Passed |
| visionOS simulator app and Quick Look build | Passed; no visionOS runtime was available for interaction |
| JavaScript module syntax and `git diff --check` | Passed |

The disposable iPhone simulator was removed after validation. Build products and test results are under `/tmp/manicule-foliate-{build,ios,vision}`; logs are `/tmp/manicule-foliate-{finaltest,iostest,release,ios,vision}.log`. The existing installed macOS app was not replaced.
