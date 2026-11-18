# Used by the sed / date / stat / mktemp / ls wrappers in macoid.rc: run the macOS-style call through the translator,
# and when there is no rule for it hand it to Android's own binary unchanged.
# Usage: sh mactr-run.sh <command> [args...]
. "$MACOID/lib/mactr.sh"
mactr_run "$@"; _rc=$?
if [ "$_rc" = 99 ]; then _t=$1; shift; _mt_real "$_t" "$@"; exit $?; fi
exit $_rc
