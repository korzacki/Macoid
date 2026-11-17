# Changelog

All notable changes to Macoid are documented here.

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
