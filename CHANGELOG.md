# Changelog

All notable changes to Macoid are documented here.

## [4.1] - 2026-11-18

### Added
- **Apple tools on a GitHub runner again - and only those.** `swift`, `swiftc`, `swift build|run|test|package`, `swift-format`,
  `xcodebuild`, `xcrun`, `codesign`, `simctl`, `ibtool`, `actool`, `momc`, `mapc`, `iconutil`, `productbuild`, `productsign`, `pkgbuild`,
  `notarytool`, `altool`, `stapler`, `xctrace`, `instruments`, `xcresulttool`, `xcstringstool`, `security` run on a runner
  (`lib/mac.sh`, workflow `lib/apple-job/apple.yml`). Everything else (pkg, pip, python, gcc, git ...) still runs on the phone.
  Swift goes to Ubuntu and is repeated on macOS when the code imports an Apple framework (`MACOID_SWIFT=ubuntu|macos|local`).
- `macoid build swift|swift-mac|ios|macos` build on a runner (`ios` = unsigned `.ipa`, `macos` = `.app`, `--scheme` picks the scheme).
- `gh run wait <id>` (waits without dumping the log), `gh run download --force`.
- `zip -x pattern` and `zip -q`; `zip -r out.zip .` no longer prefixes every entry with `./`.

### Fixed
- **Download errors.** Downloads (artifacts, `wget`, the Linux engine and root filesystem) are written to `<file>.part`, retried up to 5 times,
  **resumed** from where the connection dropped (HTTP Range), checked against Content-Length and renamed only when complete.
  gzip transfer encoding is switched off for downloads (it broke length checks), GET requests to the GitHub API retry on network errors / 5xx,
  expired artifacts and damaged zips give a clear message.
- **Downloading again what is already there.** `gh run download` skips an artifact that is already unpacked (same id and size; `--force` overrides),
  keeps the zip until it unpacked cleanly, and lists up to 100 artifacts. The Linux root filesystem download is kept until it has unpacked, so a failed
  unpack or a restart reuses it instead of downloading ~30 MB again; a half-finished file continues. SwiftPM / CocoaPods packages are cached between runner jobs.

### Changed
- Apple tools no longer try the phone's Linux first (`MACOID_SWIFT=local` brings that back); `xcode-select --install`, `brew`, `macoid help` describe the runner.

## [4.0] - 2026-11-18

### Changed
- **No more GitHub runners, no cloud, at all.** `macoid cloud`, `macoid sync-commands`, `macoid installs`, the cloud install cache,
  the runner scratch repo (`<you>/macoid-cloud`) and the workflow templates are removed. Commands that used to fall back to a
  macOS runner now run in the Linux on the phone or say plainly that they need a real Mac.
- **A real Linux on the phone.** Debian 13 (glibc, apt) is the new default, Alpine stays available (`pkg distro alpine`);
  installs made by 3.x stay Alpine. Architectures: arm64, arm (armv7) and x86_64, chosen from the phone's CPU (`pkg arch`).
  There is no "arm128" architecture.
- **Python, pip, git, curl and ssh are there from the start**: the first setup installs a base set, so `python`, `python3`,
  `pip`, `pip3`, `git`, `curl` work right away. `pkg` also works inside the Linux shell (`lx`).
- `pkg`, `apt`, `apt-get`, `brew install`, `pip`, `npm`, `gem`, `cargo`, `go` all use that Linux. REPLs (`python`, `node`, ...) work now.
- `macoid build` compiles on the phone: `node python go rust cmake maven gradle-java`.
- The Termux-style native package repo (needed hours of building on a runner or Docker PC) and `tools/build-repo.sh` are removed.
- The `apk-release` skill is removed (it built Android apps on a runner).
- App update removes the files older versions left behind (cloud scripts, templates).

### Fixed
- `apt update` that failed on every mirror (no internet) no longer counts as a fresh package index.

