#!/usr/bin/env python3
"""validate-image.py <sysupgrade.bin> <sku> [--json]

Checks that a JioRouter AX6000 sysupgrade image really is the image for <sku>
(6111|6411|6611|6711|6811|6911) before anyone flashes it. Standard library only.
Run it with `python3 -I` and treat the image as untrusted data: it is only parsed,
never executed or extracted to disk.

Checks (all must pass, exit 0; any failure exits 1; usage/IO errors exit 2):
  1. tar contains sysupgrade-<board>/{CONTROL,kernel,root}; CONTROL BOARD == jiorouter_ax6000-jidu<sku>
  2. fwtool metadata lists supported_devices == jiorouter,ax6000-jidu<sku> (only)
  3. kernel is a FIT image; its DTB has model, compatible and the ath11k calibration
     variant on BOTH radios (IPQ9574 AHB and QCN9074 PCIe) matching <sku>
  4. FEAT-14: the wcss@4ab00000 reserved-memory node and the q6wcss remoteproc are enabled,
     otherwise the integrated 2.4 GHz radio cannot start
  5. root is squashfs; sizes are plausible for the 'ubi' partition (225 MiB)
"""
import json, os, re, struct, sys, tarfile

SKUS = ("6111", "6411", "6611", "6711", "6811", "6911")
UBI_BYTES = 0x0E100000
FDT_MAGIC = 0xD00DFEED


# ---- minimal flattened device tree parser -------------------------------------------------
class Node:
    __slots__ = ("name", "props", "kids")

    def __init__(self, name):
        self.name, self.props, self.kids = name, {}, []

    def walk(self, path=""):
        p = path + "/" + self.name if self.name else path
        yield p, self
        for k in self.kids:
            yield from k.walk(p)

    def get(self, name):
        for k in self.kids:
            if k.name == name:
                return k
        return None


def parse_fdt(buf, base=0):
    """Return (root Node, totalsize). buf[base:] must start with an FDT header."""
    if len(buf) < base + 40:
        raise ValueError("truncated FDT header")
    (magic, total, off_struct, off_strings, _off_rsv, _ver, _lc, _boot, size_strings, size_struct) = \
        struct.unpack_from(">10I", buf, base)
    if magic != FDT_MAGIC:
        raise ValueError("bad FDT magic 0x%08x" % magic)
    if base + total > len(buf):
        raise ValueError("FDT totalsize beyond the data")
    strings = buf[base + off_strings: base + off_strings + size_strings]
    pos, end = base + off_struct, base + off_struct + size_struct
    stack, root = [], None
    while pos < end:
        (tok,) = struct.unpack_from(">I", buf, pos)
        pos += 4
        if tok == 1:  # BEGIN_NODE
            z = buf.index(b"\0", pos)
            node = Node(buf[pos:z].decode("ascii", "replace"))
            pos = (z + 1 + 3) & ~3
            if stack:
                stack[-1].kids.append(node)
            else:
                root = node
            stack.append(node)
        elif tok == 2:  # END_NODE
            stack.pop()
        elif tok == 3:  # PROP
            ln, nameoff = struct.unpack_from(">II", buf, pos)
            pos += 8
            name = strings[nameoff: strings.index(b"\0", nameoff)].decode("ascii", "replace")
            stack[-1].props[name] = bytes(buf[pos: pos + ln])
            pos = (pos + ln + 3) & ~3
        elif tok == 4:  # NOP
            continue
        elif tok == 9:  # END
            break
        else:
            raise ValueError("bad FDT token %d" % tok)
    if root is None or stack:
        raise ValueError("unbalanced FDT structure")
    return root, total


def s(node, prop):
    v = node.props.get(prop)
    return None if v is None else v.split(b"\0")[0].decode("utf-8", "replace")


def strlist(node, prop):
    v = node.props.get(prop)
    return [] if v is None else [x.decode("utf-8", "replace") for x in v.split(b"\0") if x]


def enabled(node):
    st = s(node, "status")
    return st is None or st in ("okay", "ok")


# ---- the checks -----------------------------------------------------------------------------
def fit_dtb(kernel):
    """Return the DTB bytes of the default configuration's first fdt image."""
    fit, _total = parse_fdt(kernel)
    images, confs = fit.get("images"), fit.get("configurations")
    if images is None or confs is None:
        raise ValueError("kernel is not a FIT image (no /images or /configurations)")
    want = None
    dflt = s(confs, "default")
    for c in confs.kids:
        if dflt is None or c.name == dflt:
            want = s(c, "fdt")
            if want:
                break
    if want is None:
        raise ValueError("FIT has no default configuration with an fdt")
    img = images.get(want)
    if img is None:
        raise ValueError("FIT fdt image %r not found" % want)
    data = img.props.get("data")
    if data is None:  # external data
        off, size = img.props.get("data-offset"), img.props.get("data-size")
        if off is None or size is None:
            raise ValueError("FIT fdt image has no data")
        o, sz = struct.unpack(">I", off)[0], struct.unpack(">I", size)[0]
        total = struct.unpack_from(">I", kernel, 4)[0]
        start = ((total + 3) & ~3) + o
        data = kernel[start: start + sz]
    return data, want


