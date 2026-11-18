# macOS -> Android translator (4.2). Sourced by shim.sh and run by mactr-run.sh. Needs $MACOID.
#
#   mactr_run <command> [args...]
#     any status = the command was translated and ran (that is its exit status)
#     99         = no rule for it: the caller goes on (real Linux on the phone, package install ...)
#
# It takes the syntax a Mac user types (BSD flavour: sed -i '', date -v+1d, stat -f %z, md5, shasum -a 256, jot, ditto ...)
# and turns it into what Android's toolbox understands. Only commands with a real rule are handled here; commands that
# only inspect or change a Mac (hdiutil, networksetup, launchctl ...) say so instead of pretending.

# Android's own binary of that name (never a shell function or alias of ours)
_mt_real() {
  _mt_n=$1; shift
  for _mt_d in /system/bin /system/xbin /vendor/bin; do
    [ -x "$_mt_d/$_mt_n" ] && { "$_mt_d/$_mt_n" "$@"; return $?; }
  done
  command "$_mt_n" "$@"
}
_mt_have() { for _mt_d in /system/bin /system/xbin /vendor/bin; do [ -x "$_mt_d/$1" ] && return 0; done; command -v "$1" >/dev/null 2>&1; }
# a tool Android lacks (zip ...): the normal Macoid way, installed on first use in the local Linux
_mt_tool() {
  if [ -n "$MACOID" ] && [ -f "$MACOID/lib/shim.sh" ]; then /system/bin/sh "$MACOID/lib/shim.sh" "$@"; else command "$@"; fi
}
_mt_err() { echo "$1: $2" >&2; }
_mt_int() { case $1 in 0?) echo "${1#0}";; '') echo 0;; *) echo "$1";; esac; }

# ------------------------------------------------------------------------------------------------ sed
# BSD:  sed -i '' 's/a/b/' f     sed -i.bak ...     sed -l
# Android's sed wants a plain -i (the empty suffix is a separate argument on a Mac: it has to go)
_mt_sed() {
  _n=$#; _skip=0
  while [ "$_n" -gt 0 ]; do
    _x=$1; shift; _n=$((_n - 1))
    if [ "$_skip" = 1 ]; then _skip=0; [ -z "$_x" ] && continue; fi
    case "$_x" in
      -l) continue;;
      -i) _skip=1;;
    esac
    set -- "$@" "$_x"
  done
  _mt_real sed "$@"
}

