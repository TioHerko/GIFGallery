import logging
from io import BytesIO
from pathlib import Path

from django.conf import settings
from django.core.files.base import ContentFile
from PIL import Image, ImageSequence

logger = logging.getLogger(__name__)

THUMB_MAX_WIDTH = 320


def generate_thumbnail_bytes(src_path, max_width=THUMB_MAX_WIDTH):
    """Return animated-GIF bytes scaled to ``max_width`` (preserving frame
    timing and loop count), or ``None`` if the source is already small enough
    or generation fails."""
    try:
        with Image.open(src_path) as im:
            width, height = im.size
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
    return True
