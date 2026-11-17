# macoid build: compile your project ON THE PHONE, inside the local Linux. No GitHub runner.
#   usage: macoid build [target] [--entry file]
#   targets that work here: node  python  go  rust  cmake  maven  gradle-java
#   results land in ./build-output
. "$MACOID/lib/linux.sh"

build_detect() {
  set -- *.xcworkspace; [ -e "$1" ] && { echo ios; return; }
  set -- *.xcodeproj;   [ -e "$1" ] && { echo ios; return; }
  [ -f Package.swift ] && { echo swift; return; }
  [ -f pubspec.yaml ] && { echo flutter-apk; return; }
  if [ -f package.json ]; then grep -q '"electron"' package.json && { echo electron; return; }; echo node; return; fi
  [ -f pom.xml ] && { echo maven; return; }
  if [ -f build.gradle ] || [ -f build.gradle.kts ] || [ -f settings.gradle ] || [ -f settings.gradle.kts ]; then
    if [ -f app/src/main/AndroidManifest.xml ] || [ -f src/main/AndroidManifest.xml ]; then echo android-apk; else echo gradle-java; fi; return
  fi
  [ -f Cargo.toml ] && { echo rust; return; }
  [ -f go.mod ] && { echo go; return; }
  [ -f CMakeLists.txt ] && { echo cmake; return; }
  [ -f Makefile ] && { echo cmake; return; }
  set -- *.csproj; [ -e "$1" ] && { echo dotnet; return; }
  set -- *.sln;    [ -e "$1" ] && { echo dotnet; return; }
  [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f main.py ] && { echo python; return; }
  echo ""
}

# _build_run <tool-to-ensure...> -- <sh script>   : makes sure the tools exist in Linux, then runs the script there in $PWD
_build_run() {
  _need=""
  while [ "$1" != -- ]; do _need="$_need $1"; shift; done; shift
  for _n in $_need; do lx_ensure "$_n" || { echo "build: could not install '$_n' in the local Linux (internet? 'pkg doctor')" >&2; return 1; }; done
  mkdir -p build-output
  lx_run /bin/sh -c "$1"
}

build_cmd() {
  _target=""; _entry=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --entry) _entry=$2; shift 2;;
      --scheme) shift 2;;
      -*) echo "unknown option $1" >&2; return 2;;
      *) _target=$1; shift;;
    esac
  done
  [ -n "$_target" ] || _target=$(build_detect)
  [ -n "$_target" ] || { echo "usage: macoid build <target> [--entry file]"; echo "targets: node python go rust cmake maven gradle-java   (could not auto-detect the project type here)"; return 2; }
  echo "[macoid] building '$_target' on this phone (local Linux: $LX_DISTRO $LX_GUEST)..." >&2
  case "$_target" in
    node)
      _build_run nodejs npm -- 'set -e; (npm ci || npm install); npm run build --if-present
        for d in dist build out; do [ -d "$d" ] && { rm -rf build-output/$d; cp -R "$d" build-output/; }; done; true';;
    python)
      _build_run python3 pip -- "set -e
        ENTRY='$_entry'
        python3 -m pip install --upgrade pip pyinstaller
        [ -f requirements.txt ] && python3 -m pip install -r requirements.txt
        if [ -z \"\$ENTRY\" ]; then for c in main.py app.py __main__.py; do [ -f \"\$c\" ] && ENTRY=\$c && break; done; fi
        [ -n \"\$ENTRY\" ] || { echo 'no entry file found: macoid build python --entry yourfile.py'; exit 1; }
        pyinstaller --onefile \"\$ENTRY\" && cp -R dist/. build-output/";;
    go)
      _build_run go -- 'set -e
        for t in linux/amd64 linux/arm64 linux/arm darwin/amd64 darwin/arm64 windows/amd64; do
          os=${t%/*}; arch=${t#*/}; ext=""; [ "$os" = windows ] && ext=.exe
          CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -o "build-output/app-$os-$arch$ext" .
        done';;
    rust)
      _build_run cargo -- 'set -e; cargo build --release
        find target/release -maxdepth 1 -type f -perm -u+x -exec cp {} build-output/ \;';;
    cmake)
      _build_run cmake make gcc -- 'set -e
        if [ -f CMakeLists.txt ]; then cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build; else make; fi
        [ -d build ] && cp -R build/. build-output/ || true';;
    maven)
      _build_run mvn java -- 'set -e; mvn -B package
        find . -path ./build-output -prune -o \( -path "*/target/*.jar" -o -path "*/target/*.war" \) -print -exec cp {} build-output/ \;';;
    gradle-java)
      _build_run gradle java -- 'set -e
        if [ -f gradlew ]; then chmod +x gradlew; ./gradlew build --no-daemon; else gradle build --no-daemon; fi
        find . -path ./build-output -prune -o -path "*/build/libs/*.jar" -print -exec cp {} build-output/ \;';;
    android-apk|android-aab|flutter-apk|electron|dotnet|ios|macos|swift|swift-mac)
      echo "build: '$_target' cannot be built on the phone (it needs the Android SDK / Xcode / .NET / Flutter toolchains, which Macoid does not set up)." >&2
      echo "       Macoid no longer sends builds to GitHub runners. Targets that work here: node python go rust cmake maven gradle-java" >&2
      return 2;;
    *) echo "build: unknown target '$_target'. Targets that work here: node python go rust cmake maven gradle-java" >&2; return 2;;
  esac
  _rc=$?
  [ $_rc -eq 0 ] && echo "[macoid] done. Results are in ./build-output" >&2
  return $_rc
}
