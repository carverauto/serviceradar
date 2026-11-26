"""Fail-closed synthetic H.264/MP4/CMAF/JPEG media generator for Mode B tests."""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any

from integration_tests.vantage_ml import vantage_contracts
from integration_tests.vantage_ml.drivers import env_probe


def _run_ffmpeg(args: list[str], *, timeout: float = 60.0) -> subprocess.CompletedProcess[str]:
    ffmpeg_bin = env_probe.probe_binary("ffmpeg")
    proc = subprocess.run(
        [str(ffmpeg_bin), "-hide_banner", "-loglevel", "error", "-y", *args],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"ffmpeg exited with code {proc.returncode}: {proc.stderr.strip()}"
        )
    return proc


def _require_pil_and_numpy() -> tuple[Any, Any]:
    try:
        import numpy as np  # type: ignore[import-not-found]
        from PIL import Image, ImageDraw  # type: ignore[import-not-found]
    except ImportError as exc:
        raise RuntimeError(
            f"Mode B PIL/numpy media synthesis prerequisites missing: {exc}"
        ) from exc
    return np, (Image, ImageDraw)


def generate_synthetic_plate_png(
    output_path: Path | str,
    *,
    plate_text: str = "SR-0100",
    camera_label: str = "Gate West 01",
    width: int = 1280,
    height: int = 720,
) -> Path:
    """Render a synthetic high-resolution PNG frame with PIL/numpy (fails closed if missing)."""
    if plate_text not in vantage_contracts.SYNTHETIC_PLATES:
        vantage_contracts.assert_synthetic_hygiene(plate_text)
    np, (Image, ImageDraw) = _require_pil_and_numpy()
    out = Path(output_path)
    out.parent.mkdir(parents=True, exist_ok=True)

    arr = np.zeros((height, width, 3), dtype=np.uint8)
    arr[:, :, 0] = 36
    arr[:, :, 1] = 44
    arr[:, :, 2] = 58
    img = Image.fromarray(arr, mode="RGB")
    draw = ImageDraw.Draw(img)
    # Vehicle silhouette + high-contrast synthetic plate box
    draw.rectangle([width // 4, height // 3, (width * 3) // 4, (height * 5) // 6], fill=(90, 105, 128))
    draw.rectangle([width // 2 - 120, height // 2 + 40, width // 2 + 120, height // 2 + 110], fill=(242, 244, 238))
    draw.text((24, 24), camera_label, fill=(240, 240, 240))
    draw.text((width // 2 - 70, height // 2 + 65), plate_text, fill=(20, 24, 36))
    img.save(out, format="PNG")
    return out


def generate_synthetic_h264_mp4(
    output_name: str = "synthetic_gate_west_01.mp4",
    *,
    width: int = 1280,
    height: int = 720,
    duration_s: int = 2,
    fps: int = 15,
    scratch_subdir: str = "media",
) -> Path:
    """Generate a synthetic H.264 MP4 clip under scratch dir using ffmpeg."""
    media_dir = env_probe.get_scratch_dir(scratch_subdir)
    out_path = media_dir / output_name
    _run_ffmpeg(
        [
            "-f",
            "lavfi",
            "-i",
            f"testsrc2=size={width}x{height}:rate={fps}:duration={duration_s}",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-g",
            str(fps),
            "-keyint_min",
            str(fps),
            "-movflags",
            "+faststart",
            str(out_path),
        ]
    )
    if not out_path.is_file() or out_path.stat().st_size == 0:
        raise RuntimeError(f"ffmpeg produced empty MP4 output at {out_path}")
    return out_path


def generate_synthetic_cmaf_block(
    prefix: str = "synthetic_block",
    *,
    width: int = 1280,
    height: int = 720,
    duration_s: int = 2,
    fps: int = 15,
    scratch_subdir: str = "media",
) -> tuple[Path, Path]:
    """Generate a synthetic fMP4/CMAF init (`init.mp4`) and media segment (`media.m4s`)."""
    media_dir = env_probe.get_scratch_dir(scratch_subdir) / prefix
    media_dir.mkdir(parents=True, exist_ok=True)
    mp4_path = generate_synthetic_h264_mp4(
        f"{prefix}_source.mp4",
        width=width,
        height=height,
        duration_s=duration_s,
        fps=fps,
        scratch_subdir=scratch_subdir,
    )
    init_name = "init.mp4"
    seg_pattern = str(media_dir / "chunk_%03d.m4s")
    manifest_path = media_dir / "stream.mpd"
    _run_ffmpeg(
        [
            "-i",
            str(mp4_path),
            "-c:v",
            "copy",
            "-f",
            "dash",
            "-init_seg_name",
            init_name,
            "-media_seg_name",
            "chunk_$Number%03d$.m4s",
            "-seg_duration",
            str(duration_s),
            str(manifest_path),
        ]
    )
    init_path = media_dir / init_name
    seg_candidates = sorted(media_dir.glob("chunk_*.m4s"))
    if not init_path.is_file() or not seg_candidates:
        raise RuntimeError(
            f"CMAF generation did not produce {init_path} and chunk_*.m4s (pattern={seg_pattern})"
        )
    media_path = media_dir / "media.m4s"
    media_path.write_bytes(b"".join(p.read_bytes() for p in seg_candidates))
    return init_path, media_path


def generate_synthetic_jpeg_file(
    output_name: str = "synthetic_crop.jpg",
    *,
    width: int = 320,
    height: int = 180,
    seed: int = 1,
    target_max_bytes: int = vantage_contracts.MAX_PERSISTED_CROP_BYTES,
    scratch_subdir: str = "media",
) -> Path:
    """Write a deterministic Baseline JFIF crop under scratch dir."""
    media_dir = env_probe.get_scratch_dir(scratch_subdir)
    out_path = media_dir / output_name
    jpeg = vantage_contracts.make_synthetic_baseline_jfif(
        width,
        height,
        seed=seed,
        target_max_bytes=target_max_bytes,
    )
    vantage_contracts.validate_baseline_jfif(jpeg, max_bytes=target_max_bytes)
    out_path.write_bytes(jpeg)
    return out_path