### Not possible any more / not possible on the phone
- `xcodebuild`, `codesign`, `simctl`, `ibtool`, `actool`, iOS/macOS builds, Android APK/AAB builds, Flutter, Electron, .NET builds.

## [Unreleased - 3.x look]

### Changed
- **New look.** Deep graphite gradient backdrop; floating rounded tab bar with pill-shaped session chips (blue = normal,
  coral = root); the terminal sits on its own rounded card; extra keys are rounded and live on a floating panel with
  haptic feedback; the overflow menu and confirm dialogs are rounded instead of the stock Android ones.
- Editor: floating header, rounded text card, a dot next to the file name when there are unsaved changes.
- Shared styling lives in the new `Skin.kt`.

## [3.3] - 2026-11-18

### Fixed
- **Installed packages "did not save" / commands missing after `brew install`.** Three causes, all fixed:
  1. New commands were only registered when the shell started, and the "restart the shell with ^C" hint never worked
     (^C does not restart anything). Every command installed in the local Linux now gets a tiny launcher in
     `$MACOID/linux/wrap`, which is on `PATH`, so it works **immediately** - also inside scripts, pipes and `xargs`.
  2. `pip install`, `npm i -g`, `cargo install`, `go install`, `gem install` ... never registered the commands they added.
     Macoid now re-scans after every package-manager run.
  3. `brew install` swallowed apk's error and, when the local install failed (for example no internet), still printed
     "installed" and only marked the tool for the cloud. It now shows the real error, exits non-zero and saves nothing.
     Only a genuine "no such package" falls back to the cloud Mac.
- **App updates wiped everything.** Debug APKs built on GitHub Actions were signed with a random key each time, so Android
  refused to update the app, the app had to be uninstalled, and the local Linux with all its packages went with it.
  The build now uses a fixed key (`app/macoid.keystore`): install the new APK **over** the old one and your packages stay.
- Skill commands (`skill install ...` with a `bin/` folder) and commands from cloud installs also work at once.
  `skill remove` and `brew uninstall` drop their launchers.

### Changed
- **Faster installs.** The apk package index is kept on disk and refreshed at most every 12 h, instead of being downloaded
  again for every install (`--no-cache`). A stale index is refreshed and the install retried automatically.
- Clear error when the index cannot be downloaded ("check your internet") instead of a confusing "no such package".
- `brew install` ignores flags such as `--formula` / `-q`, says casks are unsupported, and installs the rest when one name fails.
- More package-name mappings (`rg`, `nvim`, `golang`, `openjdk`).
- `pkg doctor` shows where everything is stored and how many commands are on PATH.

### Upgrading
- This is the first build with the fixed signing key. If the app was installed from an older build, Android will refuse the
  update **once**: uninstall the old app, install this one, and from now on updates keep your data.
- Existing 3.2 installs get their launchers built automatically the first time a shell starts.

## [3.2] - 2026-11-17

### Added
- **Fast Apple tools.** `plutil` and `PlistBuddy` (convert/print/lint/extract/type, Print/Set/Add/Delete/Copy), `lipo`,
  `otool`, `install_name_tool`, `dwarfdump` (LLVM), `sips` (ImageMagick) and `xmllint`/`xsltproc` now run **on the phone**
  in the local Linux instead of a macOS runner.
- **`swift` on a Linux runner.** `swift`, `swiftc`, `swift build|run|test|package`, `swift-format` run on `ubuntu-latest`
  (Swift is preinstalled there, it boots in seconds and costs 1x minutes instead of 10x). Macoid reads your `.swift` files
  and only uses a real Mac when they import an Apple-only framework (SwiftUI, UIKit, AppKit, Combine, CryptoKit ...).
  If the Linux run fails with `no such module '<Apple framework>'` the command is repeated on a real Mac automatically.
  `MACOID_SWIFT=ubuntu|macos` overrides the choice.
