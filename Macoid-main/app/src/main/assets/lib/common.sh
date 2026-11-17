# shared helpers, sourced by Macoid scripts
jvm() { CLASSPATH="$MACOID_APK" exec /system/bin/app_process / com.macoid.terminal.Cli "$@"; }
bridge() {
  _a=$1; shift
  am broadcast --user 0 -n com.macoid.terminal/.BridgeReceiver -a "$_a" --es key "$(cat "$MACOID/.key" 2>/dev/null)" "$@" >/dev/null 2>&1
}
die() { echo "$*" >&2; exit 1; }
prop() { getprop "$1" 2>/dev/null; }
mem_kb() { grep "^$1:" /proc/meminfo | tr -s ' ' | cut -d' ' -f2; }
ncpu() { grep -c ^processor /proc/cpuinfo; }
