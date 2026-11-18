# Macoid 4.1 - a macOS-style terminal for Android, with a real Linux inside

Macoid gives you a Mac-like shell on Android: real `git`, a GitHub CLI (`gh`), macOS commands (`open`, `pbcopy`, `defaults`,
`sw_vers`, `sysctl`, `osascript`, ...) and a **real Linux (Debian by default) running locally on the phone**. Everything you
install or run - `python`, `pip`, `node`, `gcc`, `ffmpeg`, `apt`, ... - runs in that Linux. **Only the Apple tools (`swift`, `xcodebuild`,
`xcrun`, `codesign`, `simctl` ...) run on a GitHub runner - everything else stays on the phone.**
Info: Unpack workflow is for unpacking zip file that contains in the code, so if you modified some of the code. and you just too lazy to unpack it, run that workflow.

## Build the app
1. Push this folder to a GitHub repository or fork it (i'll give access).
2. **Actions -> Build APK** -> download the `Macoid-apk` artifact (`app-debug.apk`) and install it
   (allow installs from unknown sources). Or open the folder in Android Studio and run *Build > Build APK*.
3. Every build is signed with the same key (`app/macoid.keystore`), so you can install a new APK **over** the old one and
   keep everything you installed.

(That workflow compiles the Macoid app itself. At run time the app only calls GitHub Actions for the Apple tools, see below.)

## What runs where
| Layer | What | Where it runs |
|---|---|---|
| Native | `git` (JGit), `gh`, `curl`, `wget`, `zip`, `unzip`, `host/dig/nslookup` | on your phone |
| macOS emulation | `open pbcopy pbpaste say afplay osascript defaults sw_vers sysctl system_profiler scutil pmset ioreg vm_stat diskutil ifconfig networksetup launchctl mdfind mdls ditto trash tree md5 shasum uuidgen brew man softwareupdate xcode-select caffeinate` | on your phone (reads real Android data) |
| Real Linux | `python pip node npm gcc clang make cmake cargo go ruby ssh rsync tmux ffmpeg jq ...` and every package of the distro | on your phone, inside proot |
| Apple stand-ins | `plutil PlistBuddy lipo otool install_name_tool dwarfdump sips` | on your phone (python / LLVM / ImageMagick in the Linux) |
| Apple tools | `swift swiftc xcodebuild xcrun codesign simctl ibtool actool productbuild pkgbuild notarytool ...` | **GitHub runner** (Ubuntu for plain Swift, macOS for Xcode / Apple frameworks) |

## The Linux (`lx`, `pkg`)
```
lx                       # a shell in the real Linux (bash, apt, python, pip, git already there)
lx <cmd> ...             # run one command there
pkg install python ffmpeg jq     # or: apt install ... / brew install ...
pip install requests     # local pip;   also npm / yarn / pnpm / gem / cargo / go
pkg doctor               # status
```
* First use downloads the proot engine (~1 MB) and the root filesystem (Debian ~30 MB), unpacks it and installs the **base set**:
  `python3 pip venv git curl wget ca-certificates openssh-client` (`MACOID_LX_BASE=none` skips it, `MACOID_LX_BASE="a b c"` replaces it;
  `pkg setup` retries it). `python`, `python3`, `pip`, `pip3`, `git`, `curl`, `ssh` work right away afterwards.
* Known commands install themselves on first use (`gcc`, `node`, `cargo`, `go`, `ffmpeg`, `tmux` ...). Other packages: `pkg install <name>`.
* Inside the Linux shell `pkg install / remove / search / update` works too (same verbs).
* Installed commands are on `PATH` at once (launchers in `$MACOID/linux/wrap`), also in scripts and pipes.
* Everything lives in the app's private storage (`$MACOID/linux`) and survives restarts and updates signed with the same key.

### Distros
| `pkg distro ...` | what | package manager |
|---|---|---|
| `debian` (default) | Debian 13 "trixie", glibc: normal pip wheels, normal binaries | `apt` |
| `alpine` | Alpine, musl, very small (installs made by Macoid 3.x stay Alpine) | `apk` |

Each distro keeps its own files; switching does not delete the other. Override for one command: `MACOID_DISTRO=alpine pkg install jq`.

### Architectures (`pkg arch ...`)
The Linux uses **the phone's own CPU**, picked automatically:

| phone | Linux arch |
|---|---|
| arm64 / aarch64 (nearly every phone) | `arm64` |
| 32-bit ARM (armv7 / armv8l userland) | `arm` |
| x86_64 (emulators, Chromebooks) | `x86_64` |

There is **no "arm128"**: no such CPU architecture exists. `pkg arch arm64|arm|x86_64|default` picks another one; a different
architecture than the phone's runs through qemu-user, which you must provide yourself as a static binary at
`$MACOID/linux/qemu/qemu-<arch>` (experimental, not included).

## Build projects
```
cd myproject
macoid build               # auto-detects the project type, builds ON THE PHONE
macoid build python --entry app.py
```
Targets: `node python go rust cmake maven gradle-java`. Results land in `./build-output`.
Apple targets build on a GitHub runner: `macoid build swift` (Ubuntu, or macOS when the code imports SwiftUI/UIKit/AppKit ...), `swift-mac`,
`ios` (unsigned `.ipa`, `--scheme name` to pick the scheme), `macos` (`.app`).
Not possible (need Android SDK / .NET / Flutter / Electron): `android-apk android-aab flutter-apk electron dotnet`.

## Apple tools on a GitHub runner
```
gh auth login                       # once; token scopes: repo + workflow
cd MyApp && xcodebuild -scheme MyApp -sdk iphonesimulator build
swift build                         # swift / swiftc / swift run|test|package, xcrun, codesign, simctl ...
```
* Only the Apple tools go to a runner. The current folder is zipped and pushed as a throw-away branch of a private repo
  `<you>/macoid-cloud` (created on first use); the push starts the workflow, the log and every new/changed file come back
  into the current folder, then the branch and the run are deleted. Paths in arguments are relative to the current folder.
* `swift*` runs on Ubuntu (cheap, boots in seconds) and is repeated on macOS automatically when the code needs an Apple framework.
  `MACOID_SWIFT=ubuntu|macos` forces one, `MACOID_SWIFT=local` uses a Swift toolchain installed in the phone's Linux.
* `MACOID_XCODE=16.2` picks the Xcode version, `MACOID_MAC_RUNNER=macos-15` the runner image, `MACOID_MAC_RETURN=all|none` what comes back
  (default: new/changed files without `.build`, `DerivedData`, `Pods`), `MACOID_MAC_EXCLUDE="dir1 dir2"` leaves folders out of the upload (limit ~95 MB),
  `MACOID_MAC_ENV="VAR1 VAR2"` forwards environment variables, `MACOID_XCODEBUILD_RAW=1` stops Macoid adding `-quiet`.
* SwiftPM / CocoaPods downloads are cached between jobs, results and zips are never downloaded twice, and a dropped connection resumes.
* macOS runner minutes count 10x on GitHub's free plan; Ubuntu runs count 1x.

## Getting started with GitHub
```
gh auth login                 # paste a token (scopes: repo, workflow). It also sets git user.name/email.
git clone you/project         # shorthand for https://github.com/you/project.git
git add -A && git commit -m "change" && git push
gh repo create myapp --private --source . --push
gh pr create -t "My PR"
```
Authentication is HTTPS + token only (no SSH). `git` and `gh` are only for working with your repositories; they do not run anything remotely.

## Skills
Skills are installable packages: a folder with a `SKILL.md` (front matter: `name`, `description`, optional `run`),
scripts, and an optional `bin/` folder whose files become shell commands.
```
skill examples                          # built-in skills
skill install builtin:hello-cmd         # adds a `hello` command (works right away)
skill install owner/repo                # from GitHub (repo may hold many skills), also owner/repo/subfolder
skill install https://.../pack.zip      # or a local .zip / ./folder
skill list | info <name> | run <name> [args] | update | remove <name>
skill new my-skill                      # scaffold your own, then: nano ~/.macoid/skills/my-skill/SKILL.md
skill search backup                     # GitHub repos tagged with the topic "macoid-skill"
```
Built-ins: `hello-cmd` (template), `repo-backup` (zip the current folder to ~/storage/Download).
Macoid has no AI model on the phone, so a skill here is an installable command package, not a prompt.

## Root
Macoid cannot root a phone - it uses `su` on a phone that is **already rooted** (Magisk, KernelSU, APatch ...).
* `#` button: new root session (approve the su prompt). `tsu`: root shell from a normal tab. `sudo <cmd>`: one command as root.
* `macoid root status` tests su; `macoid root fixperms` hands the app folder back to the app user after root work.
* `edit <file>` opens root-only files too (saves through su).

## Editing & storage
* `nano|vi|vim|edit <file>` opens a built-in editor screen.
* `setup-storage` requests storage permission; shared storage is at `~/storage`.
* Tab completes file names (shell-native), Ctrl-C works like a normal terminal, arrow keys/history work.

## Limits (honest list)
* The Linux runs in **proot**, not as a real kernel: no `systemd`, no Docker, no mounting, no raw network tools needing real root,
  and syscall-heavy programs are slower than native. `/proc` is the phone's own.
* Darwin (macOS) binaries cannot run on the phone; `xcodebuild`, `codesign`, `simctl` and iOS/macOS builds run on a GitHub runner (see above) and need internet + a GitHub login.
* No GUI apps. SSH works (`ssh` installs on first use).
* This was written without being run on a phone: the Linux engine was smoke-tested on a PC (Debian 13 x86_64 + proot), the app
  itself and the Android side (proot on your CPU/ROM, seccomp) still have to be tried on your device. `pkg doctor` / `macoid doctor` show the state.
