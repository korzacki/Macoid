# Runs a macOS command on a real macOS GitHub Actions runner. Usage: shim.sh <command> [args]
. "$MACOID/lib/common.sh"
tool=$1; shift
if [ "${MACOID_CLOUD:-1}" = 0 ]; then echo "$tool: command not found (cloud runner disabled)" >&2; exit 127; fi
case "$tool" in
  # hardware / OS specific: running these on a cloud VM would report the wrong machine
  kextstat|kmutil|kextload|kextunload|kextcache|csrutil|spctl|tccutil|bputil|fdesetup|firmwarepasswd|nvram|systemsetup|profiles|tmutil|airport|wdutil|powermetrics|sysdiagnose|spindump|purge|dscl|dscacheutil|dsconfigad|dsenableroot|dseditgroup|sysadminctl|pwpolicy|authorizationhost|vsdbutil|reboot|halt|shutdown|dmesg|fsck*|mount_*|newfs_*|asr|bless|hdik|iostat|nettop|sample|leaks|fs_usage)
    echo "$tool: this command inspects or changes the local machine and is not available on Android." >&2; exit 126;;
  # need a real terminal
  ssh|telnet|ftp|sftp|lldb|htop|tmux|screen|emacs|passwd|login|su)
    echo "$tool: interactive terminal programs are not supported in Macoid." >&2; exit 126;;
  python|python3|node|ruby|irb|perl|php|lua|julia|R|ghci|ocaml|iex|erl|sbt|scala|clj|dart|deno|bun)
    [ $# -eq 0 ] && { echo "$tool: the interactive REPL is not supported. Run a script (e.g. $tool file) or use -c/-e." >&2; exit 126; };;
esac
. "$MACOID/lib/cloud.sh"
echo "[macoid] running '$tool' on a real Mac (GitHub Actions). Disable with MACOID_CLOUD=0" >&2
cloud_cmd --os "${MACOID_CLOUD_OS:-macos}" --fetch -- "$tool" "$@"