# ------------------------------------------------------------------------------------------------ date
_mt_fmt() {   # epoch [format...]  -> formatted; works with GNU-style and toybox-style date
  _e=$1; shift
  _mt_real date -d "@$_e" "$@" 2>/dev/null || _mt_real date -D %s -d "$_e" "$@"
}
_mt_mk() {    # Y M D h m s -> epoch (local time)
  _s=$(printf '%04d-%02d-%02d %02d:%02d:%02d' "$1" "$2" "$3" "$4" "$5" "$6")
  _mt_real date -d "$_s" +%s 2>/dev/null || _mt_real date -D '%Y-%m-%d %H:%M:%S' -d "$_s" +%s
}
_mt_month() {
  case "$1" in
    [Jj]an*) echo 1;; [Ff]eb*) echo 2;; [Mm]ar*) echo 3;; [Aa]pr*) echo 4;; [Mm]ay*) echo 5;; [Jj]un*) echo 6;;
    [Jj]ul*) echo 7;; [Aa]ug*) echo 8;; [Ss]ep*) echo 9;; [Oo]ct*) echo 10;; [Nn]ov*) echo 11;; [Dd]ec*) echo 12;;
    *) return 1;;
  esac
}
# parse a date string with a strftime-like format (the common conversions) -> epoch; missing parts = now
_mt_parse() {   # format string
  _pf=$1; _ps=$2
  _now=$(_mt_real date +%s); set -- $(_mt_fmt "$_now" +'%Y %m %d %H %M %S')
  _Y=$(_mt_int "$1"); _M=$(_mt_int "$2"); _D=$(_mt_int "$3"); _h=$(_mt_int "$4"); _m=$(_mt_int "$5"); _s=$(_mt_int "$6")
  _pf=$(printf '%s' "$_pf" | sed -e 's/%T/%H:%M:%S/g' -e 's/%F/%Y-%m-%d/g' -e 's/%D/%m\/%d\/%y/g' -e 's/%R/%H:%M/g')
  while [ -n "$_pf" ]; do
    case "$_pf" in
      %*)
        _c=${_pf#%}; _c=${_c%"${_c#?}"}; _pf=${_pf#%?}
        case "$_c" in
          Y) _v=$(printf '%s' "$_ps" | sed -n 's/^\([0-9]\{4\}\).*/\1/p'); [ -n "$_v" ] || return 1; _Y=$(_mt_int "$_v"); _ps=${_ps#????};;
          y) _v=$(printf '%s' "$_ps" | sed -n 's/^\([0-9]\{2\}\).*/\1/p'); [ -n "$_v" ] || return 1; _v=$(_mt_int "$_v"); if [ "$_v" -ge 69 ]; then _Y=$((1900 + _v)); else _Y=$((2000 + _v)); fi; _ps=${_ps#??};;
          m|d|e|H|M|S)
            _v=$(printf '%s' "$_ps" | sed -n 's/^ *\([0-9]\{1,2\}\).*/\1/p'); [ -n "$_v" ] || return 1
            _ps=$(printf '%s' "$_ps" | sed 's/^ *[0-9]\{1,2\}//'); _v=$(_mt_int "$_v")
            case "$_c" in m) _M=$_v;; d|e) _D=$_v;; H) _h=$_v;; M) _m=$_v;; S) _s=$_v;; esac;;
          b|B|h)
            _v=$(printf '%s' "$_ps" | sed -n 's/^\([A-Za-z]\{3,9\}\).*/\1/p'); [ -n "$_v" ] || return 1
            _M=$(_mt_month "$_v") || return 1; _ps=${_ps#"$_v"};;
          Z|z) _ps=$(printf '%s' "$_ps" | sed 's/^[^ ]*//');;
          %) _ps=${_ps#%};;
          *) return 1;;
        esac;;
      *) _l=${_pf%"${_pf#?}"}; _pf=${_pf#?}; _ps=${_ps#"$_l"};;
    esac
  done
  _mt_mk "$_Y" "$_M" "$_D" "$_h" "$_m" "$_s"
}
_mt_date() {
  _J=0; _F=""; _R=""; _V=""; _out=""; _inp=""; _U=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -j) _J=1;;
      -u) _U=1;;
      -f) _F=$2; shift;;
      -r) _R=$2; shift;;
      -v*) _vv=${1#-v}; [ -z "$_vv" ] && { _vv=$2; shift; }; _V="$_V $_vv";;
      +*) _out=$1;;
      *) _inp=$1;;
    esac
    shift
  done
  [ -n "$_U" ] && export TZ=UTC
  _ep=""
  if [ -n "$_R" ]; then
    case "$_R" in ''|*[!0-9]*) _ep=$(_mt_real stat -c %Y "$_R" 2>/dev/null) || { _mt_err date "$_R: no such file or not an epoch"; return 1; };; *) _ep=$_R;; esac
  elif [ -n "$_F" ]; then
    [ -n "$_inp" ] || { _mt_err date "-f needs a date string"; return 1; }
    _ep=$(_mt_parse "$_F" "$_inp") || { _mt_err date "failed conversion of '$_inp' using format '$_F'"; return 1; }
  else
    _ep=$(_mt_real date +%s)
  fi
  for _vv in $_V; do
    _sg=""; _r=$_vv
    case "$_r" in [+-]*) _sg=${_r%"${_r#?}"}; _r=${_r#?};; esac
    _un=${_r#"${_r%?}"}; _num=${_r%?}
    case "$_num" in ''|*[!0-9]*) _mt_err date "unsupported adjustment '-v$_vv' (use y m w d H M S)"; return 1;; esac
    if [ -n "$_sg" ]; then
      [ "$_sg" = - ] && _num=-$_num
      case "$_un" in
        S) _ep=$((_ep + _num));; M) _ep=$((_ep + _num * 60));; H) _ep=$((_ep + _num * 3600));;
        d) _ep=$((_ep + _num * 86400));; w) _ep=$((_ep + _num * 604800));;
        m|y)
          set -- $(_mt_fmt "$_ep" +'%Y %m %d %H %M %S')
          _Y=$(_mt_int "$1"); _M=$(_mt_int "$2"); _D=$(_mt_int "$3"); _h=$(_mt_int "$4"); _mi=$(_mt_int "$5"); _s=$(_mt_int "$6")
          if [ "$_un" = y ]; then _Y=$((_Y + _num)); else _t=$((_Y * 12 + _M - 1 + _num)); _Y=$((_t / 12)); _M=$((_t % 12 + 1)); fi
          _ep=$(_mt_mk "$_Y" "$_M" "$_D" "$_h" "$_mi" "$_s") || return 1;;
        *) _mt_err date "unsupported unit '$_un' in -v$_vv"; return 1;;
      esac
    else
      set -- $(_mt_fmt "$_ep" +'%Y %m %d %H %M %S')
      _Y=$(_mt_int "$1"); _M=$(_mt_int "$2"); _D=$(_mt_int "$3"); _h=$(_mt_int "$4"); _mi=$(_mt_int "$5"); _s=$(_mt_int "$6")
      case "$_un" in y) _Y=$_num;; m) _M=$_num;; d) _D=$_num;; H) _h=$_num;; M) _mi=$_num;; S) _s=$_num;;
        *) _mt_err date "unsupported unit '$_un' in -v$_vv"; return 1;; esac
      _ep=$(_mt_mk "$_Y" "$_M" "$_D" "$_h" "$_mi" "$_s") || return 1
    fi
  done
  if [ -n "$_out" ]; then _mt_fmt "$_ep" "$_out"; else _mt_fmt "$_ep" +'%a %b %e %H:%M:%S %Z %Y'; fi
}