def check_image(path, sku):
    res, ok = [], True

    def chk(name, passed, detail=""):
        nonlocal ok
        ok = ok and passed
        res.append({"check": name, "ok": bool(passed), "detail": detail})

    board = "jiorouter_ax6000-jidu" + sku
    compat = "jiorouter,ax6000-jidu" + sku
    model = "JioRouter AX6000 JIDU" + sku
    variant = "JIDU" + sku

    try:
        tf = tarfile.open(path, "r:")
    except (tarfile.TarError, OSError) as e:
        chk("tar container", False, str(e))
        return ok, res
    try:
        return _check_members(tf, path, sku, board, compat, model, variant, res, chk, lambda: ok)
    except (tarfile.TarError, EOFError, OSError, struct.error, ValueError, KeyError) as e:
        chk("image readable", False, "%s: %s" % (type(e).__name__, e))
        return False, res


def _check_members(tf, path, sku, board, compat, model, variant, res, chk, get_ok):
    members = {m.name: m for m in tf.getmembers()}
    prefix = "sysupgrade-" + board + "/"
    got = sorted(n for n in members if n.endswith(("/CONTROL", "/kernel", "/root")))
    chk("tar members", all(prefix + x in members for x in ("CONTROL", "kernel", "root")), ", ".join(got))
    if not get_ok():
        return False, res

    control = tf.extractfile(members[prefix + "CONTROL"]).read().decode("ascii", "replace")
    m = re.search(r"^BOARD=(\S+)", control, re.M)
    chk("CONTROL BOARD", bool(m) and m.group(1) == board, "found %s, want %s" % (m.group(1) if m else None, board))

    raw = open(path, "rb").read()
    mj = re.search(rb'"supported_devices"\s*:\s*(\[[^\]]*\])', raw[-8192:])
    try:
        devs = json.loads(mj.group(1).decode()) if mj else None
    except ValueError:
        devs = None
    chk("metadata supported_devices", devs == [compat], "found %s, want %s" % (devs, [compat]))

    kernel = tf.extractfile(members[prefix + "kernel"]).read()
    root = tf.extractfile(members[prefix + "root"]).read()
    chk("root is squashfs", root[:4] in (b"hsqs", b"sqsh"), "magic %r" % root[:4])
    chk("sizes plausible", 0 < len(kernel) <= 16 << 20 and len(kernel) + len(root) < UBI_BYTES,
        "kernel %d, root %d, ubi %d" % (len(kernel), len(root), UBI_BYTES))

    try:
        dtb, fdtname = fit_dtb(kernel)
        tree, _ = parse_fdt(dtb)
    except (ValueError, struct.error) as e:
        chk("FIT/DTB parse", False, str(e))
        return False, res
    chk("FIT/DTB parse", True, "fdt image %s, %d bytes" % (fdtname, len(dtb)))

    chk("DTB model", s(tree, "model") == model, "found %r, want %r" % (s(tree, "model"), model))
    cl = strlist(tree, "compatible")
    chk("DTB compatible", bool(cl) and cl[0] == compat, "found %s, want first = %s" % (cl, compat))

    radios = {}
    for path_, n in tree.walk():
        c = strlist(n, "compatible")
        kind = "ahb" if "qcom,ipq9574-wifi" in c else "pci" if "pci17cb,1104" in c else None
        if kind:
            v = s(n, "qcom,calibration-variant") or s(n, "qcom,ath11k-calibration-variant")
            radios[kind] = (v, enabled(n), path_)
    for kind, label in (("ahb", "2.4 GHz IPQ9574"), ("pci", "5 GHz QCN9074")):
        r = radios.get(kind)
        chk("calibration variant, " + label, bool(r) and r[0] == variant and r[1],
            "found %s, want %r enabled" % (("%r enabled=%s" % (r[0], r[1])) if r else "node missing", variant))

    wcss = [(p, n) for p, n in tree.walk() if n.name.startswith("wcss@4ab00000")]
    chk("FEAT-14 q6_region (wcss@4ab00000) enabled", bool(wcss) and all(enabled(n) for _, n in wcss),
        "nodes %s, status %s" % ([p for p, _ in wcss], [s(n, "status") or "(none=okay)" for _, n in wcss]))
    rp = [(p, n) for p, n in tree.walk() if n.name.startswith("remoteproc@cd00000")]
    chk("q6wcss remoteproc enabled", bool(rp) and all(enabled(n) for _, n in rp),
        "nodes %s, status %s" % ([p for p, _ in rp], [s(n, "status") or "(none=okay)" for _, n in rp]))
    return get_ok(), res


def main(argv):
    args = [a for a in argv[1:] if a != "--json"]
    if len(args) != 2 or args[1] not in SKUS:
        print(__doc__)
        return 2
    if not os.path.isfile(args[0]):
        print("cannot read image: %s" % args[0], file=sys.stderr)
        return 2
    ok, res = check_image(args[0], args[1])
    if "--json" in argv:
        print(json.dumps({"image": args[0], "sku": args[1], "ok": ok, "checks": res}, indent=1))
    else:
        for r in res:
            print("%s  %-46s %s" % ("PASS" if r["ok"] else "FAIL", r["check"], r["detail"]))
        print("RESULT: %s for jidu%s" % ("OK" if ok else "REJECTED", args[1]))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
