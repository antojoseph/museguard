# Local download inspection

Muse checks Chrome download metadata when a download starts, then inspects the completed file locally. The extension sends metadata through the existing native bridge. File bytes never enter the bridge, model prompt, or cloud service.

The extension briefly pauses a transfer while checking its metadata when Chrome permits it. A high-confidence finding keeps Muse's pause until the user explicitly chooses Resume or Cancel in the avatar's warning. Acknowledging the warning does not resume it. Chrome's own danger protection remains in control: Muse never calls `acceptDanger`, opens a payload, mounts an image, or automatically removes a file. A disconnected app releases an ordinary transfer without calling it safe.

Small downloads can finish before Chrome allows them to be paused. Completed-file inspection cannot guarantee that a file was prevented from being saved or opened by another application. This is download inspection rather than system-wide on-access antivirus protection.

## Install the local malware engine

On the source-release Mac, run:

```sh
scripts/setup-download-scanner.sh
```

No Homebrew, password, system installer, service, or root access is required. The script downloads the official ClamAV 1.5.4 universal macOS package from `www.clamav.net`, checks its pinned SHA-256 and Apple-trusted Cisco installer signature (team `DE8Y96K9QP`), then expands the payload without executing installer scripts. It preserves the packaged certificate and license, changes fixed library search paths to loader-relative paths, and ad-hoc signs those modified local copies. `PROVENANCE.txt` records the original package, checksum, source link, and modification. Those relocated copies do not retain Cisco's application signature.

The engine goes in `~/Library/Application Support/MuseGuard/DownloadScanner/clamav`. FreshClam downloads and verifies the official signature databases in the adjacent `database` directory. The updater uses the included ClamAV CVD trust certificate for both download verification and database load testing. It never disables signature or TLS verification. It makes one update attempt and respects the updater's stored cooldown after a CDN error.

Update definitions using:

```sh
scripts/setup-download-scanner.sh --update-only
```

After setup, Muse checks for official definition updates in the background at startup and once a day while protection is enabled. Update attempts and successes are persisted; failures, app restarts and Pause do not reset the 24-hour throttle. Pause cancels Muse's updater, and Resume waits for the next eligible update window. FreshClam's own persisted CDN cooldown also remains in force. Only short update-status messages enter Recent activity; full updater output and downloaded files do not enter the model.

Maintenance uses only the configured Muse-local `freshclam`, existing configuration and packaged CVD trust certificate. It requires the official mirror and rejects execute hooks, custom URLs, duplicate settings and unknown configuration directives. The background network request downloads malware definitions from ClamAV; it uploads no inspected files. The command above remains available for a manual definition refresh. A missing or failed database is reported as unavailable; an aged-database warning makes coverage limited. The app also recognizes a scanner bundled in `Contents/Helpers/clamav`, or an existing Homebrew scanner. Bundled and Muse-local engines use the user-local database directory; Homebrew uses its own configuration and updater.

For an already downloaded official package, `--package /absolute/path/to/clamav-1.5.4.macos.universal.pkg` avoids another package download while performing the same checks. `--no-update` installs only the engine and explicitly reports that definitions have not been updated. No scanner binaries or databases are checked into Git.

## Coverage and bounds

Completed files must be regular files beneath the user's Downloads directory, or a directory explicitly passed to `DownloadInspector`. Canonical paths and descriptor identity are checked; symlinks and paths outside those roots are refused. Reading, hashing, and ClamAV scanning use an open file descriptor. Size, modification time, inode and change time are checked again before a result is accepted. A changed file never receives a clean result.

Default limits are 256 MiB per file, 512 MiB total expanded archive content, 1,000 archive entries, 12 recursive levels in ClamAV, and 45 seconds for a scanner process. One scanner runs per inspector instance to bound memory usage. Pause and request cancellation terminate an active scanner. Metadata checks remain independent of that scanner slot.

The static ZIP inspection does not extract files. It bounds the central directory to 4 MiB and checks local/central filenames, Unicode path overrides, traversal, duplicate entries, symbolic links, encryption, expansion ratios and suspicious embedded executable names. Unsupported ZIP64, corrupt, encrypted or excessive archives are limited rather than clean. Other archive payloads receive ClamAV's bounded local scan; disk images are not mounted.

Executable bytes disguised as a document, deceptive double extensions, concrete Chrome danger reports, archive traversal and actual malware signatures can trigger a warning. An unsigned executable, valid code signature, unusual extension, encrypted archive, or scanner limit is not itself proof of malware. Signature validity is reported separately from the malware result.

`scan_status` distinguishes `clean`, `infected`, `limited`, `error`, and `unavailable`. `clean` means the configured local engine completed its bounded scan without finding a known signature; it is not a guarantee of safety. The built-in detector recognizes only the harmless standard EICAR test pattern when ClamAV is unavailable and labels that narrow test detection explicitly.

HTTP URL credentials, query parameters and fragments are removed from download messages; blob URLs become their origin, and data/file URL contents are omitted. A completed local file can still be inspected when its URL is omitted. Only completed-file requests contain the local file path. Paused download IDs and opaque command tokens are stored in Chrome session storage to recover after a service-worker restart. A transport or unavailable-scanner result remains pending, with at most two delayed retries while the worker remains alive; Pause cancels those retries. Worker recovery also reattaches pending completed inspections.

## Verification

```sh
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -warnings-as-errors \
  -o build/download-inspection-checks Tests/DownloadInspectionChecks.swift \
  Sources/SentinelPet/Downloads/*.swift Sources/SentinelPet/Risk/RiskVerdict.swift
./build/download-inspection-checks
node --test BrowserExtension/tests/downloads.test.cjs
```

After installing real definitions, also run:

```sh
./build/download-inspection-checks --real-clamav
```

The optional `MUSE_CLAMAV_BINARY` and `MUSE_CLAMAV_DATABASE` environment variables select an explicit engine/database for this test. It verifies both the harmless EICAR antivirus test string and an ordinary local text file; it never downloads or runs live malware. The normal tests cover denied paths, FIFO/symlink rejection, changed-file detection, deceptive content, bounded archive handling, scanner limits/errors/timeouts/cancellation, global Pause, owned-pause recovery and explicit command tokens. Fake scanner scripts are confined to a temporary test directory and do not stand in for the real-engine test.

## Official references

- [Chrome downloads API](https://developer.chrome.com/docs/extensions/reference/api/downloads)
- [ClamAV official downloads](https://www.clamav.net/downloads)
- [ClamAV scanning limits and behavior](https://docs.clamav.net/manual/Usage/Scanning.html)
- [FreshClam configuration](https://docs.clamav.net/manual/Usage/Configuration.html)
- [FreshClam errors and CDN cooldowns](https://docs.clamav.net/faq/faq-freshclam.html)

The setup fetches upstream software for the local user's use. A distributor who bundles ClamAV must preserve its license and satisfy its corresponding-source and bundled-component license obligations. The package's GPL license and upstream source URL are retained beside the engine.
