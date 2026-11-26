"""Mode A hermetic tests for crop-box geometry and Baseline Sequential JFIF media."""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

if __package__ in (None, "") and "TEST_SRCDIR" not in os.environ:
    _repo_root = str(Path(__file__).resolve().parents[2])
    if _repo_root not in sys.path:
        sys.path.insert(0, _repo_root)

from integration_tests.vantage_ml import vantage_contracts as vc


class CropBoxGeometryTest(unittest.TestCase):
    """Verify `compute_padded_crop_box` parity with `frame.rs` and `thumbnail.rs`."""

    def test_min_bbox_width_px_96_accepts_and_95_skips(self) -> None:
        accepted = vc.compute_padded_crop_box(
            frame_w=1920,
            frame_h=1080,
            bbox=[0.0, 0.25, 96.0 / 1920.0, 0.50],
            padding_ratio=0.15,
            min_bbox_width_px=96,
            max_dimension=640,
        )
        self.assertEqual(accepted["status"], "ok")
        self.assertIsNone(accepted["reason"])
        self.assertAlmostEqual(accepted["raw_width_px"], 96.0, places=6)
        self.assertGreaterEqual(accepted["crop_w"], 96)
        self.assertLessEqual(accepted["out_w"], 640)
        self.assertLessEqual(accepted["out_h"], 640)

        skipped = vc.compute_padded_crop_box(
            frame_w=1920,
            frame_h=1080,
            bbox=[0.0, 0.25, 95.0 / 1920.0, 0.50],
            padding_ratio=0.15,
            min_bbox_width_px=96,
            max_dimension=640,
        )
        self.assertEqual(skipped["status"], "skipped")
        self.assertEqual(skipped["reason"], "crop_below_min_dimension")
        self.assertAlmostEqual(skipped["raw_width_px"], 95.0, places=6)

    def test_min_bbox_width_px_rounds_ieee754_matching_crop_rs(self) -> None:
        # (0.35 - 0.30) * 1920 == 95.99999999999997 in IEEE-754 float64; Rust crop.rs rounds to 96
        accepted = vc.compute_padded_crop_box(
            frame_w=1920,
            frame_h=1080,
            bbox=[0.30, 0.0, 0.35, 0.2],
            padding_ratio=0.15,
            min_bbox_width_px=96,
            max_dimension=640,
        )
        self.assertEqual(accepted["status"], "ok")
        self.assertIsNone(accepted["reason"])
        self.assertLess(accepted["raw_width_px"], 96.0)

        for px_width in (95.4, 95.0):
            with self.subTest(px_width=px_width):
                skipped = vc.compute_padded_crop_box(
                    frame_w=1920,
                    frame_h=1080,
                    bbox=[0.0, 0.0, px_width / 1920.0, 0.2],
                    padding_ratio=0.15,
                    min_bbox_width_px=96,
                    max_dimension=640,
                )
                self.assertEqual(skipped["status"], "skipped")
                self.assertEqual(skipped["reason"], "crop_below_min_dimension")
                self.assertEqual(skipped["rounded_width_px"], 95)

    def test_padding_clamps_to_frame_bounds_and_downscales_to_640(self) -> None:
        # Touching top-left corner clamps px1=0, py1=0
        corner = vc.compute_padded_crop_box(
            frame_w=1000,
            frame_h=800,
            bbox=[0.0, 0.0, 0.2, 0.2],
            padding_ratio=0.15,
            min_bbox_width_px=96,
            max_dimension=640,
        )
        self.assertEqual(corner["status"], "ok")
        self.assertEqual(corner["px1"], 0)
        self.assertEqual(corner["py1"], 0)
        self.assertEqual(corner["crop_w"], 230)
        self.assertEqual(corner["crop_h"], 184)
        self.assertEqual(corner["out_w"], 230)
        self.assertEqual(corner["out_h"], 184)

        # Wide crop (> 640px) downscales preserving aspect ratio
        wide = vc.compute_padded_crop_box(
            frame_w=1920,
            frame_h=1080,
            bbox=[0.1, 0.2, 0.9, 0.6],
            padding_ratio=0.0,
            min_bbox_width_px=96,
            max_dimension=640,
        )
        self.assertEqual(wide["crop_w"], 1536)
        self.assertEqual(wide["crop_h"], 432)
        self.assertEqual(wide["out_w"], 640)
        self.assertEqual(wide["out_h"], 180)

    def test_invalid_bbox_or_dimensions_raise_contract_error(self) -> None:
        with self.assertRaises(vc.ContractValidationError):
            vc.compute_padded_crop_box(0, 1080, [0.1, 0.1, 0.5, 0.5])
        with self.assertRaises(vc.ContractValidationError):
            vc.compute_padded_crop_box(1920, 1080, [0.5, 0.1, 0.5, 0.5])
        with self.assertRaises(vc.ContractValidationError):
            vc.compute_padded_crop_box(1920, 1080, [0.1, 0.1, 0.5, 0.5], padding_ratio=-0.1)


