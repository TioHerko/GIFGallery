import logging
from io import BytesIO
from pathlib import Path

from django.conf import settings
from django.core.files.base import ContentFile
from PIL import Image, ImageSequence
from pygifsicle import optimize

logger = logging.getLogger(__name__)

THUMB_MAX_WIDTH = 320


def gif_limit_error(fileobj):
    """Return a user-facing error if a GIF exceeds the decoded size limits.

    ``fileobj`` is rewound to the start before returning, so the upload can
    still be stored when this passes. The byte-size cap alone does not stop a
    small file from declaring a huge canvas or thousands of frames.
    """
    try:
        with Image.open(fileobj) as im:
            width, height = im.size
            frames = getattr(im, "n_frames", 1)
    except Exception:
        return "not a readable GIF"
    finally:
        try:
            fileobj.seek(0)
        except (AttributeError, OSError):
            pass

    if width * height > settings.GIF_MAX_PIXELS:
        return (
            f"image is {width}x{height} pixels; "
            f"the limit is {settings.GIF_MAX_PIXELS} pixels"
        )
    if frames > settings.GIF_MAX_FRAMES:
        return (
            f"image has {frames} frames; "
            f"the limit is {settings.GIF_MAX_FRAMES} frames"
        )
    return None


def generate_thumbnail_bytes(src_path, max_width=THUMB_MAX_WIDTH):
    """Return animated-GIF bytes scaled to ``max_width`` (preserving frame
    timing and loop count), or ``None`` if the source is already small enough
    or generation fails."""
    try:
        with Image.open(src_path) as im:
            width, height = im.size
            if width * height > settings.GIF_MAX_PIXELS:
                logger.warning(
                    "Skipping thumbnail for oversized GIF %s (%dx%d)",
                    src_path, width, height,
                )
                return None
            if getattr(im, "n_frames", 1) > settings.GIF_MAX_FRAMES:
                logger.warning(
                    "Skipping thumbnail for GIF %s with too many frames",
                    src_path,
                )
                return None
            if width <= max_width:
                return None

            scale = max_width / width
            new_size = (max_width, max(1, round(height * scale)))

            # Halve the frame rate: keep every other frame and roll the
            # dropped frame's duration into the previous kept frame so
            # total runtime is preserved.
            frames = []
            durations = []
            for index, frame in enumerate(ImageSequence.Iterator(im)):
                duration = frame.info.get("duration", 100)
                if index % 2 == 1:
                    if durations:
                        durations[-1] += duration
                    continue
                composited = frame.convert("RGBA").resize(new_size, Image.LANCZOS)
                # Quantize to a 256-color palette so the encoder can write
                # frame deltas — saves a lot vs. saving RGBA frames.
                frames.append(composited.quantize(colors=256))
                durations.append(duration)

            loop = im.info.get("loop", 0)
    except Exception:
        logger.exception("Failed to read source GIF %s", src_path)
        return None

    if not frames:
        return None

    try:
        out = BytesIO()
        frames[0].save(
            out,
            format="GIF",
            save_all=True,
            append_images=frames[1:],
            duration=durations,
            loop=loop,
            optimize=True,
        )
        return out.getvalue()
    except Exception:
        logger.exception("Failed to encode thumbnail for %s", src_path)
        return None


def thumbnail_filename(gif):
    """Stable thumbnail filename derived from the GIF id."""
    return f"{gif.id}.gif"


def optimize_in_place(path):
    """Best-effort gifsicle pass: don't fail if gifsicle is missing (dev
    machines) or chokes on the file."""
    try:
        optimize(path)
    except Exception:
        logger.warning("gifsicle failed for %s", path, exc_info=True)


def build_thumbnail(gif, save=True):
    """Generate and attach a thumbnail file to ``gif``. Returns True if a
    thumbnail was created (or already existed and is still valid), False if
    skipped (e.g. source already small or generation failed)."""
    if gif.thumbnail and gif.thumbnail.name:
        thumb_path = Path(settings.MEDIA_ROOT) / gif.thumbnail.name
        if thumb_path.exists():
            return True

    if not gif.file or not gif.file.name:
        return False

    src_path = gif.file.path
    data = generate_thumbnail_bytes(src_path)
    if data is None:
        return False

    gif.thumbnail.save(thumbnail_filename(gif), ContentFile(data), save=save)
    optimize_in_place(gif.thumbnail.path)
    return True