- `xcrun <tool>` goes through the same routing; `xcrun --sdk ...`, `--find`, `--show-*` run on a real Mac.
- `macoid build swift` builds on a Linux runner, or the new `swift-mac` template when Apple frameworks are used
  (the old template built on Linux **and** macOS every time).

### Changed
- `xcodebuild build|test|archive` adds `-quiet COMPILER_INDEX_STORE_ENABLE=NO` (also in the `ios` and `macos` templates).
  `MACOID_XCODEBUILD_RAW=1` turns this off.
- Cloud jobs no longer download `.build` (large; Linux/macOS binaries do not run on Android).
- The "running on a real Mac" line now says which kind of runner is used.
- `xcode-select --install` explains the fast alternatives.

### Known limitations
- `xcodebuild`, `codesign`, `simctl`, `ibtool`, `actool`, `notarytool` ... still need a real Mac: there is no substitute.
- Swift output built on Linux is a Linux binary; run code with `swift file.swift` / `swift run`.
- Not tested on a device or on a live runner (written without Android/GitHub access): LLVM/ImageMagick package names are
  Alpine's, and the Swift install path on the ubuntu image is checked at run time.

## [3.1] - 2026-11-17

### Added
- **Fast local installer (no GitHub runner).** `pkg`, `apk`, `apt`, `apt-get`, `brew install`, `pip`, `pip3`, `pipx`, `uv`,
  `npm`, `yarn`, `pnpm`, `gem`, `cargo`, `go` now install and run **on the phone** inside a small Alpine Linux
  (proot). Nothing is uploaded, nothing waits in a queue and no VM boots: an install takes seconds, and installed
  packages simply stay there between sessions (no cache files, no replaying).
- One-time setup on first use (~1 MB engine + ~3.5 MB Alpine, downloaded automatically). `pkg doctor` shows the state,
  `pkg reset --yes` wipes it.
- `pkg install|remove|search|list|info|update|upgrade|shell`, `lx` (Linux shell / run one command there), `apk` (raw).
- Known tools install themselves on first use: running `python`, `pip`, `node`, `npm`, `ruby`, `cargo`, `go`, `gcc`,
  `make`, `cmake`, `ssh`, `tmux`, `htop`, `rsync` ... fetches the package with apk, then runs it.
- Interactive REPLs (`python`, `node`, `irb`) and full-screen programs (`tmux`, `htop`, `ssh`) work now, because they run
  locally on the real PTY terminal.

### Changed
- The macOS-command shim tries the local Linux first; only macOS-only tools (swift, xcodebuild, plutil, codesign ...)
  and explicit `macoid cloud` / `macoid build` still use a GitHub Actions runner. `MACOID_LINUX=0` forces the old behaviour.
- `brew install <name>` installs from the Alpine index first and falls back to the cloud Mac only if there is no such package.

### Notes
- Packages are Alpine (musl) packages, not Homebrew bottles or macOS binaries; Darwin-only software still needs the cloud.
- Needs a 64-bit (arm64) or 32-bit ARM / x86_64 phone with internet on the first run. Written without a device at hand:
  if the engine does not start on a phone, `pkg doctor` says what is missing.

## [3.0] - 2026-11-17

### Added
- **Real terminal.** The line-by-line text view is replaced by a real PTY terminal with full xterm emulation
  (the same terminal-emulator / terminal-view libraries Termux uses): colours, cursor movement, scrollback,
  text selection, pinch-to-zoom, Ctrl/Alt, arrow keys, `top`, full-screen programs, interactive prompts.
- **Multiple sessions** (tabs): `+` new shell, `#` new **root** shell, long-press a tab to close it.
- **Root support (`su`).** On a rooted phone (Magisk / KernelSU / APatch) the `#` button opens a root shell; inside any
  shell `tsu` enters a root shell and `sudo <cmd>` runs one command as root. The root shell has its own home
  (`root-home`) so files root creates cannot lock the normal shell out; `macoid root status|fixperms` helps.
  Macoid does not root the phone itself - it needs a phone that is already rooted.
