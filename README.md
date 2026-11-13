# JellyfinClient (iPhone)

Native SwiftUI client for [Jellyfin](https://jellyfin.org) servers (10.9+). iOS 18+, no third-party dependencies.

## Features

- **Login** – server address (`192.168.1.10:8096`, `https://…`, pasted web URL), username/password; session token stored in the Keychain.
- **Browsing** – Continue Watching, libraries (movies, shows, folders), posters with paging, series → seasons → episodes, watched/progress badges.
- **Playback** – system player (AVPlayer) with PiP and AirPlay. The server decides via `PlaybackInfo`:
  direct play for MP4/MOV (H.264/HEVC) under the limit, otherwise HLS remux/transcode. Start/progress/stop are reported so resume positions sync.
- **Transcoding in 0.5 Mbit/s steps** – "Original" or a limit from 0.5 to 120 Mbit/s (stepper + slider). Default in Settings, overridable per title. Resolution is capped automatically at low bitrates.
- **Downloads** – original file or server-transcoded H.264/AAC MP4 at a chosen bitrate (0.5 steps), with progress, poster, size estimate and offline playback.

## Run

```bash
open JellyfinClient.xcodeproj
```

Pick an iPhone simulator or your device and press ⌘R. For a real device, select your team under *Signing & Capabilities* and change the bundle ID (`com.example.JellyfinClient`).

Server-side permissions needed per user: *Allow video playback that requires transcoding* (transcoded playback/downloads) and *Allow media downloading* (original downloads).

## Layout

| Folder | Contents |
| --- | --- |
| `App/` | App entry, `AppModel` (session), root/tab views |
| `Core/` | `JellyfinAPI` (REST client), models, device profile, bitrate helpers, Keychain storage |
| `Playback/` | `PlaybackCoordinator` – PlaybackInfo, player presentation, progress reporting |
| `Downloads/` | `DownloadManager` – URLSession downloads + index in `Documents/Downloads` |
| `Views/` | SwiftUI screens and shared components |

New Swift files dropped into `JellyfinClient/` are picked up by Xcode automatically (folder-synchronized group).

## Known limitations (next steps)

- Downloads stop if the app is closed (no background `URLSession` yet); they're marked "Interrupted" and can be restarted.
- No audio/subtitle track picker yet; music, live TV and photo libraries are hidden.
- Offline watch progress isn't synced back to the server.
- Debug builds accept `JF_DEBUG_SERVER`, `JF_DEBUG_USER`, `JF_DEBUG_PASSWORD` launch environment variables to prefill the login form (used for automated simulator tests; not compiled into Release).
