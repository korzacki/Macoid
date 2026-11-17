---
name: apk-release
description: Build the Android project in this folder on GitHub Actions and copy the APK to ~/storage/Download
run: run.sh
---

# apk-release

Run inside an Android project: `skill run apk-release`. Needs `gh auth login` and `setup-storage`.
Uses `macoid build android-apk`, then copies every APK it produced into `~/storage/Download`.
