macoid build android-apk || { echo "build failed" >&2; exit 1; }
out="$HOME/storage/Download"; [ -d "$out" ] || out="$HOME"
find build-output -name '*.apk' | while read f; do cp "$f" "$out/" && echo "APK saved: $out/$(basename "$f")"; done