# ------------------------------------------------------------------------------------------------ stat -f
# BSD stat -f "%z %Sm %N" file   ->   done spec by spec with Android's stat -c
_mt_stat_one() {   # format file
  _sf=$1; _sp=$2; _line=""
  while [ -n "$_sf" ]; do
    case "$_sf" in
      %%*) _line="$_line%"; _sf=${_sf#%%};;
      %*)
        _sf=${_sf#%}; _mod=""
        case "$_sf" in [SLH]*) _mod=${_sf%"${_sf#?}"}; _sf=${_sf#?};; esac
        _ch=${_sf%"${_sf#?}"}; _sf=${_sf#?}
        case "$_mod$_ch" in
          z) _v=$(_mt_real stat -c %s "$_sp");;
          N) _v=$_sp;;
          m) _v=$(_mt_real stat -c %Y "$_sp");;  a) _v=$(_mt_real stat -c %X "$_sp");;  c) _v=$(_mt_real stat -c %Z "$_sp");;
          B) _v=$(_mt_real stat -c %W "$_sp");;
          Sm) _v=$(_mt_fmt "$(_mt_real stat -c %Y "$_sp")" +"$_stf");;
          Sa) _v=$(_mt_fmt "$(_mt_real stat -c %X "$_sp")" +"$_stf");;
          Sc) _v=$(_mt_fmt "$(_mt_real stat -c %Z "$_sp")" +"$_stf");;
          SB) _v=$(_mt_fmt "$(_mt_real stat -c %W "$_sp")" +"$_stf");;
          Lp) _v=$(_mt_real stat -c %a "$_sp");;
          Sp) _v=$(_mt_real stat -c %A "$_sp");;
          p) _h=$(_mt_real stat -c %f "$_sp"); _v=$(printf '%o' "$((0x$_h))");;
          u) _v=$(_mt_real stat -c %u "$_sp");;  g) _v=$(_mt_real stat -c %g "$_sp");;
          Su) _v=$(_mt_real stat -c %U "$_sp");; Sg) _v=$(_mt_real stat -c %G "$_sp");;
          i) _v=$(_mt_real stat -c %i "$_sp");;  l) _v=$(_mt_real stat -c %h "$_sp");;
          d) _v=$(_mt_real stat -c %d "$_sp");;  k) _v=$(_mt_real stat -c %o "$_sp");;
          b) _v=$(_mt_real stat -c %b "$_sp");;
          Y) _v=$(readlink "$_sp" 2>/dev/null);;
          HT) _v=""; _sf=${_sf#?};;
          *) _mt_err stat "unsupported format %$_mod$_ch"; return 1;;
        esac
        _line="$_line$_v";;
      *) _l=${_sf%"${_sf#?}"}; _sf=${_sf#?}; _line="$_line$_l";;
    esac
  done
  printf '%b\n' "$_line"
}
_mt_stat() {
  _fmt=""; _stf="%b %e %H:%M:%S %Y"; _isbsd=0; _args=""
  # decide: is -f the BSD "format" option (its value contains %) or Android's "filesystem status" flag?
  _p=""; for _x in "$@"; do
    if [ "$_p" = -f ] && case "$_x" in *%*) true;; *) false;; esac; then _isbsd=1; fi
    case "$_x" in -f*%*) _isbsd=1;; esac
    _p=$_x
  done
  [ "$_isbsd" = 1 ] || { _mt_real stat "$@"; return $?; }
  _n=$#; _got=0; _files=""
  while [ "$_n" -gt 0 ]; do
    _x=$1; shift; _n=$((_n - 1))
    case "$_x" in
      -f) _fmt=$1; shift; _n=$((_n - 1)); _got=1;;
      -f*) _fmt=${_x#-f}; _got=1;;
      -t) _stf=$1; shift; _n=$((_n - 1));;
      -L|-n|-q) ;;
      *) set -- "$@" "$_x";;
    esac
  done
  [ "$_got" = 1 ] || { _mt_real stat "$@"; return $?; }
  [ $# -gt 0 ] || { _mt_err stat "usage: stat -f format file ..."; return 1; }
  _rc=0
  for _f in "$@"; do
    [ -e "$_f" ] || [ -L "$_f" ] || { _mt_err stat "$_f: stat: No such file or directory"; _rc=1; continue; }
    _mt_stat_one "$_fmt" "$_f" || _rc=1
  done
  return $_rc
}

