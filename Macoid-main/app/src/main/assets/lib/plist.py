#!/usr/bin/env python3
# plutil / PlistBuddy replacement for Macoid (runs in the local Linux, uses only the Python stdlib).
import sys, os, json, plistlib, datetime, io

def load(path):
    data = sys.stdin.buffer.read() if path == "-" else open(path, "rb").read()
    try:
        return plistlib.loads(data)
    except Exception:
        try:
            return json.loads(data.decode("utf-8"))
        except Exception:
            raise SystemExit("%s: Property List error: unable to parse (not a plist or JSON)" % path)

def jsonable(o):
    if isinstance(o, dict): return {k: jsonable(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)): return [jsonable(v) for v in o]
    if isinstance(o, bytes): import base64; return base64.b64encode(o).decode()
    if isinstance(o, datetime.datetime): return o.strftime("%Y-%m-%dT%H:%M:%SZ")
    return o

def dump(obj, fmt):
    if fmt == "xml1": return plistlib.dumps(obj, fmt=plistlib.FMT_XML)
    if fmt == "binary1": return plistlib.dumps(obj, fmt=plistlib.FMT_BINARY)
    if fmt == "json": return (json.dumps(jsonable(obj), indent=2, sort_keys=True) + "\n").encode()
    if fmt == "swift": raise SystemExit("plutil: -convert swift is not supported here")
    raise SystemExit("plutil: unknown format '%s' (use xml1, binary1 or json)" % fmt)

def pretty(o, ind=0):   # plutil -p style
    pad = "  " * ind
    if isinstance(o, dict):
        if not o: return "{\n" + pad + "}"
        return "{\n" + "".join('%s  "%s" => %s\n' % (pad, k, pretty(v, ind + 1)) for k, v in o.items()) + pad + "}"
    if isinstance(o, list):
        if not o: return "[\n" + pad + "]"
        return "[\n" + "".join("%s  %d => %s\n" % (pad, i, pretty(v, ind + 1)) for i, v in enumerate(o)) + pad + "]"
    if isinstance(o, bool): return "1" if o else "0"
    if isinstance(o, bytes): return "{length = %d, bytes = 0x%s}" % (len(o), o.hex())
    if isinstance(o, str): return '"%s"' % o
    return str(o)

def tname(o):
    return {bool: "bool", int: "integer", float: "float", str: "string", bytes: "data",
            datetime.datetime: "date", dict: "dictionary", list: "array"}.get(type(o), "string")

def keypath(obj, kp):
    cur = obj
    for part in [p for p in kp.split(".") if p != ""]:
        if isinstance(cur, dict) and part in cur: cur = cur[part]
        elif isinstance(cur, list) and part.isdigit() and int(part) < len(cur): cur = cur[int(part)]
        else: raise KeyError(kp)
    return cur

def plutil(a):
    if not a or a[0] in ("-help", "--help", "-h"):
        print("usage: plutil [-lint] [-p] [-convert fmt] [-extract keypath fmt] [-type keypath] [-o path|-] [-r] file ..."); return 0
    out = None; fmt = None; mode = None; kp = None; efmt = "raw"; files = []; i = 0
    while i < len(a):
        x = a[i]
        if x in ("-lint", "-p", "-type"): mode = x
        elif x == "-convert": mode = "convert"; fmt = a[i + 1]; i += 1
        elif x == "-extract": mode = "extract"; kp = a[i + 1]; efmt = a[i + 2]; i += 2
        elif x == "-o": out = a[i + 1]; i += 1
        elif x in ("-r", "-s", "-n", "--"): pass
        elif x == "-type": pass
        elif x.startswith("-") and x != "-": raise SystemExit("plutil: unknown option %s" % x)
        else: files.append(x)
        i += 1
    if mode == "-type":
        kp = files.pop(0) if files else ""
    rc = 0
    for f in files or ["-"]:
        try:
            obj = load(f)
        except SystemExit as e:
            print(e, file=sys.stderr); rc = 1; continue
        if mode == "-lint" or mode is None:
            print("%s: OK" % f)
        elif mode == "-p":
            print(pretty(obj))
        elif mode == "-type":
            try: print(tname(keypath(obj, kp)))
            except KeyError: print("No value at that key path or invalid key path: %s" % kp, file=sys.stderr); rc = 1
        elif mode == "convert":
            data = dump(obj, fmt)
            dst = out if out else f
            if dst == "-": sys.stdout.buffer.write(data)
            else:
                if out is None and fmt == "json" and f.endswith((".plist", ".strings")): dst = os.path.splitext(f)[0] + ".json"
                open(dst, "wb").write(data)
        elif mode == "extract":
            try: v = keypath(obj, kp)
            except KeyError: print("No value at that key path or invalid key path: %s" % kp, file=sys.stderr); rc = 1; continue
            if efmt == "raw":
                data = (str(v) if not isinstance(v, (dict, list)) else json.dumps(jsonable(v))) + "\n"
                data = ("true\n" if v is True else "false\n" if v is False else data).encode()
            else:
                data = dump(v, efmt)
            if out and out != "-": open(out, "wb").write(data)
            else: sys.stdout.buffer.write(data)
    return rc

