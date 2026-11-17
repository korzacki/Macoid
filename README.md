# Macoid 2.0 - a macOS-style terminal for Android

Macoid gives you a Mac-like shell on Android: real `git`, a GitHub CLI (`gh`), macOS commands
(`open`, `pbcopy`, `defaults`, `sw_vers`, `sysctl`, `osascript`, ...), and a way to run **any other macOS
command, and to compile apps for any platform, on real GitHub Actions runners**.
Info: Unpack workflow is for unpacking zip file that contains in the code, so if you modified some of the code. and you just too lazy to unpack it, run that workflow.

## Build the app
1. Push this folder to a GitHub repository.
2. **Actions -> Build APK** -> download the `Macoid-apk` artifact (`app-debug.apk`) and install it
   (allow installs from unknown sources). Or open the folder in Android Studio and run *Build > Build APK*.

## What runs where
| Layer | What | Where it runs |
|---|---|---|
| Native | `git` (JGit), `gh`, `curl`, `wget`, `zip`, `unzip`, `host/dig/nslookup` | on your phone |
| macOS emulation | `open pbcopy pbpaste say afplay osascript defaults sw_vers sysctl system_profiler scutil pmset ioreg vm_stat diskutil ifconfig networksetup launchctl mdfind mdls ditto trash tree md5 shasum uuidgen brew man softwareupdate xcode-select caffeinate` | on your phone (reads real Android data) |
| macOS catalog | ~920 command names (`python3 node gcc clang swift xcodebuild make cmake cargo go ruby awk rsync plutil codesign ...`) | on a **real Mac** (GitHub `macos-latest`) via your account |
| Sync | `macoid sync-commands` pulls the full list of commands from a real Mac (`/bin /sbin /usr/bin /usr/sbin /opt/homebrew/bin`) and adds them | one-time cloud job |

Cloud commands are transparent: type `python3 script.py` and Macoid uploads your current folder to a private
scratch repo (`<you>/macoid-cloud`), runs it on a macOS runner, streams the output back, and copies any files the
command created into your folder. Latency is roughly 20-90 seconds. Hardware/OS-specific commands
(`csrutil`, `kextstat`, `tmutil`, `dscl`, ...) are refused instead of reporting the runner's machine.
Disable the cloud with `export MACOID_CLOUD=0`; choose another OS with `export MACOID_CLOUD_OS=ubuntu`.

## Getting started with GitHub
```
gh auth login                 # paste a token (scopes: repo, workflow). It also sets git user.name/email.
git clone you/project         # shorthand for https://github.com/you/project.git
git add -A && git commit -m "change" && git push
gh repo create myapp --private --source . --push
gh pr create -t "My PR"
gh api user -q .login
```
Authentication is HTTPS + token only (no SSH).

## Compile an app into anything
```
cd myproject
macoid build                  # auto-detects the project type
macoid build ios --scheme MyApp
macoid build android-apk
macoid cloud --os windows -- dotnet --info
```
Targets: `android-apk android-aab ios macos swift flutter-apk gradle-java maven node electron python go rust cmake dotnet`.
Results land in `./build-output` (iOS output is an **unsigned** .ipa for sideloading).
Cost note: private repos get a monthly free Actions quota, and macOS minutes count 10x.

## Skills
Skills are installable packages: a folder with a `SKILL.md` (front matter: `name`, `description`, optional `run`),
scripts, and an optional `bin/` folder whose files become shell commands.
```
skill examples                          # built-in skills
skill install builtin:hello-cmd         # adds a `hello` command (restart the shell with ^C)
skill install owner/repo                # from GitHub (repo may hold many skills), also owner/repo/subfolder
skill install https://.../pack.zip      # or a local .zip / ./folder
skill list | info <name> | run <name> [args] | update | remove <name>
skill new my-skill                      # scaffold your own, then: nano ~/.macoid/skills/my-skill/SKILL.md
skill search backup                     # GitHub repos tagged with the topic "macoid-skill"
```
Built-ins: `hello-cmd` (template), `repo-backup` (zip the current folder to ~/storage/Download), `apk-release`
(cloud-build an Android project and copy the APK to ~/storage/Download). Publish a skill by pushing its folder to GitHub.
Macoid has no AI model on the phone, so a skill here is an installable command package, not a prompt.

## Editing & storage
* `nano|vi|vim|edit <file>` opens a built-in editor dialog.
* `setup-storage` requests storage permission; shared storage is at `~/storage`.
* Tab key completes file names. `^C` restarts the shell (keeps your directory).

## Limits (honest list)
* This is an emulation layer on Android's shell - not macOS. Binaries for Darwin cannot run on the phone; they run in the cloud.
* Full-screen programs (real vim/top/less) and interactive REPLs are not supported; pipelines into cloud commands are not supported.
* No SSH client; no GUI apps.
* The Kotlin sources for git/gh were written without access to an Android SDK/JGit in the authoring environment; the first
  GitHub Actions build is the compile check.

  # Changelog

All notable changes to Macoid are documented here.

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