- **Foreground service** keeps sessions alive in the background; notification has Wake lock and Exit actions.
- **Extra keys**: ESC, TAB, CTRL, ALT, arrows, HOME/END/PGUP/PGDN and a scrolling row of symbols.
- **Root-aware editor** (`edit`, also `nano`/`vi`/`vim`): reads and saves root-only files through su.

### Changed
- `sudo` is now real (via su) instead of a no-op. `top` is the real `top`. `gh auth login` no longer echoes the token.
- The shell is started with `$ENV` pointing to `macoid.rc` (all aliases/functions are unchanged), emacs line editing,
  history in `~/.mksh_history`.
- Build needs JitPack (`maven("https://jitpack.io")`) and `android.useAndroidX=true`.

## [2.2] - 2026-11-17

### Added
- **Runner OS file (cached environment).** After a successful `pip`/`npm -g`/`gem`/`cargo`/`go`/`brew` install, the
  runner packs everything the install added into one file per ecosystem (`env-python.tgz`, `env-node.tgz`, ...) and
  stores it as a release asset (tag `macoid-env`) in your private `<you>/macoid-cloud` repo. Later jobs download and
  extract that file instead of installing again, which is much faster than re-running `pip install`.
- If the cached file is missing or fails to restore, Macoid falls back to replaying the saved install commands (2.1).
- Cloud workflow now has `contents: write` permission and a `GH_TOKEN`, needed to store the cached environment.

### Changed
- `pip install`, `npm -g` and other installs no longer upload your folder to the runner unless the command points
  to a local file (`-r requirements.txt`, `-e .`, `./pkg`). This removes most of the wait before an install starts.
- When you run a command from the home folder (`~`), only loose files are uploaded, not every folder in it.
- The git upload log (object counting/compressing, "Create a pull request" hint) is hidden; it is shown only if the
  upload fails. The two "running on a real Mac" lines were merged into one.

### Security
- Macoid now refuses to run a job if `<you>/macoid-cloud` is public (it receives your project files and cached
  installs). Make it private or delete it; override with `MACOID_ALLOW_PUBLIC=1`.

### Notes
- The first install of a package is still slow (it really installs); every run after that restores the cached file.
- The cache is per ecosystem and grows with what you install. `macoid installs clear` forgets the local list; delete
  the `macoid-env` release in `<you>/macoid-cloud` to wipe the cached files.

## [3.4] - 2026-11-18

### Added
- **Native, Termux-style package system.** `pkg install` downloads prebuilt `.deb` packages (apt + dpkg in `files/usr`) and
  runs them directly on Android. Packages are built once, offline, by `tools/build-repo.sh` (hours, once); installs on the
  phone take seconds and need no GitHub runner and no proot.
- `NativeBoot` (Kotlin): downloads and unpacks `bootstrap-<arch>.zip` with SHA-256 check, SYMLINKS.txt handling and a
  swap-in so a failed download never breaks an existing prefix.
- `lib/native.sh`, `lib/native.conf`, `tools/build-repo.sh`.
- First use of a known command (`python`, `node`, `go`, `clang`, `ssh`, `jq`, ...) installs its native package.

### Changed
- `pkg`, `apt`, `apt-get`, `brew install` try the native repo first and fall back to Alpine only for packages it lacks.
- `$PREFIX/bin` is on `PATH`; native `curl wget unzip zip tree man host dig nslookup` replace the built-in stand-ins.

### Notes
- The native engine is off until `NAT_BASE_URL` points at a repo built with `tools/build-repo.sh`.

## [2.1] - 2026-11-17

### Fixed
- **Installs no longer vanish.** Every cloud command runs on a fresh, empty GitHub runner, so anything you
  installed (`pip install`, `npm i -g`, ...) was lost as soon as the job ended and had to be redone. Successful
  installs are now remembered and re-applied automatically before later commands that need them.
- **Aliases are now saved.** Aliases created with `alias` used to disappear when the shell restarted (`^C`) or the
  app was closed. They are now stored and restored on startup.