# ------------------------------------------------------------------------------------------------ md5 / shasum
_mt_hash() {   # tool label quiet reverse [files...]
  _ht=$1; _hl=$2; _hq=$3; _hr=$4; shift 4
  if [ $# -eq 0 ]; then _mt_real "$_ht" | { read -r _h _rest; printf '%s\n' "$_h"; }; return 0; fi
  _rc=0
  for _f in "$@"; do
    [ -f "$_f" ] || { _mt_err "$_hl" "$_f: No such file or directory"; _rc=1; continue; }
    _h=$(_mt_real "$_ht" "$_f"); _h=${_h%% *}
    if [ "$_hq" = 1 ]; then printf '%s\n' "$_h"
    elif [ "$_hr" = 1 ]; then printf '%s %s\n' "$_h" "$_f"
    else printf '%s (%s) = %s\n' "$_hl" "$_f" "$_h"; fi
  done
  return $_rc
}
_mt_md5() {   # md5 [-q] [-r] [-s string] [-p] [file ...]
  _q=0; _r=0; _str=""; _hs=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -q) _q=1;; -r) _r=1;; -p) ;;
      -s) _str=$2; _hs=1; shift;;
      -s*) _str=${1#-s}; _hs=1;;
      --) shift; break;;
      -*) _mt_err md5 "unknown option $1"; return 1;;
      *) break;;
    esac
    shift
  done
  if [ "$_hs" = 1 ]; then
    _h=$(printf '%s' "$_str" | _mt_real md5sum); _h=${_h%% *}
    if [ "$_q" = 1 ]; then printf '%s\n' "$_h"; elif [ "$_r" = 1 ]; then printf '%s "%s"\n' "$_h" "$_str"; else printf 'MD5 ("%s") = %s\n' "$_str" "$_h"; fi
    return 0
  fi
  _mt_hash md5sum MD5 "$_q" "$_r" "$@"
}
_mt_shasum() {   # shasum [-a 1|224|256|384|512] [-b] [-t] [-c] [files]
  _alg=1; _pass=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -a) _alg=$2; shift;;
      -a*) _alg=${1#-a};;
      -b|-t|-p|-0|-U) ;;
      -c|--check|--quiet|--status|-w|--warn) _pass="$_pass $1";;
      --) shift; break;;
      -*) _mt_err shasum "unknown option $1"; return 1;;
      *) break;;
    esac
    shift
  done
  case "$_alg" in 1|224|256|384|512) ;; *) _mt_err shasum "unsupported algorithm $_alg (use 1 224 256 384 512)"; return 1;; esac
  if [ $# -eq 0 ]; then _mt_real "sha${_alg}sum" | { read -r _h _rest; printf '%s  -\n' "$_h"; }; return 0; fi
  _mt_real "sha${_alg}sum" $_pass "$@"
}
_mt_shaN() { _n=$1; shift; _mt_hash "sha${_n}sum" "SHA${_n}" 0 0 "$@"; }

