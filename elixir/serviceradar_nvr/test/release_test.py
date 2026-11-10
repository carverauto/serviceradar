"""Execute the shipped release with synthetic media and no control-plane services."""
import hashlib
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
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(receipt["block_bytes"] + 65536 + 512)
        self.run_probe("recover")
        expected = self.decode(source)
        self.assertEqual(len(expected), 75 * 64 * 64 * 3 // 2)
        self.assertEqual(self.decode(self.env["NVR_TEST_MP4"]), expected)

    def test_publication_allows_capture_rotation_and_expires_after_caller_loss(self):
        block = self.record_publication_block()
        self.env["NVR_TEST_BLOCK_ID"] = block.name
        self.env["NVR_TEST_H264"] = str(self.root / "concurrent.h264")
        source = self.make_media(510)
        self.run_probe("publication_concurrent")
        paths = json.loads(Path(self.env["NVR_TEST_RECEIPT"]).read_text())
        self.assertEqual(len(paths), 3)
        decoded = []
        for index, directory in enumerate(paths):
            directory = Path(directory)
            output = self.root / f"concurrent-{index}.mp4"
            output.write_bytes((directory / "init.mp4").read_bytes() +
                               (directory / "media.m4s").read_bytes())
            decoded.append(self.decode(output))
        self.assertEqual(b"".join(decoded), self.decode(source))

    def test_publication_intent_survives_restart_and_preserves_conflicts(self):
        block = self.record_publication_block()
        descriptor = Path(self.env["NVR_TEST_MP4"] + ".0.json").read_bytes()
        self.run_probe("publication_prepare")
        intent = block / "publication.json"
        original = intent.read_bytes()
        document = json.loads(original)
        self.assertEqual(set(document), {"version", "storage_id", "block_id", "operation_id",
                                         "recording_block_id", "descriptor_sha256", "descriptor"})
        self.assertEqual(document["version"], 1)
        self.assertEqual(document["storage_id"], self.env["SERVICERADAR_NVR_STORAGE_ID"])
        self.assertEqual(document["block_id"], block.name)
        self.assertEqual(document["operation_id"], "00000000-0000-4000-8000-000000000021")
        self.assertEqual(document["recording_block_id"], "00000000-0000-4000-8000-000000000022")
        self.assertEqual(document["descriptor_sha256"], hashlib.sha256(descriptor).hexdigest())
        self.assertEqual(document["descriptor"], json.loads(descriptor))
        self.assertEqual(original, json.dumps(document, sort_keys=True, separators=(",", ":")).encode())
        self.assertLessEqual(len(original), 65536)
        self.assertEqual(intent.stat().st_mode & 0o777, 0o600)
        inode, mtime = intent.stat().st_ino, intent.stat().st_mtime_ns
        # Restart with no room for another byte: exact retry must still succeed.
        used = sum(p.stat().st_size for p in block.iterdir())
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(used)
        self.run_probe("publication_retry")
        self.assertEqual((intent.stat().st_ino, intent.stat().st_mtime_ns), (inode, mtime))
        self.assertEqual(intent.read_bytes(), original)
        self.env["NVR_TEST_BLOCK_ID"] = block.name
        self.run_probe("publication_storage_binding")

        for damaged in [original[:17], original + b" ", b"x" * 65537,
                        json.dumps(document | {"storage_id": "00000000-0000-4000-8000-000000000099"},
                                   sort_keys=True, separators=(",", ":")).encode()]:
            intent.write_bytes(damaged)
            self.run_probe("publication_error")
            self.assertEqual(intent.read_bytes(), damaged)
        intent.write_bytes(original)
        media = block / "media.m4s"
        damaged_media = bytearray(media.read_bytes())
        damaged_media[-1] ^= 1
        media.write_bytes(damaged_media)
        self.run_probe("publication_error")
        self.assertEqual(intent.read_bytes(), original)
        self.assertEqual(media.read_bytes(), damaged_media)

    def test_publication_records_require_space_before_creating_metadata(self):
        block = self.record_publication_block()
        retained = sum(p.stat().st_size for p in block.iterdir())
        block_bytes = json.loads(Path(self.env["NVR_TEST_RECEIPT"]).read_text())["block_bytes"]
        # Keep room for the retained block's two bounded metadata records and
        # the next block's records, independently of its media reservation.
        capture_budget = retained + block_bytes + 2 * (65536 + 512) - 1
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(capture_budget)
        self.run_probe("publication_headroom")
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(sum(p.stat().st_size for p in block.iterdir()))
        self.run_probe("publication_budget")
        self.assertFalse((block / "publication.json").exists())
        del self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"]
        self.env["SERVICERADAR_NVR_RESERVE_BYTES"] = "1125899906842624"
        self.run_probe("publication_pressure")
        self.assertFalse((block / "publication.json").exists())

        del self.env["SERVICERADAR_NVR_RESERVE_BYTES"]
        self.run_probe("publication_prepare")
        self.acknowledgement_input(block)
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(sum(p.stat().st_size for p in block.iterdir()))
        self.run_probe("publication_ack_budget")
        self.assertFalse((block / "publication-ack.json").exists())
        del self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"]
        self.env["SERVICERADAR_NVR_RESERVE_BYTES"] = "1125899906842624"
        self.run_probe("publication_ack_pressure")
        self.assertFalse((block / "publication-ack.json").exists())

        # The acknowledgement can spend its own reserved slot. Once both
        # immutable records exist, unused headroom is available to capture.
        del self.env["SERVICERADAR_NVR_RESERVE_BYTES"]
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(sum(p.stat().st_size for p in block.iterdir()) + 512)
        self.run_probe("publication_ack_store")
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(capture_budget)
        self.run_probe("publication_headroom_released")

    def record_publication_block(self):
        self.make_media()
        self.run_probe("record")
        block = next(p for p in self.spool.iterdir() if p.is_dir())
        # Existing descriptor export verifies media; Python independently hashes its wire bytes.
        self.run_probe("discover_rotation")
        descriptor_path = Path(self.env["NVR_TEST_MP4"] + ".0.json")
        descriptor = descriptor_path.read_bytes()
        self.env["NVR_TEST_DESCRIPTOR_SHA256"] = hashlib.sha256(descriptor).hexdigest()
        return block

    def acknowledgement_input(self, block):
        # Invented response in the public wire format, supplied independently of
        # the Elixir codec. Core's DB owner checks emission after committed acceptance.
        intent = (block / "publication.json").read_bytes()
        document = {"version": 1, "kind": "intent_accepted",
                    "operation_id": json.loads(intent)["operation_id"],
                    "intent_sha256": hashlib.sha256(intent).hexdigest()}
        raw = json.dumps(document, sort_keys=True, separators=(",", ":")).encode()
        path = self.root / "ack-input.json"
        path.write_bytes(raw)
        self.env["NVR_TEST_ACK"] = str(path)
        self.env["NVR_TEST_BLOCK_ID"] = block.name
        return path, raw

    def test_publication_acknowledgement_survives_restart_and_preserves_unresolved_records(self):
        block = self.record_publication_block()
        self.run_probe("publication_prepare")
        supplied, raw = self.acknowledgement_input(block)
        intent = block / "publication.json"
        original_intent = intent.read_bytes()
        ack = block / "publication-ack.json"

        # A response without its original retained intent cannot become local evidence.
        intent.unlink()
        self.run_probe("publication_ack_error")
        self.assertFalse(ack.exists())
        intent.write_bytes(original_intent)
        intent.chmod(0o600)
        self.run_probe("publication_ack_store")
        self.assertEqual(ack.read_bytes(), raw)
        self.assertEqual(ack.stat().st_mode & 0o777, 0o600)
        before = [(p.stat().st_ino, p.stat().st_mtime_ns) for p in (intent, ack)]
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(sum(p.stat().st_size for p in block.iterdir()))
        self.run_probe("publication_ack_retry")
        self.assertEqual([(p.stat().st_ino, p.stat().st_mtime_ns) for p in (intent, ack)], before)
        self.assertEqual(intent.read_bytes(), original_intent)
        self.assertEqual(ack.read_bytes(), raw)

        document = json.loads(raw)
        wrong = document | {"intent_sha256": "0" * 64}
        for bad in [raw + b" ", b"x" * 513,
                    json.dumps(wrong, sort_keys=True, separators=(",", ":")).encode()]:
            supplied.write_bytes(bad)
            self.run_probe("publication_ack_input_error")
            self.assertEqual(ack.read_bytes(), raw)
        supplied.write_bytes(raw)

        for damaged in [raw[:17], raw + b" ", b"x" * 513]:
            ack.write_bytes(damaged)
            self.run_probe("publication_ack_error")
            self.assertEqual(ack.read_bytes(), damaged)
            self.assertEqual(intent.read_bytes(), original_intent)
        ack.write_bytes(raw)
        alias = self.root / "ack-alias.json"
        os.link(ack, alias)
        self.run_probe("publication_ack_error")
        self.assertEqual(ack.stat().st_ino, alias.stat().st_ino)
        alias.unlink()
        media = block / "media.m4s"
        damaged_media = bytearray(media.read_bytes())
        damaged_media[-1] ^= 1
        media.write_bytes(damaged_media)
        self.run_probe("publication_ack_error")
        self.assertEqual(ack.read_bytes(), raw)
        self.assertEqual(media.read_bytes(), damaged_media)

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
        Path(self.env["NVR_TEST_RECEIPT"]).unlink()
        self.run_probe("discover_rotation")
        for index in range(3):
            path = Path(self.env["NVR_TEST_MP4"] + f".{index}")
            encoded = Path(str(path) + ".json").read_bytes()
            descriptor = json.loads(encoded)
            self.assertEqual(encoded, json.dumps(descriptor, sort_keys=True, separators=(",", ":")).encode())
            self.assertEqual(set(descriptor), {"version", "identity", "format", "init", "media", "fragments"})
            self.assertEqual(descriptor["version"], 1)
            self.assertEqual(descriptor["identity"], {
                "source_id": "synthetic-camera", "profile": "recording", "recorder_epoch": 1,
                "block_sequence": index, "clock": {
                    "clock_epoch": "synthetic-clock", "timebase": 90000,
                    "dts_source": "pts_no_reordering", "utc_mapping": "unknown",
                },
            })
            self.assertEqual(descriptor["format"], {"codec": "avc1.42c00a", "timescale": 30720})
            data = path.read_bytes()
            init_size = descriptor["init"]["length"]
            init, media = data[:init_size], data[init_size:]
            self.assertEqual(descriptor["init"], {"length": len(init), "sha256": hashlib.sha256(init).hexdigest()})
            self.assertEqual(descriptor["media"], {"length": len(media), "sha256": hashlib.sha256(media).hexdigest()})
            offset = 0
            for fragment in descriptor["fragments"]:
                self.assertEqual(fragment["offset"], offset)
                end = offset + fragment["length"]
                self.assertEqual(fragment["sha256"], hashlib.sha256(media[offset:end]).hexdigest())
                offset = end
            self.assertEqual(offset, len(media))
        decoded = [self.decode(self.env["NVR_TEST_MP4"] + f".{i}") for i in range(3)]
        self.assertEqual([len(x) for x in decoded], [n * 64 * 64 * 3 // 2 for n in [240, 240, 30]])
        self.assertEqual(b"".join(decoded), expected)

        # A fresh one-block budget admits capture but cannot fund its successor.
        self.spool = self.root / "limited-spool"
        self.spool.mkdir(mode=0o700)
        self.env["SERVICERADAR_NVR_SPOOL_ROOT"] = str(self.spool)
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(receipt["block_bytes"] + 65536 + 512)
        self.run_probe("rotation_budget")
        self.assertEqual(len(list(self.spool.iterdir())), 2)
        Path(self.env["NVR_TEST_RECEIPT"]).unlink()
        self.run_probe("discover_rotation")
        self.assertEqual(self.decode(self.env["NVR_TEST_MP4"] + ".0"), expected[:240 * 64 * 64 * 3 // 2])

    def test_discovery_preserves_unsealed_corrupt_and_uncommitted_blocks(self):
        self.make_media()
        self.run_probe("record")
        block = next(p for p in self.spool.iterdir() if p.is_dir())
        originals = {p.name: p.read_bytes() for p in block.iterdir()}
        journal = originals["journal"]
        offset = 0
        while offset < len(journal):
            last = offset
            size = int.from_bytes(journal[offset:offset + 4], "big")
            offset += 4 + size + 32
        self.assertEqual(offset, len(journal))
        self.assertEqual(json.loads(journal[last + 4:offset - 32])["type"], "seal")

        cases = [
            ("journal", journal[:last], "unsealed_block"),
            ("journal", journal[:-1] + bytes([journal[-1] ^ 1]), "invalid_journal_record"),
            ("journal", b"x" * 50000, "journal_too_large"),
            ("media.m4s", b"x" + originals["media.m4s"][1:], "media_digest_mismatch"),
            ("media.m4s", originals["media.m4s"] + b"uncommitted", "uncommitted_block_bytes"),
            ("init.mp4", originals["init.mp4"] + b"uncommitted", "uncommitted_block_bytes"),
        ]
        for name, content, error in cases:
            with self.subTest(error=error, file=name):
                for filename, original in originals.items():
                    (block / filename).write_bytes(original)
                (block / name).write_bytes(content)
                before = {p.name: p.read_bytes() for p in block.iterdir()}
                self.env["NVR_TEST_RECOVERY_ERROR"] = error
                self.run_probe("discover_unresolved")
                self.assertEqual({p.name: p.read_bytes() for p in block.iterdir()}, before)

        # A valid journal under a different block ID cannot supply that identity.
        for name, original in originals.items():
            (block / name).write_bytes(original)
        renamed = self.spool / ("f" * 64)
        block.rename(renamed)
        self.env["NVR_TEST_RECOVERY_ERROR"] = "block_identity_mismatch"
        self.run_probe("discover_unresolved")
        self.assertEqual({p.name: p.read_bytes() for p in renamed.iterdir()}, originals)

    def test_discovery_refuses_invalid_format_even_with_valid_journal_hashes(self):
        self.make_media()
        self.run_probe("record")
        block = next(p for p in self.spool.iterdir() if p.is_dir())
        journal = (block / "journal").read_bytes()
        header_size = int.from_bytes(journal[:4], "big")
        header = json.loads(journal[4:4 + header_size])
        init = (block / "init.mp4").read_bytes()
        self.assertEqual(init.count(b"avcC\x01\x42"), 1)
        unsupported = init.replace(b"avcC\x01\x42", b"avcC\x01\x64")
        for content in [init[:-1], unsupported, b"synthetic non-MP4 initialization"]:
            with self.subTest(initialization_bytes=len(content)):
                # Integrity-valid persisted records must still have a supported format.
                header["init"] = {"length": len(content), "sha256": hashlib.sha256(content).hexdigest()}
                encoded = json.dumps(header, separators=(",", ":")).encode()
                (block / "init.mp4").write_bytes(content)
                (block / "journal").write_bytes(len(encoded).to_bytes(4, "big") + encoded +
                                              hashlib.sha256(encoded).digest() + journal[4 + header_size + 32:])
                before = {p.name: p.read_bytes() for p in block.iterdir()}
                self.env["NVR_TEST_RECOVERY_ERROR"] = "invalid_initialization"
                self.run_probe("discover_unresolved")
                self.assertEqual({p.name: p.read_bytes() for p in block.iterdir()}, before)

    def test_interrupted_recording_recovers_only_committed_frames(self):
        source = self.make_media()
        self.run_probe("interrupted")
        self.assertFalse(Path(self.env["NVR_TEST_RECEIPT"]).exists())
        block = next(p for p in self.spool.iterdir() if p.is_dir())
        media = (block / "media.m4s").read_bytes()
        journal = (block / "journal").read_bytes()
        # Represent writes interrupted before a complete journal record committed.
        (block / "media.m4s").write_bytes(media + b"uncommitted synthetic tail")
        (block / "journal").write_bytes(journal + b"\x00\x00")
        self.run_probe("recover_interrupted")
        self.assertEqual((block / "media.m4s").read_bytes(), media)
        sealed = {p.name: p.read_bytes() for p in block.iterdir()}
        self.run_probe("discover_rotation")
        decoded = self.decode(self.env["NVR_TEST_MP4"] + ".0")
        self.assertEqual(len(decoded), 60 * 64 * 64 * 3 // 2)
        self.assertEqual(decoded, self.decode(source)[:len(decoded)])
        self.assertEqual({p.name: p.read_bytes() for p in block.iterdir()}, sealed)

    def test_recovery_preserves_unresolved_blocks_and_pressure(self):
        self.make_media()
        self.run_probe("interrupted")
        block = next(p for p in self.spool.iterdir() if p.is_dir())
        originals = {p.name: p.read_bytes() for p in block.iterdir()}
        journal = originals["journal"]
        header_end = 4 + int.from_bytes(journal[:4], "big") + 32
        cases = [
            ("journal", journal[:-1] + bytes([journal[-1] ^ 1]), "invalid_journal_record"),
            ("media.m4s", b"x" + originals["media.m4s"][1:], "media_digest_mismatch"),
            ("init.mp4", originals["init.mp4"] + b"uncommitted", "uncommitted_block_bytes"),
            ("journal", journal[:header_end], "empty_block"),
        ]
        for name, content, error in cases:
            with self.subTest(error=error):
                for filename, original in originals.items():
                    (block / filename).write_bytes(original)
                (block / name).write_bytes(content)
                before = {p.name: p.read_bytes() for p in block.iterdir()}
                self.env["NVR_TEST_RECOVERY_ERROR"] = error
                self.run_probe("recover_unresolved")
                self.assertEqual({p.name: p.read_bytes() for p in block.iterdir()}, before)

        for name, original in originals.items():
            (block / name).write_bytes(original)
        disk = os.statvfs(self.spool)
        self.env["SERVICERADAR_NVR_RESERVE_BYTES"] = str(disk.f_bavail * disk.f_frsize + 1024**3)
        self.env["NVR_TEST_RECOVERY_ERROR"] = "nvr_storage_pressure"
        self.run_probe("recover_unresolved")
        self.assertEqual({p.name: p.read_bytes() for p in block.iterdir()}, originals)

        del self.env["SERVICERADAR_NVR_RESERVE_BYTES"]
        renamed = self.spool / ("f" * 64)
        block.rename(renamed)
        self.env["NVR_TEST_RECOVERY_ERROR"] = "block_identity_mismatch"
        self.run_probe("recover_unresolved")
        self.assertEqual({p.name: p.read_bytes() for p in renamed.iterdir()}, originals)

    def test_deadline_and_producer_loss_release_admission(self):
        self.env["SERVICERADAR_NVR_MAX_DURATION_MS"] = "500"
        self.run_probe("lifecycle")
        self.assertEqual(sorted(p.name for p in self.spool.iterdir()), [".storage-id"])

    def test_concurrent_reservations_and_accounting_restart(self):
        self.env["SERVICERADAR_NVR_MAX_SESSIONS"] = "3"
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = "20000000"
        self.run_probe("capacity")
        self.assertEqual(sorted(p.name for p in self.spool.iterdir()), [".storage-id"])

    def test_reads_refuse_overload_expire_and_restart_without_stopping_recording(self):
        self.run_probe("read_admission")
        self.assertEqual({p.name for p in self.spool.iterdir()}, {".storage-id"})

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
        (self.spool / f"{4096:064x}").mkdir(mode=0o700)
        self.run_probe("discovery_limit")
        self.assertEqual(len(list(self.spool.iterdir())), 4098)

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
