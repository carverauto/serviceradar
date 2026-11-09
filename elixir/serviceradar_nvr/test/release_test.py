"""Execute the shipped release with synthetic media and no control-plane services."""
import json
import os
import signal
import socket
import subprocess
import tarfile
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path


class NVRReleaseTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.release = Path(cls.temp.name) / "release"
        cls.release.mkdir()
        with tarfile.open(os.environ["NVR_RELEASE"]) as archive:
            archive.extractall(cls.release, filter="data")
        cls.binary = str(cls.release / "bin/serviceradar_nvr")
        cls.probe = str(Path(os.environ["NVR_PROBE"]).resolve())
        cls.ffmpeg = str(Path("third_party/membrane/media_test_tools/ffmpeg").resolve())

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)
        self.spool = self.root / "spool"
        self.spool.mkdir(mode=0o700)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        self.env = {
            "PATH": "/usr/bin:/bin", "HOME": str(self.root), "TMPDIR": str(self.root),
            "RELEASE_COOKIE": "synthetic_nvr_cookie", "ERL_CRASH_DUMP": "/dev/null",
            "SERVICERADAR_NVR_SPOOL_ROOT": str(self.spool),
            "SERVICERADAR_NVR_STORAGE_ID": "00000000-0000-4000-8000-000000000011",
            "NVR_TEST_EXPECTED_STORAGE_ID": "00000000-0000-4000-8000-000000000011",
            "SERVICERADAR_NVR_MAX_SESSIONS": "2", "SERVICERADAR_NVR_HEALTH_PORT": str(port),
            "NVR_TEST_RECEIPT": str(self.root / "receipt.json"),
            "NVR_TEST_H264": str(self.root / "synthetic.h264"),
            "NVR_TEST_MP4": str(self.root / "recovered.mp4"),
        }

    def run_probe(self, mode):
        env = self.env | {"NVR_TEST_MODE": mode}
        result = subprocess.run([self.binary, "eval", f'Code.require_file("{self.probe}")'],
                                env=env, capture_output=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(b"NVR_RELEASE_PROBE_OK", result.stdout)

    def test_media_survives_release_restart_and_decodes_identically(self):
        # Exercise the same member-to-volume selection used by the StatefulSet.
        identity = self.env.pop("SERVICERADAR_NVR_STORAGE_ID")
        self.env["SERVICERADAR_NVR_MEMBER_NAME"] = "synthetic-nvr-1"
        self.env["SERVICERADAR_NVR_STORAGE_IDS"] = json.dumps({
            "synthetic-nvr-0": "00000000-0000-4000-8000-000000000012",
            "synthetic-nvr-1": identity,
        })
        source = self.make_media()
        self.run_probe("record")
        receipt = json.loads(Path(self.env["NVR_TEST_RECEIPT"]).read_text())
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(receipt["block_bytes"])
        self.run_probe("recover")
        expected = self.decode(source)
        self.assertEqual(len(expected), 75 * 64 * 64 * 3 // 2)
        self.assertEqual(self.decode(self.env["NVR_TEST_MP4"]), expected)

    def make_media(self, frames=75):
        source = self.env["NVR_TEST_H264"]
        subprocess.run([self.ffmpeg, "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                        "testsrc2=size=64x64:rate=15", "-frames:v", str(frames), "-c:v", "libx264",
                        "-profile:v", "baseline", "-bf", "0", "-g", "30", "-sc_threshold", "0",
                        "-x264-params", "aud=1:repeat-headers=1", "-f", "h264", source],
                       check=True, capture_output=True, timeout=30)
        return source

    def decode(self, path):
        return subprocess.run([self.ffmpeg, "-nostdin", "-v", "error", "-xerror", "-threads", "1",
                                   "-i", path, "-map", "0:v:0", "-fps_mode", "passthrough", "-f",
                                   "rawvideo", "-pix_fmt", "yuv420p", "pipe:1"],
                              check=True, capture_output=True, timeout=30).stdout

    def test_rotation_preserves_frames_and_stops_before_unreserved_block(self):
        # The first boundary rotates during push; the second during final flush.
        source = self.make_media(510)
        expected = self.decode(source)
        self.assertEqual(len(expected), 510 * 64 * 64 * 3 // 2)
        # Enough for one reservation and these retained bytes, not two reservations.
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = "20000000"
        self.run_probe("rotation")
        receipt = json.loads(Path(self.env["NVR_TEST_RECEIPT"]).read_text())
        self.assertEqual(len(list(self.spool.iterdir())), 4)
        self.run_probe("recover_rotation")
        decoded = [self.decode(self.env["NVR_TEST_MP4"] + f".{i}") for i in range(3)]
        self.assertEqual([len(x) for x in decoded], [n * 64 * 64 * 3 // 2 for n in [240, 240, 30]])
        self.assertEqual(b"".join(decoded), expected)

        # A fresh one-block budget admits capture but cannot fund its successor.
        self.spool = self.root / "limited-spool"
        self.spool.mkdir(mode=0o700)
        self.env["SERVICERADAR_NVR_SPOOL_ROOT"] = str(self.spool)
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(receipt["block_bytes"])
        self.run_probe("rotation_budget")
        self.assertEqual(len(list(self.spool.iterdir())), 2)
        self.run_probe("recover_rotation")
        self.assertEqual(self.decode(self.env["NVR_TEST_MP4"] + ".0"), expected[:240 * 64 * 64 * 3 // 2])

    def test_deadline_and_producer_loss_release_admission(self):
        self.env["SERVICERADAR_NVR_MAX_DURATION_MS"] = "500"
        self.run_probe("lifecycle")
        self.assertEqual(sorted(p.name for p in self.spool.iterdir()), [".storage-id"])

    def test_concurrent_reservations_and_accounting_restart(self):
        self.env["SERVICERADAR_NVR_MAX_SESSIONS"] = "3"
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = "20000000"
        self.run_probe("capacity")
        self.assertEqual(sorted(p.name for p in self.spool.iterdir()), [".storage-id"])

    def test_physical_free_reserve_refuses_without_creating_media(self):
        disk = os.statvfs(self.spool)
        self.env["SERVICERADAR_NVR_RESERVE_BYTES"] = str(disk.f_bavail * disk.f_frsize + 1024**3)
        self.run_probe("pressure")
        self.assertEqual(sorted(p.name for p in self.spool.iterdir()), [".storage-id"])

    def test_unrecognized_inventory_is_preserved_and_refused(self):
        marker = self.spool / ".storage-id"
        marker.write_text(self.env["NVR_TEST_EXPECTED_STORAGE_ID"] + "\n")
        marker.chmod(0o600)
        block = self.spool / ("a" * 64)
        block.mkdir(mode=0o700)
        target = self.root / "retained-evidence"
        target.write_bytes(b"invented retained media")
        (block / "media.m4s").symlink_to(target)
        self.run_probe("inventory")
        self.assertTrue((block / "media.m4s").is_symlink())
        self.assertEqual(target.read_bytes(), b"invented retained media")

    def test_inventory_limit_refuses_even_empty_retained_blocks(self):
        marker = self.spool / ".storage-id"
        marker.write_text(self.env["NVR_TEST_EXPECTED_STORAGE_ID"] + "\n")
        marker.chmod(0o600)
        for index in range(4096):
            (self.spool / f"{index:064x}").mkdir(mode=0o700)
        self.run_probe("inventory_limit")
        self.assertEqual(len(list(self.spool.iterdir())), 4097)

    def test_foreground_release_probes_refuse_uninitialized_storage(self):
        proc = subprocess.Popen([self.binary, "start"], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            base = "http://127.0.0.1:" + self.env["SERVICERADAR_NVR_HEALTH_PORT"]
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    self.fail(f"release exited: {proc.communicate()[0]}")
                try:
                    with urllib.request.urlopen(base + "/healthz", timeout=1) as reply:
                        self.assertEqual(reply.read(), b"ok")
                    break
                except urllib.error.URLError:
                    time.sleep(0.05)
            else:
                self.fail("release did not become live")
            for path, status in [("/readyz", 503), ("/recordings", 404)]:
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    urllib.request.urlopen(base + path, timeout=2)
                self.assertEqual(failure.exception.code, status)
            self.assertEqual(list(self.spool.iterdir()), [])
        finally:
            proc.send_signal(signal.SIGTERM)
            proc.communicate(timeout=15)

    def test_unknown_member_cannot_adopt_another_volume(self):
        del self.env["SERVICERADAR_NVR_STORAGE_ID"]
        self.env["SERVICERADAR_NVR_MEMBER_NAME"] = "synthetic-nvr-1"
        self.env["SERVICERADAR_NVR_STORAGE_IDS"] = json.dumps({
            "synthetic-nvr-0": self.env["NVR_TEST_EXPECTED_STORAGE_ID"],
        })
        result = subprocess.run([self.binary, "eval", "{:ok, _} = Application.ensure_all_started(:serviceradar_nvr)"],
                                env=self.env, capture_output=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"invalid_nvr_storage_member", result.stdout + result.stderr)
        self.assertEqual(list(self.spool.iterdir()), [])

    def test_invalid_limits_fail_boot(self):
        for setting in ["MAX_SESSIONS", "MAX_SPOOL_BYTES", "RESERVE_BYTES"]:
            with self.subTest(setting=setting):
                env = self.env | {"SERVICERADAR_NVR_" + setting: "0"}
                result = subprocess.run([self.binary, "eval", "{:ok, _} = Application.ensure_all_started(:serviceradar_nvr)"],
                                        env=env, capture_output=True, timeout=20)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"invalid_nvr_limit", result.stdout + result.stderr)
                self.assertEqual(list(self.spool.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