# ------------------------------------------------------------------------------------------------ mktemp -t, ls -G
_mt_mktemp() {
  _d=0; _tn=""; _rest=""; _n=$#
  while [ "$_n" -gt 0 ]; do
    _x=$1; shift; _n=$((_n - 1))
    case "$_x" in
      -t) case "$1" in -*|'') ;; *) _tn=$1; shift; _n=$((_n - 1));; esac; [ -z "$_tn" ] && _tn=tmp;;
      -d) _d=1;;
      *) set -- "$@" "$_x";;
    esac
  done
  if [ -n "$_tn" ]; then
    _td=${TMPDIR:-$HOME/tmp}; mkdir -p "$_td" 2>/dev/null
    if [ "$_d" = 1 ]; then _mt_real mktemp -d "$_td/$_tn.XXXXXXXX"; else _mt_real mktemp "$_td/$_tn.XXXXXXXX"; fi
  else
    if [ "$_d" = 1 ]; then _mt_real mktemp -d "$@"; else _mt_real mktemp "$@"; fi
  fi
}
_mt_ls() {   # BSD flags Android's ls does not know: -G (colour) -@ -e -O -T
  _col=0; _n=$#
  while [ "$_n" -gt 0 ]; do
    _x=$1; shift; _n=$((_n - 1))
    case "$_x" in
      --*|-) set -- "$@" "$_x";;
      -*) _y=$(printf '%s' "$_x" | tr -d '@eOT'); case "$_y" in *G*) _col=1; _y=$(printf '%s' "$_y" | tr -d 'G');; esac
          [ "$_y" = - ] || set -- "$@" "$_y";;
      *) set -- "$@" "$_x";;
    esac
  done
  if [ "$_col" = 1 ]; then _mt_real ls --color=auto "$@"; else _mt_real ls "$@"; fi
}