class BaselineJfifMediaTest(unittest.TestCase):
    """Verify deterministic Baseline Sequential JFIF generation and strict marker validation."""

    def test_deterministic_generation_and_marker_structure(self) -> None:
        jpeg_a = vc.make_synthetic_baseline_jfif(
            160, 120, seed=42, target_max_bytes=vc.MAX_PERSISTED_CROP_BYTES
        )
        jpeg_b = vc.make_synthetic_baseline_jfif(
            160, 120, seed=42, target_max_bytes=vc.MAX_PERSISTED_CROP_BYTES
        )
        jpeg_other = vc.make_synthetic_baseline_jfif(
            160, 120, seed=99, target_max_bytes=vc.MAX_PERSISTED_CROP_BYTES
        )
        self.assertEqual(jpeg_a, jpeg_b)
        self.assertNotEqual(jpeg_a, jpeg_other)

        info = vc.validate_baseline_jfif(jpeg_a, max_bytes=vc.MAX_PERSISTED_CROP_BYTES)
        self.assertEqual(info["width"], 160)
        self.assertEqual(info["height"], 120)
        self.assertGreaterEqual(info["dqt_count"], 2)
        self.assertGreaterEqual(info["dht_count"], 4)
        self.assertLessEqual(info["byte_length"], vc.MAX_PERSISTED_CROP_BYTES)
        self.assertTrue(jpeg_a.startswith(b"\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01"))
        self.assertTrue(jpeg_a.endswith(b"\xFF\xD9"))

    def test_size_cap_stepdown_and_downscale_for_persisted_and_vlm_limits(self) -> None:
        vlm_crop = vc.make_synthetic_baseline_jfif(
            640, 480, seed=3, target_max_bytes=vc.MAX_VLM_CROP_BYTES
        )
        vlm_info = vc.validate_baseline_jfif(vlm_crop, max_bytes=vc.MAX_VLM_CROP_BYTES)
        self.assertLessEqual(vlm_info["byte_length"], vc.MAX_VLM_CROP_BYTES)

        # Force iterative quality step-down + 3:4 downscale under tight 6 KiB cap
        tight_crop = vc.make_synthetic_baseline_jfif(
            640, 480, seed=5, target_max_bytes=6144, quality=90, min_quality=35
        )
        tight_info = vc.validate_baseline_jfif(tight_crop, max_bytes=6144)
        self.assertLessEqual(tight_info["byte_length"], 6144)
        self.assertLess(tight_info["width"], 640)

        with self.assertRaises(vc.ContractValidationError):
            vc.make_synthetic_baseline_jfif(64, 64, target_max_bytes=511)

    def test_validate_baseline_jfif_rejects_corrupted_markers_and_unstuffed_entropy(self) -> None:
        valid = vc.make_synthetic_baseline_jfif(64, 48, seed=11, target_max_bytes=8192)
        vc.validate_baseline_jfif(valid, max_bytes=8192)

        # 1. Exceeds max_bytes
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_baseline_jfif(valid, max_bytes=len(valid) - 1)

        # 2. Missing SOI / EOI
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_baseline_jfif(b"\x00\xD8" + valid[2:])
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_baseline_jfif(valid[:-2] + b"\xFF\x00")

        # 3. Progressive SOF2 (0xC2) instead of Baseline SOF0 (0xC0)
        sof0_idx = valid.index(b"\xFF\xC0\x00\x11\x08")
        sof2 = bytearray(valid)
        sof2[sof0_idx + 1] = 0xC2
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_baseline_jfif(bytes(sof2))

        # 4. Missing APP0 JFIF header (replace with APP1)
        app1 = bytearray(valid)
        app1[3] = 0xE1
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_baseline_jfif(bytes(app1))

        # 5. Unstuffed 0xFF 0xAA inside entropy scan before EOI
        sos_idx = valid.index(b"\xFF\xDA\x00\x0C")
        unstuffed = valid[: sos_idx + 16] + b"\xFF\xAA" + valid[sos_idx + 16 :]
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_baseline_jfif(unstuffed)

        # 6. Zero dimensions in SOF0
        zero_dim = bytearray(valid)
        zero_dim[sof0_idx + 5 : sof0_idx + 7] = b"\x00\x00"
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_baseline_jfif(bytes(zero_dim))


if __name__ == "__main__":
    unittest.main()
