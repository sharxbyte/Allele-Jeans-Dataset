# Allele Collect

A Flutter app for collecting a consented body-measurement dataset for Allele Jeans (contact: Administrator@allelejeans.com).

Each participant:
1. Confirms they are 18 or older and are the person being scanned.
2. Signs the **Training Data Consent**, and optionally the **Dataset Licence and Trust Agreement** (`assets/legal/`).
3. Enters contact details.
4. Takes a front photo, a side photo and a ~22-second turning video, with the phone on a tripod and spoken guidance.
5. Gets the photos back with numbered yellow guide lines at each tape site, and fills in the tape table: body height, plus for each site the tape height, a relaxed reading and a snug reading.
6. Exports a folder and a `.zip`, and shares it with Allele.

This build has **no sign-in and no encryption**: exports are plain files meant to be sent to Allele.

## Download (Android)

Get the APK from the [Releases](../../releases) page. Allow "install unknown apps" when prompted.

## Build

Requires Flutter (stable channel, Dart ≥ 3.13).

```bash
flutter pub get
flutter test
flutter build apk --release          # Android
flutter build ipa --release          # iOS — macOS with Xcode only
```

### iOS notes (for the iOS developer)

| Setting | Value |
|---|---|
| Bundle ID | `com.allelejeans.collect` |
| Display name | Allele Collect |
| Minimum iOS | 15.5 (required by Google ML Kit pose detection) |
| Podfile | `ios/Podfile` (platform 15.5) |

- `Info.plist` already contains the camera usage text, plus `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`. Exports appear in the **Files** app under *On My iPhone › Allele Collect*, and can also be sent with the share sheet.
- No platform channel is needed on iOS. Hardware details fall back to defaults, and the video is exported raw. The Android-only `HardwareProfiler.kt` just adds lens intrinsics to the export.
- Distribution is via TestFlight. `codemagic.yaml` contains a ready-made workflow (cloud Mac build, then TestFlight upload) that needs an App Store Connect API key. Building locally in Xcode with your own signing works too.
- Test on physical devices: Google ML Kit pose detection does not run on the iOS simulator.

## Export layout

```
PARTICIPANT_ID/
  meta.json            height, weight, tape table, flags
  measurements.csv     number,id,label,tape_height_cm,relaxed_cm,snug_cm,note
  capture.json         phone tilt (gravity) log, lens info, pose keypoints
  front.jpg  side.jpg  front_annotated.jpg  side_annotated.jpg
  turn.mp4
  consent/             signed agreements (JSON + signature PNG + the exact text signed)
  contact/contact.json kept separate; never part of the dataset
```

## Legal

The agreements in `assets/legal/` are drafts pending attorney review. The app refuses to let anyone sign a document that still contains a "DECIDE BEFORE USE" marker.