# ------------------------------------------------------------------------------------------------ jot / ditto
_mt_jot() {   # jot [-r] [-w fmt] [-s sep] [-b word] reps [begin [end]]   (integers)
  _w=""; _sep="
"; _word=""; _rnd=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -r) _rnd=1;; -w) _w=$2; shift;; -s) _sep=$2; shift;; -b) _word=$2; shift;;
      --) shift; break;;
      -*) _mt_err jot "unsupported option $1"; return 1;;
      *) break;;
    esac
    shift
  done
  _reps=${1:-100}; _beg=${2:-1}; _end=${3:-}
  for _v in "$_reps" "$_beg" ${_end:+"$_end"}; do case "$_v" in ''|*[!0-9-]*) _mt_err jot "only whole numbers are supported"; return 1;; esac; done
  if [ -n "$_word" ]; then _i=0; while [ "$_i" -lt "$_reps" ]; do [ "$_i" -gt 0 ] && printf '%s' "$_sep"; printf '%s' "$_word"; _i=$((_i + 1)); done; printf '\n'; return 0; fi
  if [ "$_rnd" = 1 ]; then _lo=${2:-0}; _hi=${3:-100}; else
    [ -n "$_end" ] || _end=$((_beg + _reps - 1))
  fi
  _i=0; _first=1
  while [ "$_i" -lt "$_reps" ]; do
    if [ "$_rnd" = 1 ]; then _val=$((_lo + (RANDOM * 32768 + RANDOM) % (_hi - _lo + 1)))
    elif [ "$_reps" -gt 1 ]; then _val=$((_beg + (_end - _beg) * _i / (_reps - 1)))
    else _val=$_beg; fi
    [ "$_first" = 1 ] || printf '%s' "$_sep"; _first=0
    if [ -n "$_w" ]; then printf "$_w" "$_val"; else printf '%s' "$_val"; fi
    _i=$((_i + 1))
  done
  printf '\n'
}
_mt_ditto() {
  _z=0; _k=0; _x=0; _kp=0; _n=$#
  while [ "$_n" -gt 0 ]; do
    _a=$1; shift; _n=$((_n - 1))
    case "$_a" in
      -c) _z=1;; -k) _k=1;; -x) _x=1;; --keepParent) _kp=1;;
      -V|-v|-V*|--rsrc|--norsrc|--noextattr|--noqtn|--noacl|--nocache|--extattr|--sequesterRsrc|--zlibCompressionLevel|--preserveHFSCompression) ;;
      *) set -- "$@" "$_a";;
    esac
  done
  if [ "$_z" = 1 ] && [ "$_k" = 1 ]; then
    [ $# -eq 2 ] || { _mt_err ditto "usage: ditto -c -k [--keepParent] source archive.zip"; return 1; }
    _src=$1; _out=$2; case "$_out" in /*) ;; *) _out="$PWD/$_out";; esac
    if [ "$_kp" = 1 ]; then _par=$(dirname "$_src"); _bn=$(basename "$_src"); ( cd "$_par" && _mt_tool zip -q -r "$_out" "$_bn" )
    elif [ -d "$_src" ]; then ( cd "$_src" && _mt_tool zip -q -r "$_out" . )
    else _par=$(dirname "$_src"); _bn=$(basename "$_src"); ( cd "$_par" && _mt_tool zip -q "$_out" "$_bn" ); fi
    return $?
  fi
  if [ "$_x" = 1 ] && [ "$_k" = 1 ]; then
    [ $# -eq 2 ] || { _mt_err ditto "usage: ditto -x -k archive.zip destination"; return 1; }
    mkdir -p "$2" && { if _mt_have unzip; then _mt_real unzip -o -q "$1" -d "$2"; else _mt_tool unzip -o -q "$1" -d "$2"; fi; }
    return $?
  fi
  [ $# -eq 2 ] || { _mt_err ditto "usage: ditto source destination"; return 1; }
  if [ -d "$1" ]; then mkdir -p "$2" && cp -R "$1"/. "$2"/; else
    if [ -d "$2" ]; then cp "$1" "$2"/; else cp "$1" "$2"; fi
  fi
}

# ------------------------------------------------------------------------------------------------ Spotlight, system info
_mt_mdfind() {
  _dir=""; _name=""; _q=""; _cnt=0; _z=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -onlyin) _dir=$2; shift;;
      -name) _name=$2; shift;;
      -count) _cnt=1;; -0) _z=1;; -live|-literal|-interpret) ;;
      -*) _mt_err mdfind "unsupported option $1"; return 1;;
      *) _q="$_q $1";;
    esac
    shift
  done
  _q=${_q# }
  if [ -z "$_name" ] && [ -n "$_q" ]; then
    case "$_q" in
      *kMDItemFSName*==*) _name=$(printf '%s' "$_q" | sed -n "s/.*kMDItemFSName *== *[\"']\\([^\"']*\\)[\"'].*/\\1/p");;
      *kMDItem*) _mt_err mdfind "only plain words and kMDItemFSName queries are supported (no Spotlight index on Android)"; return 1;;
      *) _name=$_q;;
    esac
  fi
  [ -n "$_name" ] || { _mt_err mdfind "usage: mdfind [-onlyin dir] [-name name | words]"; return 1; }
  _name=$(printf '%s' "$_name" | tr -d '*')
  _res=$(find "${_dir:-$HOME}" -iname "*$_name*" 2>/dev/null)
  if [ "$_cnt" = 1 ]; then if [ -n "$_res" ]; then printf '%s\n' "$_res" | wc -l | tr -d ' '; else echo 0; fi; return 0; fi
  [ -n "$_res" ] && { if [ "$_z" = 1 ]; then printf '%s' "$_res" | tr '\n' '\000'; else printf '%s\n' "$_res"; fi; }
  return 0
}
_mt_mdls() {   # mdls [-name attr] [-raw] file
  _attr=""; _raw=0
  while [ $# -gt 0 ]; do case "$1" in -name) _attr=$2; shift;; -raw) _raw=1;; -*) ;; *) break;; esac; shift; done
  [ -e "$1" ] || { _mt_err mdls "$1: could not find $1."; return 1; }
  _f=$1
  _val() {
    case "$1" in
      kMDItemFSName) printf '"%s"' "$(basename "$_f")";;
      kMDItemFSSize) _mt_real stat -c %s "$_f";;
      kMDItemContentModificationDate) _mt_fmt "$(_mt_real stat -c %Y "$_f")" +'%Y-%m-%d %H:%M:%S %z';;
      kMDItemFSCreationDate) _mt_fmt "$(_mt_real stat -c %W "$_f")" +'%Y-%m-%d %H:%M:%S %z';;
      kMDItemKind) if [ -d "$_f" ]; then printf '"Folder"'; else printf '"Document"'; fi;;
      *) return 1;;
    esac
  }
  if [ -n "$_attr" ]; then
    _v=$(_val "$_attr") || { echo "$_attr = (null)"; return 0; }
    if [ "$_raw" = 1 ]; then printf '%s\000' "$_v"; else echo "$_attr = $_v"; fi
    return 0
  fi
  for _a in kMDItemContentModificationDate kMDItemFSCreationDate kMDItemFSName kMDItemFSSize kMDItemKind; do echo "$_a = $(_val "$_a")"; done
}
_mt_scutil() {
  case "$1" in
    --get) case "$2" in
        ComputerName|HostName|LocalHostName) _h=$(getprop net.hostname 2>/dev/null); [ -n "$_h" ] || _h=$(hostname 2>/dev/null); echo "${_h:-android}";;
        *) _mt_err scutil "no value for $2"; return 1;;
      esac;;
    *) _mt_err scutil "only --get ComputerName|HostName|LocalHostName is available on Android"; return 126;;
  esac
}
_mt_meminfo() { sed -n "s/^$1: *\\([0-9]*\\) kB.*/\\1/p" /proc/meminfo 2>/dev/null | head -n 1; }
_mt_vm_stat() {
  [ -r /proc/meminfo ] || { _mt_err vm_stat "/proc/meminfo is not readable"; return 1; }
  _pg() { echo $(( $(_mt_meminfo "$1") / 4 )); }
  echo "Mach Virtual Memory Statistics: (page size of 4096 bytes)   [from /proc/meminfo]"
  echo "Pages free:                            $(_pg MemFree)."
  echo "Pages active:                          $(_pg Active)."
  echo "Pages inactive:                        $(_pg Inactive)."
  echo "Pages file-backed:                     $(_pg Cached)."
  echo "Pages occupied by compressor:          $(_pg SwapCached)."
}
_mt_system_profiler() {
  _t=${1:-all}
  _hw() {
    echo "Hardware:"; echo; echo "    Hardware Overview:"; echo
    echo "      Model Name: $(getprop ro.product.model 2>/dev/null)"
    echo "      Manufacturer: $(getprop ro.product.manufacturer 2>/dev/null)"
    _soc=$(getprop ro.soc.model 2>/dev/null); [ -n "$_soc" ] || _soc=$(getprop ro.board.platform 2>/dev/null)
    echo "      Chip: $_soc"
    echo "      Total Number of Cores: $(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
    echo "      Memory: $(( $(_mt_meminfo MemTotal) / 1024 )) MB"
  }
  _sw() {
    echo "Software:"; echo; echo "    System Software Overview:"; echo
    echo "      System Version: Android $(getprop ro.build.version.release 2>/dev/null) (API $(getprop ro.build.version.sdk 2>/dev/null))"
    echo "      Kernel Version: $(uname -sr 2>/dev/null)"
    echo "      Build: $(getprop ro.build.id 2>/dev/null)"
  }
  case "$_t" in
    SPHardwareDataType) _hw;;
    SPSoftwareDataType) _sw;;
    all) _hw; echo; _sw;;
    *) _mt_err system_profiler "$_t: only SPHardwareDataType and SPSoftwareDataType exist on Android"; return 126;;
  esac
}
_mt_pmset() {
  case "$1 $2" in
    "-g batt")
      _c=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null); _s=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
      [ -n "$_c" ] || { _mt_err pmset "battery information is not readable here"; return 1; }
      case "$_s" in Charging|Full) _src="AC Power";; *) _src="Battery Power";; esac
      echo "Now drawing from '$_src'"; printf ' -InternalBattery-0 (id=0)\t%s%%; %s; present: true\n' "$_c" "$(printf '%s' "$_s" | tr 'A-Z' 'a-z')";;
    *) _mt_err pmset "only 'pmset -g batt' exists on Android"; return 126;;
  esac
}
_mt_caffeinate() {
  _t=""; _n=$#
  while [ "$_n" -gt 0 ]; do
    _x=$1; shift; _n=$((_n - 1))
    case "$_x" in
      -t) _t=$1; shift; _n=$((_n - 1));;
      -w) shift; _n=$((_n - 1));;
      -[dimsu]*) ;;
      *) set -- "$_x" "$@"; break;;
    esac
  done
  echo "caffeinate: Android has no wakelock for this shell; running without keeping the screen awake." >&2
  if [ $# -gt 0 ]; then "$@"; return $?; fi
  [ -n "$_t" ] && sleep "$_t"; return 0
}
_mt_xattr() { return 0; }    # quarantine flags (xattr -cr) do not exist here: nothing to clear
_mt_chflags() {
  case "$1" in
    nohidden|nouchg|nouchange|noschg) return 0;;
    uchg|uchange) shift; chmod a-w "$@";;
    *) _mt_err chflags "'$1' is not supported on Android"; return 126;;
  esac
}
_mt_screencapture() {
  _o=""; for _x in "$@"; do case "$_x" in -*) ;; *) _o=$_x;; esac; done
  [ -n "$_o" ] || _o="$HOME/Screenshot-$(date +%Y%m%d-%H%M%S).png"
  if _mt_have screencap && _mt_real screencap -p "$_o" 2>/dev/null; then echo "$_o"; return 0; fi
  _mt_err screencapture "Android only lets a shell with adb/root permission take screenshots"; return 1
}
_mt_diskutil() {
  case "$1" in
    list) _mt_real df ;;
    info) shift; _mt_real df -h "${1:-/}";;
    *) _mt_err diskutil "'$1' changes disks and is not available on Android"; return 126;;
  esac
}

