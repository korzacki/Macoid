# Persistent state for tools that run on the cloud (macOS) runner.
# Every cloud job starts on a blank machine, so "pip install x" would vanish right after it ran.
# Instead we remember each successful install here and re-apply it before later commands that need it.
#   $HOME/.macoid/installs.tsv   one line per install:  ecosystem|new commands|original command
#   $HOME/.macoid/cloudbins      names of commands that installs added (they get a local alias -> cloud)
MACOID_STATE="$HOME/.macoid"
INST_FILE="$MACOID_STATE/installs.tsv"
BINS_FILE="$MACOID_STATE/cloudbins"

# tool_eco <tool>: which ecosystem's saved installs must be re-applied before running <tool>
tool_eco() {
  case "$1" in
    python|python[0-9]*|pip|pip[0-9]*|pipx|pydoc|pydoc3|virtualenv) echo python;;
    node|npm|npx|yarn|pnpm|corepack|deno|bun) echo node;;
    ruby|gem|irb|bundle|bundler|rake|erb|rdoc|ri) echo ruby;;
    cargo|rustc|rustup|rustfmt|clippy-driver|rust-analyzer) echo rust;;
    go|gofmt) echo go;;
    *) echo "";;
  esac
}

# install_eco <tool> [args]: prints the ecosystem if this command installs a global tool/package
install_eco() {
  _t=$1; shift
  case "$_t" in
    python|python[0-9]*) if [ "$1" = -m ] && [ "$2" = pip ]; then shift 2; _t=pip; else return 0; fi;;
  esac
  _g=0; for _a in "$@"; do case "$_a" in -g|--global) _g=1;; esac; done
  case "$_t" in
    pip|pip[0-9]*|pipx) [ "$1" = install ] && echo python;;
    npm|pnpm) case "$1" in install|i|add) [ $_g = 1 ] && echo node;; esac;;
    yarn) [ "$1" = global ] && [ "$2" = add ] && echo node;;
    gem) [ "$1" = install ] && echo ruby;;
    cargo) [ "$1" = install ] && echo rust;;
    go) [ "$1" = install ] && echo go;;
    brew) case "$1" in install|reinstall) echo brew;; esac;;
  esac
  return 0
}

# uninstall_args <tool> [args]: prints the package names if this command removes a global package
uninstall_args() {
  _t=$1; shift
  case "$_t" in
    python|python[0-9]*) if [ "$1" = -m ] && [ "$2" = pip ]; then shift 2; _t=pip; else return 0; fi;;
  esac
  _ok=0
  case "$_t" in
    pip|pip[0-9]*|pipx|gem|cargo|brew) case "$1" in uninstall|remove) _ok=1;; esac;;
    npm|pnpm) case "$1" in uninstall|remove|rm|un) _ok=1;; esac;;
    yarn) [ "$1" = global ] && [ "$2" = remove ] && { shift; _ok=1; };;
  esac
  [ $_ok = 1 ] || return 0
  shift
  for _a in "$@"; do case "$_a" in -*) ;; *) printf '%s\n' "$_a";; esac; done
}

inst_record() {   # eco bins cmd
  mkdir -p "$MACOID_STATE"; touch "$INST_FILE" "$BINS_FILE"
  _tmp="$INST_FILE.new"; : > "$_tmp"
  while IFS= read -r _l || [ -n "$_l" ]; do
    case "$_l" in *"|$3") ;; *) printf '%s\n' "$_l" >> "$_tmp";; esac
  done < "$INST_FILE"
  printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$_tmp"
  mv "$_tmp" "$INST_FILE"
  for _b in $2; do
    case "$_b" in *[!A-Za-z0-9_+.-]*|'') continue;; esac
    grep -qx -- "$_b" "$BINS_FILE" 2>/dev/null || echo "$_b" >> "$BINS_FILE"
  done
}

inst_remove() {   # package-name -> drops matching saved installs (and the commands they added); returns 0 if something was removed
  [ -f "$INST_FILE" ] || return 1
  _p=$1; _hit=1; _tmp="$INST_FILE.new"; : > "$_tmp"
  while IFS= read -r _l || [ -n "$_l" ]; do
    case "$_l" in
      *" '$_p'"*|*" '$_p=="*|*" '$_p@"*|*" '$_p>="*)
        _hit=0
        _bins=${_l#*|}; _bins=${_bins%%|*}
        _bt="$BINS_FILE.new"; : > "$_bt"
        while IFS= read -r _x || [ -n "$_x" ]; do
          case " $_bins " in *" $_x "*) ;; *) echo "$_x" >> "$_bt";; esac
        done < "$BINS_FILE" 2>/dev/null
        mv "$_bt" "$BINS_FILE";;
      *) printf '%s\n' "$_l" >> "$_tmp";;
    esac
  done < "$INST_FILE"
  mv "$_tmp" "$INST_FILE"
  return $_hit
}

inst_list() {
  [ -s "$INST_FILE" ] || { echo "No saved installs yet. Anything you pip/npm -g/gem/cargo/go/brew install is remembered here."; return 0; }
  _i=0
  while IFS='|' read -r _e _b _c; do
    _i=$((_i+1)); printf '%2d. [%s] %s' "$_i" "$_e" "$(printf '%s' "$_c" | tr -d "'")"
    [ -n "$_b" ] && printf '   -> commands: %s' "$_b"; echo
  done < "$INST_FILE"
}
