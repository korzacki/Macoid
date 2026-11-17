---
name: repo-backup
description: Zip the current folder (without .git) into ~/storage/Download with a date stamp
run: run.sh
---

# repo-backup

Run it inside any project folder: `skill run repo-backup`. Needs `setup-storage` once so that
`~/storage/Download` is writable. The archive is named `<folder>-YYYYMMDD-HHMM.zip`.