# ------------------------------------------------------------------------------------------------ the dispatcher
mactr_run() {
  _tool=$1; [ $# -gt 0 ] && shift
  case "$_tool" in
    sed) _mt_sed "$@";;
    date) _mt_date "$@";;
    stat) _mt_stat "$@";;
    md5) _mt_md5 "$@";;
    shasum) _mt_shasum "$@";;
    sha1|sha224|sha256|sha384|sha512) _mt_shaN "${_tool#sha}" "$@";;
    mktemp) _mt_mktemp "$@";;
    ls) _mt_ls "$@";;
    jot) _mt_jot "$@";;
    ditto) _mt_ditto "$@";;
    mdfind) _mt_mdfind "$@";;
    mdls) _mt_mdls "$@";;
    scutil) _mt_scutil "$@";;
    vm_stat) _mt_vm_stat "$@";;
    system_profiler) _mt_system_profiler "$@";;
    pmset) _mt_pmset "$@";;
    caffeinate) _mt_caffeinate "$@";;
    xattr) _mt_xattr "$@";;
    chflags) _mt_chflags "$@";;
    screencapture) _mt_screencapture "$@";;
    diskutil) _mt_diskutil "$@";;
    hdiutil|networksetup|ioreg|launchctl|softwareupdate|mas|dtrace|qlmanage|automator|mdutil|mdimport|pkgutil|installer|drutil|lsappinfo|opensnoop|sc_usage|vmmap|heap|footprint|memory_pressure|dot_clean|scselect|hostinfo|sa|lastcomm|nfsd|configd|distnoted|ctf_insert|mcxrefresh)
      _mt_err "$_tool" "this is a macOS-only system tool; Android has no equivalent"; return 126;;
    *) return 99;;
  esac
}