# ---------------------------------------------------------------- PlistBuddy
def pb_path(s):
    parts = s.lstrip(":").split(":")
    last = parts[-1] if len(parts) > 1 and parts[-1] == "" else None   # "Arr:" = append to array Arr
    parts = [p for p in parts if p != ""]
    return parts + [""] if last is not None else parts

def pb_get(obj, parts):
    cur = obj
    for p in parts:
        if isinstance(cur, dict): cur = cur[p]
        elif isinstance(cur, list): cur = cur[int(p)]
        else: raise KeyError(p)
    return cur

def pb_parent(obj, parts):
    return pb_get(obj, parts[:-1]), parts[-1]

def pb_value(t, v):
    t = t.lower()
    if t == "string": return v
    if t == "bool": return v.lower() in ("true", "yes", "1")
    if t == "integer": return int(v, 0)
    if t in ("real", "float"): return float(v)
    if t == "array": return []
    if t == "dict": return {}
    if t == "date": return datetime.datetime.strptime(v, "%Y-%m-%d %H:%M:%S")
    if t == "data": return v.encode()
    raise SystemExit("Unrecognized Type: %s" % t)

def pb_print(o, ind=0):
    pad = "    " * ind
    if isinstance(o, dict):
        return "Dict {\n" + "".join("%s    %s = %s\n" % (pad, k, pb_print(v, ind + 1)) for k, v in o.items()) + pad + "}"
    if isinstance(o, list):
        return "Array {\n" + "".join("%s    %s\n" % (pad, pb_print(v, ind + 1)) for v in o) + pad + "}"
    if isinstance(o, bool): return "true" if o else "false"
    if isinstance(o, bytes): return o.decode("latin-1")
    return str(o)

def plistbuddy(a):
    cmds = []; f = None; i = 0
    while i < len(a):
        if a[i] == "-c": cmds.append(a[i + 1]); i += 2
        elif a[i] in ("-x", "-h", "--help"): i += 1
        else: f = a[i]; i += 1
    if not f or not cmds:
        print("usage: PlistBuddy -c \"command\" [-c ...] file.plist   (Print, Set, Add, Delete, Copy, Merge-less subset)"); return 1
    if os.path.exists(f): obj = load(f)
    else: obj = {}
    fmt = plistlib.FMT_XML
    try:
        if os.path.exists(f) and open(f, "rb").read(6) == b"bplist": fmt = plistlib.FMT_BINARY
    except Exception: pass
    dirty = False
    for c in cmds:
        parts = c.split(None, 1); cmd = parts[0].lower(); rest = parts[1] if len(parts) > 1 else ""
        try:
            if cmd == "print":
                t = pb_get(obj, pb_path(rest)) if rest.strip() else obj
                print(pb_print(t))
            elif cmd == "set":
                p, _, v = rest.partition(" "); path = pb_path(p); par, k = pb_parent(obj, path)
                old = par[int(k)] if isinstance(par, list) else par[k]
                nv = type(old)(v) if not isinstance(old, bool) and isinstance(old, (int, float, str)) else (v.lower() in ("true", "yes", "1"))
                if isinstance(par, list): par[int(k)] = nv
                else: par[k] = nv
                dirty = True
            elif cmd == "add":
                toks = rest.split(None, 2); path = pb_path(toks[0]); t = toks[1]; v = toks[2] if len(toks) > 2 else ""
                par, k = pb_parent(obj, path)
                if isinstance(par, list):
                    par.append(pb_value(t, v)) if not k.isdigit() else par.insert(int(k), pb_value(t, v))
                else:
                    if k in par: print("Add: \"%s\" Entry Already Exists" % ":".join(path)); return 1
                    par[k] = pb_value(t, v)
                dirty = True
            elif cmd == "delete":
                path = pb_path(rest)
                if not path: obj = {}
                else:
                    par, k = pb_parent(obj, path)
                    if isinstance(par, list): del par[int(k)]
                    else: del par[k]
                dirty = True
            elif cmd == "copy":
                s, d = rest.split(None, 1); val = pb_get(obj, pb_path(s)); par, k = pb_parent(obj, pb_path(d))
                if isinstance(par, list): par.append(val)
                else: par[k] = val
                dirty = True
            elif cmd in ("save", "exit"): pass
            else:
                print("Unrecognized Command: %s" % cmd); return 1
        except (KeyError, IndexError, ValueError):
            print('%s: Entry, "%s", Does Not Exist' % (cmd.capitalize(), rest.split()[0] if rest else "")); return 1
    if dirty: open(f, "wb").write(plistlib.dumps(obj, fmt=fmt))
    return 0

if __name__ == "__main__":
    prog = os.path.basename(sys.argv[0]).lower()
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode in ("--plutil", "--plistbuddy"):
        sys.exit((plutil if mode == "--plutil" else plistbuddy)(sys.argv[2:]) or 0)
    sys.exit((plistbuddy if "buddy" in prog else plutil)(sys.argv[1:]) or 0)