- **Misleading "not installed" message.** Running a cloud command used to print
  "'swift' is not installed on Android". It now says the command is running on a real Mac.
- `brew install <name>` for a macOS command that already exists on the cloud Mac (e.g. `swift`) used to print
  "nothing to install" and record nothing. It now marks the tool as installed.

### Added
- **Saved installs** for `pip`/`pip3`/`pipx`, `npm`/`pnpm -g`, `yarn global add`, `gem`, `cargo install`,
  `go install` and `brew install`. Only the installs relevant to a command are re-applied
  (`python3` restores pip packages, `node` restores npm packages, and so on).
- **New commands from installs are detected.** If an install adds a command (e.g. `pip install yt-dlp` adds
  `yt-dlp`), it gets a local alias that runs on the cloud. Press `^C` once to load it.
- `brew install <formula>` for names outside the built-in catalog now installs on the cloud Mac and is saved.
- `pip uninstall`, `npm uninstall -g`, `gem uninstall`, `cargo uninstall` and `brew uninstall` remove the saved entry.
- `macoid installs` lists saved installs; `macoid installs rm <package>` and `macoid installs clear` manage them.
- `brew list` and `brew info` show tools marked as installed.
- `~/.macoid/aliases.rc` (written automatically by `alias`, edited by `unalias`) and `~/.macoid/user.rc`
  (free-form startup file you can edit yourself). Your aliases override the built-in ones.
- `node_modules` is now uploaded with the project when it is under 30 MB, so a plain `npm install` is not lost
  between runs.

### Changed
- Cloud jobs set `PIP_BREAK_SYSTEM_PACKAGES`, `PIP_DISABLE_PIP_VERSION_CHECK` and Homebrew's no-auto-update /
  no-cleanup flags to keep installs working and faster.

### Known limitations
- The runner is still wiped after every job, so saved packages are re-installed in the cloud each time they are
  needed. Results persist; the wait for those installs does not go away.
- Newly installed commands need a shell restart (`^C`) before they can be used.

## [2.0] - Initial release

### Added
- macOS-style terminal for Android with real `git` (JGit) and a GitHub CLI (`gh`).
- Native commands: `git`, `gh`, `curl`, `wget`, `zip`, `unzip`, `host`/`dig`/`nslookup`.
- macOS emulation on the phone: `open`, `pbcopy`, `pbpaste`, `say`, `afplay`, `osascript`, `defaults`,
  `sw_vers`, `sysctl`, `system_profiler`, `scutil`, `pmset`, `ioreg`, `vm_stat`, `diskutil`, `ifconfig`,
  `networksetup`, `launchctl`, `mdfind`, `mdls`, `ditto`, `trash`, `tree`, `md5`, `shasum`, `uuidgen`, `brew`,
  `man`, `softwareupdate`, `xcode-select`, `caffeinate`.
- macOS command catalog (~920 names, e.g. `python3`, `node`, `gcc`, `clang`, `swift`, `xcodebuild`, `make`,
  `cmake`, `cargo`, `go`, `ruby`, `awk`, `rsync`, `plutil`, `codesign`) that runs transparently on a real
  `macos-latest` GitHub Actions runner through your own account, with output streamed back and newly created files
  copied into your folder.
- `macoid sync-commands` to pull the full command list from a real Mac.
- Hardware/OS-specific commands (`csrutil`, `kextstat`, `tmutil`, `dscl`, ...) are refused instead of reporting
  the runner's machine.
- `macoid build [target]` to compile projects on GitHub Actions (Android APK/AAB, iOS, macOS, Swift, Flutter,
  Gradle, Maven, Node, Electron, Python, Go, Rust, CMake, .NET).
- `MACOID_CLOUD=0` to disable the cloud and `MACOID_CLOUD_OS=ubuntu` to choose another runner OS.
- GitHub authentication over HTTPS with a token (no SSH).
