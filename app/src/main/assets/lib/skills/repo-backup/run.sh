name=$(basename "$PWD")
out="$HOME/storage/Download"
[ -d "$out" ] || out="$HOME"
zipfile="$out/$name-$(date +%Y%m%d-%H%M).zip"
tmp="$TMPDIR/backup.$$"; mkdir -p "$tmp"
for f in ./* ; do [ -e "$f" ] && cp -R "$f" "$tmp/"; done
( cd "$tmp" && zip -r "$zipfile" . ) >/dev/null && echo "Backup written: $zipfile" || echo "backup failed" >&2
rm -rf "$tmp"
