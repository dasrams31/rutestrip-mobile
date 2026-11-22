# RuteStrip Android

Flutter app for [RuteStrip](https://rutestrip.ai.id): find hiking trails on Java by
describing them in a sentence. Talks to the live JSON API (`/api/v1`, documented in
the backend repo at `docs/API.md`) and the shared SSO account API.

## Screens

- Search by sentence with the website's example searches.
- Results with the same ranking and plan sentences as the website.
- All trails, filtered by mountain or province.
- Trail page: OpenStreetMap map (flutter_map), numbers, Naismith note, elevation
  profile, similar trails, like.
- Log in and sign up (same account as the site and the chat), liked trails.
- Indonesian and English (ID | EN in every header).

## Build

Toolchain lives on D: (`D:\dev\flutter`, `D:\dev\android-sdk`, `D:\dev\jdk`), with
`GRADLE_USER_HOME` and `PUB_CACHE` under `D:\dev` as well.

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

The debug APK lands in `build\app\outputs\flutter-apk\app-debug.apk`.

Release APKs for testers (small, one per CPU type, signed with the debug key until a
Play Store key is decided):

```powershell
flutter build apk --release --split-per-abi --obfuscate --split-debug-info=build/symbols
```

## Testing against a local backend

Debug builds may talk plain HTTP to 127.0.0.1 only (`android/app/src/debug/res/xml`).
Run the Laravel backend locally (scripts in `D:\dev\rutestrip-local`), then:

```powershell
adb reverse tcp:8000 tcp:8000
```

```powershell
flutter run --dart-define=RUTESTRIP_API=http://127.0.0.1:8000
```

## Design

Follows the website's `DESIGN.md`: dark emerald header bands with the contour motif,
map-paper background, emerald for links and secondary buttons, dawn yellow only for
the one main action per screen, Barlow Condensed headings and Inter body text
(both SIL OFL, licenses in `assets/fonts`). The launcher icon is the website's PWA icon.
