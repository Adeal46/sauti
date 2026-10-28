# Wolf Companion

An on-device "read it to me" app for iPhone. Import a PDF, scan printed pages, or save a
web article, and Wolf Companion reads it aloud with a natural neural voice. The voice, text
recognition and article extraction all run on the phone.

| Feature | How it works |
|---|---|
| Neural voices (11) | Kokoro-82M (int8) via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), bundled in the app |
| PDFs | PDFKit text, with OCR for scanned pages that have no text layer |
| Camera scans | VisionKit document scanner + Apple Vision text recognition |
| Web articles | Downloaded once, cleaned with Mozilla Readability, then read offline |
| Share from Safari | Share → Wolf Companion saves the link; the app imports it when opened |
| Player | Sentence highlighting, auto-scroll, 0.75×–3× speed, lock-screen controls, background audio |

## Build it (no Mac needed)

GitHub builds the app for you on a cloud Mac.

1. **Create a repository.** On GitHub, create a new repository called `sauti`. A
   **public** repository gets unlimited free Mac build minutes; a private one works
   too but each build uses about 10× its minutes from your monthly allowance.
2. **Upload the project.** Unzip the project zip, then on the repository page choose
   **Add file → Upload files** and drag in everything inside the project folder
   (including the hidden `.github` folder: if your file manager hides it, upload
   `.github/workflows/build-ipa.yml` separately with the same path). Commit to `main`.
3. **Wait for the build.** Open the **Actions** tab. "Build IPA" starts automatically
   and takes about 10–15 minutes the first time.
4. **Download the app.** Open the finished run and download **WolfCompanion-ipa** from the
   Artifacts section. Unzip it to get `WolfCompanion.ipa` (about 105 MB, mostly the voice). `WolfCompanion-no-extension.ipa` is the same app without Share → Wolf Companion, for signing tools that reject extensions.

If the build fails, download **build-log** from the same run and share the lines
containing `error:`.

## Install it on your iPhone (Windows PC)

1. Install [Sideloadly](https://sideloadly.io) and iTunes (the version from Apple's
   website, not the Microsoft Store).
2. Connect your iPhone by USB and tap **Trust** on the phone.
3. Drag `WolfCompanion.ipa` into Sideloadly, enter your Apple ID, and click **Start**.
4. On the iPhone:
   - **Settings → General → VPN & Device Management** → tap your Apple ID → **Trust**.
   - **Settings → Privacy & Security → Developer Mode** → turn on, restart, confirm.
5. Open Wolf Companion.

With a free Apple ID the app stops opening after **7 days**; plug in and click Start
in Sideloadly again (your library is kept). A paid Apple Developer account
($99/year) extends that to a year.

If Sideloadly reports an App ID limit or an error about the share extension, open its
Advanced Options and tick **Remove app extensions**. Everything except "Share →
Wolf Companion" still works; use **+ → Add web article** instead.

## Using it

- **+** adds a PDF or text file, a camera scan, a web article, or pasted text.
- Tap any paragraph to start reading from there.
- The voice and speed buttons sit either side of the play button. Speed changes
  apply instantly.
- In Safari, **Share → Wolf Companion** saves the current page. Open Wolf Companion and it's imported.
  (If your install has no shared container, the link is copied instead and a
  "Paste" banner appears in the app.)
- The first play after launching takes a few seconds while the voice loads.

## Project layout

```
App/Sources/
  Speech/      PlaybackController (generate-ahead + AVAudioEngine), Kokoro and iPhone voices
  Import/      PDF + OCR, scans, web articles, ImportCoordinator
  Text/        Sentence splitting, number normalization, PDF line reflow
  Views/       Library, reader + player controls, settings, add sheets
ShareExtension/  "Share → Wolf Companion"
Shared/          Hand-off inbox used by the app and the extension
project.yml      XcodeGen spec (the .xcodeproj is generated in CI)
scripts/fetch-models.sh   Downloads the Kokoro model during the build
```

## Licenses

Wolf Companion's own code is yours. It bundles: the Kokoro-82M model (Apache 2.0),
sherpa-onnx (Apache 2.0) and Mozilla Readability (Apache 2.0).
