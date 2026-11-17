# Changelog

All notable changes to Macoid are documented here.

## [2.2] - 2026-11-17

### Added
- **Runner OS file (cached environment).** After a successful `pip`/`npm -g`/`gem`/`cargo`/`go`/`brew` install, the
  runner packs everything the install added into one file per ecosystem (`env-python.tgz`, `env-node.tgz`, ...) and
  stores it as a release asset (tag `macoid-env`) in your private `<you>/macoid-cloud` repo. Later jobs download and
  extract that file instead of installing again, which is much faster than re-running `pip install`.
- If the cached file is missing or fails to restore, Macoid falls back to replaying the saved install commands (2.1).
- Cloud workflow now has `contents: write` permission and a `GH_TOKEN`, needed to store the cached environment.

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
