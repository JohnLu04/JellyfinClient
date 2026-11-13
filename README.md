# JellyfinClient (iPhone)

Native SwiftUI client for [Jellyfin](https://jellyfin.org) servers (10.9+). iOS 18+, no third-party dependencies.

## Features

- **Login** – server address (`192.168.1.10:8096`, `https://…`, pasted web URL), username/password; session token stored in the Keychain.
- **Browsing** – Continue Watching, libraries (movies, shows, folders), posters with paging, series → seasons → episodes, watched/progress badges.
- **Two players, switchable any time in Settings:**
  - **mpv** (default, via [MPVKit](https://github.com/mpvkit/MPVKit), LGPL) – plays almost every format directly (MKV, HEVC, AV1, DTS, PGS …). In-player menus for **all audio tracks and subtitles**: embedded tracks switch instantly, external/text subtitles are loaded from the server, and while transcoding a switch fetches a new stream at the current position.
  - **Apple player** (AVPlayer) – PiP and AirPlay; anything the iPhone can't play natively is transcoded by the server.
- **Audio & subtitle choice** on every title page (server defaults pre-selected), used by both players.
- The server decides via `PlaybackInfo` (with a device profile per player): direct play when possible, otherwise HLS remux/transcode. Start/progress/stop (incl. selected tracks) are reported so resume positions sync.
- **Transcoding in 0.5 Mbit/s steps** – "Original" or a limit from 0.5 to 120 Mbit/s (stepper + slider). Default in Settings, overridable per title. Resolution is capped automatically at low bitrates.
- **Downloads** – original file or server-transcoded H.264/AAC MP4 at a chosen bitrate (0.5 steps), with progress, poster, size estimate and offline playback.

## Run

```bash
open JellyfinClient.xcodeproj
```

Pick an iPhone simulator or your device and press ⌘R. For a real device, select your team under *Signing & Capabilities* and change the bundle ID (`com.example.JellyfinClient`).

Server-side permissions needed per user: *Allow video playback that requires transcoding* (transcoded playback/downloads) and *Allow media downloading* (original downloads).

## Releases (IPA)

Unsigned IPAs for sideloading (AltStore, SideStore, Sideloadly) are attached to [GitHub releases](../../releases).

- **New release:** `git tag v0.2.0 && git push origin v0.2.0` – the *Build IPA* workflow builds the IPA (version taken from the tag) and creates the release.
- **Test build:** Actions → *Build IPA* → *Run workflow*; the IPA is kept as a workflow artifact for 14 days.
- **Locally:** `scripts/build-ipa.sh [version] [build-number]` → `build/ipa/`.

## Layout

| Folder | Contents |
| --- | --- |
| `App/` | App entry, `AppModel` (session), root/tab views |
| `Core/` | `JellyfinAPI` (REST client), models, device profile, bitrate helpers, Keychain storage |
| `Playback/` | `PlaybackSession` (PlaybackInfo → stream URL), `PlaybackCoordinator` (presentation, reporting), `NativePlayerEngine` (AVPlayer) |
| `Playback/MPV/` | `MPVCore` (libmpv wrapper, Metal/MoltenVK rendering), `MPVPlayerController` (state + track switching), `MPVPlayerView` (controls) |
| `Downloads/` | `DownloadManager` – URLSession downloads + index in `Documents/Downloads` |
| `Views/` | SwiftUI screens and shared components |

New Swift files dropped into `JellyfinClient/` are picked up by Xcode automatically (folder-synchronized group).

## Known limitations (next steps)

- Downloads stop if the app is closed (no background `URLSession` yet); they're marked "Interrupted" and can be restarted.
- mpv has no Picture in Picture / AirPlay (use the Apple player for that); music, live TV and photo libraries are hidden.
- The first build downloads MPVKit's prebuilt frameworks (~1 GB, cached afterwards).
- Offline watch progress isn't synced back to the server.
- Debug builds accept `JF_DEBUG_SERVER`, `JF_DEBUG_USER`, `JF_DEBUG_PASSWORD` launch environment variables to prefill the login form (used for automated simulator tests; not compiled into Release).
