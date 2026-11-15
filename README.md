# JellyfinClient (iPhone)

Native SwiftUI client for [Jellyfin](https://jellyfin.org) servers (10.9+). iOS 18+, no third-party dependencies.

## Features

- **Login** – server address (`192.168.1.10:8096`, `https://…`, pasted web URL), username/password; session token stored in the Keychain.
- **Home** – full-width hero carousel (artwork, title logo, genres, age rating, "Play S3 · E2", favorite heart), Continue Watching and Next Up with series artwork, Recently Added per library, libraries.
- **Title pages** (movies, series, episodes) – muted inline trailer in the header (German trailers preferred; YouTube via embedded player or local trailer files), Play/Resume and Download, description, cast, Favorite, Share (IMDb link), audio & quality options, Download Season, Episodes / More Like This tabs.
- **Tabs** – Home, Favorites (favorite movies, series and episodes), Library and Request; Downloads and Settings open from buttons at the top right.
- **Search** – separate magnifying-glass button at the bottom right (iOS 27 `prominent` tab role, `search` role before). Finds movies and series in your libraries and, with Seerr connected, suggests matching titles you don't have yet (deduplicated by TMDB id / title + year) to request.
- **Browsing** – libraries (movies, shows, folders), posters with paging, watched/progress badges.
- **Request (Seerr)** – the Seerr integration from the Servarr app: Movies/Series filter, requests card (pending count; approve/decline/delete, new request search), networks (Netflix opens with Netflix's weekly Top 10 for Germany), Trending / Popular / Upcoming / Top Rated rows with "See All" lists (sort, genre, hide available), search, and title pages with IMDb/Rotten Tomatoes/TMDB ratings, streaming availability (JustWatch), seasons and episodes, and requests with season, server and quality-profile choice. Connect it under Settings → Seerr (address + API key, stored in the Keychain).
- **Two players, switchable any time in Settings:**
  - **mpv** (default, via [MPVKit](https://github.com/mpvkit/MPVKit), LGPL) – plays almost every format directly (MKV, HEVC, AV1, DTS, PGS …). In-player menus for **all audio tracks and subtitles**: embedded tracks switch instantly, external/text subtitles are loaded from the server, and while transcoding a switch fetches a new stream at the current position.
  - **Apple player** (AVPlayer) – PiP and AirPlay; anything the iPhone can't play natively is transcoded by the server.
- **Buffer** – Settings → Buffer: how many seconds are loaded ahead, 10 s to 10 min (mpv `cache-secs`/`demuxer-readahead-secs` within a RAM-based memory ceiling; `preferredForwardBufferDuration` for the Apple player).
- **Video details in mpv** – an info button in the player opens a live panel: play method, bitrate limit, container, file size, average/current bitrate, buffered seconds and size, download speed, codecs, resolution, frame rate, hardware decoding, dropped frames, audio channels and sample rate.
- **Audio & subtitle choice** on every title page (server defaults pre-selected), used by both players.
- The server decides via `PlaybackInfo` (with a device profile per player): direct play when possible, otherwise HLS remux/transcode. Start/progress/stop (incl. selected tracks) are reported so resume positions sync.
- **Transcoding in 0.5 Mbit/s steps** – "Original" or a limit from 0.5 to 120 Mbit/s (stepper + slider). Default in Settings, overridable per title. Resolution is capped automatically at low bitrates.
- **Downloads** – original file or server-transcoded H.264/AAC MP4 at a chosen bitrate (0.5 steps), with progress, speed, poster, size estimate and offline playback. Built like Streamyfin's native downloader: transfers run in a background `URLSession` (they keep going when you leave the app, lock the screen or iOS ends the app, and iOS relaunches the app to file them), one at a time from a persisted queue, with automatic retries that resume where they stopped when the server allows it. On iOS 26 a continued-processing task keeps the queue moving in the background. A notification tells you when a download finishes or fails.

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
| `Downloads/` | `DownloadManager` – background URLSession, queue, retries, index in `Documents/Downloads`; `DownloadKeepAlive` – iOS 26 continued-processing task |
| `Views/` | SwiftUI screens and shared components |

New Swift files dropped into `JellyfinClient/` are picked up by Xcode automatically (folder-synchronized group).

## Known limitations (next steps)

- Swiping the app away in the app switcher (force quit) pauses downloads until you open the app again; iOS doesn't let any app continue after that. They then resume automatically.
- mpv has no Picture in Picture / AirPlay (use the Apple player for that); music, live TV and photo libraries are hidden.
- The first build downloads MPVKit's prebuilt frameworks (~1 GB, cached afterwards).
- Offline watch progress isn't synced back to the server.
- Debug builds accept `JF_DEBUG_SERVER`, `JF_DEBUG_USER`, `JF_DEBUG_PASSWORD` launch environment variables to prefill the login form, `JF_DEBUG_SEERR` / `JF_DEBUG_SEERR_KEY` for the Seerr form and `JF_DEBUG_SEARCH` for the search field (used for automated simulator tests; not compiled into Release).
