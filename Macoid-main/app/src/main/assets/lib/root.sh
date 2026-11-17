# root helpers, sourced by tsu / sudo / macoid root
root_su() {
  for _p in /system/bin/su /system/xbin/su /sbin/su /su/bin/su /system_ext/bin/su /system/sbin/su /vendor/bin/su /data/adb/ksu/bin/su /data/adb/ap/bin/su; do
    [ -x "$_p" ] && { echo "$_p"; return 0; }
  done
  command -v su 2>/dev/null
}
# writes the current environment (minus HOME/TMPDIR/USER) to a file the root shell sources; prints its path
root_envfile() {
  _f="$TMPDIR/.rootenv.$$"
  env | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | sed "s/'/'\\\\''/g; s/^\([A-Za-z_][A-Za-z0-9_]*\)=\(.*\)\$/export \1='\2'/" > "$_f"
  {
    echo "export HOME='$MACOID/root-home' TMPDIR='$MACOID/tmp-root' USER=root LOGNAME=root MACOID_ROOT=1"
    echo 'export PATH="$PATH:/sbin:/system/sbin:/vendor/bin:/data/adb/magisk:/data/adb/ksu/bin"'
    echo 'mkdir -p "$HOME" "$TMPDIR" 2>/dev/null'
  } >> "$_f"
  chmod 644 "$_f"
  echo "$_f"
}
root_quote() { for _a in "$@"; do printf "'%s' " "$(printf '%s' "$_a" | sed "s/'/'\\\\''/g")"; done; }
root_need() {
  SU=$(root_su) || die "$1: su not found - this phone is not rooted (needs Magisk / KernelSU / APatch)"
}
