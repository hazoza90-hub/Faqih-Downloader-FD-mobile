# Faqih Downloader (FD) Mobile — Engineering Constitution

> CRITICAL RULES — MUST BE FOLLOWED IN EVERY BATCH AND COMMIT

## 1. Strict Single-Responsibility Principle (SRP)
- **Strictly 1 clear responsibility per source file** across `lib/` and `android/app/src/main/kotlin/`.
- **Target length**: `< 300` physical lines per file.
- **Hard ceiling**: `< 400` physical lines (`<= 400` lines; any file exceeding 400 lines fails verification).
- Group related files into focused subfolders rather than creating monolith files or catch-all utilities.
- Automated enforcement:
  ```bash
  dart run scripts/verify_srp.dart
  ```

## 2. Architecture & Folder Structure
- `lib/core/` — Pure domain layer and app foundation:
  - `config/` — Constants, immutable `AppSettings`, `SettingsRepository`.
  - `i18n/` — Locale definitions, Arabic/English string maps, reactive `AppTranslator`.
  - `theme/` — FD dark color palette (`AppColors`) and Material 3 `ThemeData` (`AppTheme`).
  - `models/` — Immutable data models with JSON serialization (`DownloadStatus`, `DownloadChunk`, `AudioTrack`, `SubtitleTrack`, `ClipRange`, `VideoFormatOption`, `YouTubeStreamInfo`, `HistoryEntry`).
  - `utils/` — Focused pure utilities (`filename_sanitizer`, `size_formatter`, `category_classifier`, `url_detector`, `unique_path_resolver`).
- `lib/engine/` — Multi-connection HTTP range download engine, rate limiter, chunk persistence.
- `lib/services/` — Media extraction coordinator, history persistence, clipboard/share intake.
- `lib/platform/` — MethodChannel / EventChannel contracts and Android Kotlin bridges.
- `lib/features/` — Feature-sliced UI screens, Kanban tabs (`Staged`, `Active`, `Vault`), bottom sheets, settings views.
- `lib/app/` — Root application widget (`FaqihDownloaderApp`) wiring theme and localization.

## 3. Prohibited Dependencies & Media Engine Policy
- **NEVER use `ffmpeg_kit_flutter`** (deprecated and removed from Maven Central).
- Media extraction and FFmpeg muxing/transcoding/trimming/subtitle-burning MUST be wired natively in Kotlin via `io.github.junkfood02.youtubedl-android:library` and `:ffmpeg` (starting in Batch 3).
- Keep dependencies minimal, maintained, and pinned cleanly in `pubspec.yaml`.

## 4. Build & Release Guardrails
- **NEVER** build release APKs/AABs (`flutter build apk --release`, `flutter build appbundle`) or upload binaries to GitHub Releases unless the user explicitly instructs you to do so.
- Always run the full fast verification gate before committing:
  1. `dart run scripts/verify_srp.dart`
  2. `flutter analyze`
  3. `flutter test`
