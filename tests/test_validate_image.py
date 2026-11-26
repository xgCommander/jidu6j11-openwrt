#!/usr/bin/env python3
"""Tests for scripts/validate-image.py. Needs real images (never committed):
  VALIDATE_GOOD_IMAGE=<6911 sysupgrade.bin that is fine>   VALIDATE_AFFECTED_IMAGE=<6911 image with q6_region disabled>
Run: python3 -I tests/test_validate_image.py
"""
import io, os, subprocess, sys, tarfile, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
VAL = os.path.join(HERE, "..", "scripts", "validate-image.py")
GOOD, AFFECTED = os.environ.get("VALIDATE_GOOD_IMAGE"), os.environ.get("VALIDATE_AFFECTED_IMAGE")
PRE = "sysupgrade-jiorouter_ax6000-jidu6911/"


def run(img, sku="6911"):
    p = subprocess.run([sys.executable, "-I", VAL, img, sku], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


@unittest.skipUnless(GOOD and os.path.isfile(GOOD), "set VALIDATE_GOOD_IMAGE")
class T(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        with open(GOOD, "rb") as f:
            cls.raw = f.read()
        t = tarfile.open(GOOD)
        cls.mem = {m.name: t.extractfile(m).read() for m in t.getmembers() if m.isfile()}

    def build(self, name, control=None, kernel=None, root=None, tail=None):
        path = os.path.join(self.tmp, name)
        with tarfile.open(path, "w") as o:
            for n, d in (("CONTROL", control), ("kernel", kernel), ("root", root)):
                d = d if d is not None else self.mem[PRE + n]
                ti = tarfile.TarInfo(PRE + n)
                ti.size = len(d)
                o.addfile(ti, io.BytesIO(d))
        with open(path, "ab") as f:
            f.write(tail if tail is not None else self.raw[-512:])
        return path

    def test_good_passes(self):
        rc, out = run(GOOD)
        self.assertEqual(rc, 0, out)

    def test_wrong_sku_fails(self):
        for sku in ("6111", "6411", "6611", "6711", "6811"):
            self.assertEqual(run(GOOD, sku)[0], 1)

    def test_bad_sku_arg(self):
        self.assertEqual(run(GOOD, "7000")[0], 2)

    def test_missing_file(self):
        self.assertEqual(run("/nonexistent.bin")[0], 2)

    def test_mislabelled_control(self):
        rc, out = run(self.build("c.bin", control=b"BOARD=jiorouter_ax6000-jidu6411\n"))
        self.assertEqual(rc, 1)
        self.assertIn("FAIL  CONTROL BOARD", out)

    def test_mislabelled_dtb_model_same_length(self):
        k = bytearray(self.mem[PRE + "kernel"])
        i = k.find(b"JioRouter AX6000 JIDU6911")
        self.assertGreater(i, 0)
        k[i + 21:i + 25] = b"6411"
        rc, out = run(self.build("m.bin", kernel=bytes(k)))
        self.assertEqual(rc, 1)
        self.assertIn("FAIL  DTB model", out)

    def test_mislabelled_calibration_variant(self):
        k = bytearray(self.mem[PRE + "kernel"])
        n = k.count(b"JIDU6911")
        self.assertGreaterEqual(n, 2)
        j = 0
        while True:
            j = k.find(b"JIDU6911", j)
            if j < 0:
                break
            if k[j - 21:j] != b"JioRouter AX6000 ":  # leave the model string alone
                k[j + 4:j + 8] = b"6111"
            j += 8
        rc, out = run(self.build("v.bin", kernel=bytes(k)))
        self.assertEqual(rc, 1)
        self.assertIn("FAIL  calibration variant", out)

    def test_bad_fit_root_metadata_nottar_truncated(self):
        k = bytearray(self.mem[PRE + "kernel"]); k[0:4] = b"\0\0\0\0"
        cases = {
            "fit": self.build("f.bin", kernel=bytes(k)),
            "root": self.build("r.bin", root=b"XXXX" + self.mem[PRE + "root"][4:]),
            "meta": self.build("md.bin", tail=self.raw[-512:].replace(b"jidu6911", b"jidu6111")),
        }
        for name, p in cases.items():
            self.assertEqual(run(p)[0], 1, name)
        for name, data in (("nottar", b"hello" * 1000), ("trunc", self.raw[:100000]), ("empty", b"")):
            p = os.path.join(self.tmp, name)
            with open(p, "wb") as f:
                f.write(data)
            rc, out = run(p)
            self.assertEqual(rc, 1, name)
            self.assertNotIn("Traceback", out, name)

    @unittest.skipUnless(AFFECTED and os.path.isfile(AFFECTED or ""), "set VALIDATE_AFFECTED_IMAGE")
    def test_feat14_affected_image_rejected(self):
        rc, out = run(AFFECTED)
        self.assertEqual(rc, 1)
        self.assertIn("FAIL  FEAT-14 q6_region", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
