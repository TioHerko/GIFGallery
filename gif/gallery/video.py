"""Transcode short uploaded videos (mp4/mov/mkv) into GIFs with ffmpeg.

The uploaded movie never lands in MEDIA_ROOT: it is written to a private temp
directory, probed for duration, transcoded (keeping the source framerate,
downscaled to at most ``VIDEO_MAX_WIDTH`` px wide), and the whole directory
(movie included) is removed as soon as the GIF bytes are in hand. The stored
file is therefore always a real GIF we produced ourselves.
"""

import logging
import subprocess
import tempfile
from pathlib import Path

from django.conf import settings

logger = logging.getLogger(__name__)

# QuickTime/ISO-BMFF top-level atom names (mp4, mov) live at bytes 4..8; EBML
# (mkv, webm) files start with a fixed 4-byte signature.
_QUICKTIME_ATOMS = (b"ftyp", b"moov", b"mdat", b"free", b"skip", b"wide", b"pnot")
_EBML_MAGIC = b"\x1a\x45\xdf\xa3"

VIDEO_EXTENSIONS = (".mp4", ".mov", ".mkv", ".m4v", ".webm")


class VideoConversionError(Exception):
    """A video could not be converted (unreadable, too long, or ffmpeg failed).

    The message is safe to show to the uploading user.
    """


def looks_like_video(header):
    """Best-effort sniff of the leading bytes of an upload."""
    if len(header) >= 8 and header[4:8] in _QUICKTIME_ATOMS:
        return True
    if header[:4] == _EBML_MAGIC:
        return True
    return False


def _probe_duration(path):
    """Return the video duration in seconds, or ``None`` if it can't be read."""
    cmd = [
        "ffprobe",
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        str(path),
    ]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            timeout=settings.FFMPEG_TIMEOUT_SECONDS,
            check=True,
        )
    except (subprocess.SubprocessError, OSError):
        logger.warning("ffprobe failed for %s", path, exc_info=True)
        return None
    try:
        return float(result.stdout.decode().strip())
    except ValueError:
        return None


def _convert(video_path, gif_path):
    """Run the single-pass palette transcode, preserving fps and downscaling
    to at most ``VIDEO_MAX_WIDTH`` px wide (aspect ratio preserved, never
    upscaled)."""
    max_width = settings.VIDEO_MAX_WIDTH
    # Cap width at max_width without ever enlarging a narrower clip; -2 keeps
    # the aspect ratio and rounds height to an even number. split → palettegen
    # → paletteuse in one graph keeps the source framerate while giving the
    # clip its own 256-color palette instead of the poor default GIF palette.
    scale = f"scale='min({max_width},iw)':-2:flags=lanczos"
    cmd = [
        "ffmpeg",
        "-nostdin",
        "-y",
        "-i", str(video_path),
        "-filter_complex",
        f"[0:v] {scale},split [a][b];[a] palettegen [p];[b][p] paletteuse",
        "-loglevel", "error",
        str(gif_path),
    ]
    try:
        subprocess.run(
            cmd,
            capture_output=True,
            timeout=settings.FFMPEG_TIMEOUT_SECONDS,
            check=True,
        )
    except subprocess.TimeoutExpired:
        raise VideoConversionError("conversion timed out")
    except subprocess.CalledProcessError as exc:
        logger.warning(
            "ffmpeg failed for %s: %s",
            video_path,
            exc.stderr.decode(errors="replace") if exc.stderr else "",
        )
        raise VideoConversionError("could not convert video to GIF")
    except OSError:
        # ffmpeg not installed / not on PATH.
        logger.exception("ffmpeg could not be invoked")
        raise VideoConversionError("video conversion is unavailable")


def convert_upload_to_gif(uploaded_file):
    """Transcode ``uploaded_file`` (a Django UploadedFile) to GIF bytes.

    Blocking; call from a worker thread. Raises :class:`VideoConversionError`
    if the clip is unreadable, longer than ``VIDEO_MAX_DURATION_SECONDS``, or
    ffmpeg fails/times out. The temporary movie is always deleted before this
    returns.
    """
    suffix = Path(uploaded_file.name).suffix.lower()
    if suffix not in VIDEO_EXTENSIONS:
        suffix = ".mp4"

    with tempfile.TemporaryDirectory(prefix="gif-video-") as tmp:
        video_path = Path(tmp) / f"source{suffix}"
        with open(video_path, "wb") as out:
            for chunk in uploaded_file.chunks():
                out.write(chunk)

        duration = _probe_duration(video_path)
        if duration is None:
            raise VideoConversionError("could not read the video")
        limit = settings.VIDEO_MAX_DURATION_SECONDS
        if duration > limit:
            raise VideoConversionError(
                f"video is {duration:.1f}s long; the limit is {limit} seconds"
            )

        gif_path = Path(tmp) / "out.gif"
        _convert(video_path, gif_path)
        return gif_path.read_bytes()
