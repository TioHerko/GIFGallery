import logging
import sys
import threading

from django.apps import AppConfig

logger = logging.getLogger(__name__)

_SKIP_COMMANDS = {
    "migrate",
    "makemigrations",
    "showmigrations",
    "sqlmigrate",
    "squashmigrations",
    "test",
    "collectstatic",
    "createsuperuser",
    "createapitoken",
    "generate_thumbnails",
    "shell",
    "dbshell",
    "check",
    "loaddata",
    "dumpdata",
    "flush",
}


def _backfill_missing_thumbnails():
    from .models import Gif
    from .thumbnails import build_thumbnail

    try:
        gifs = list(Gif.objects.filter(thumbnail="").iterator())
    except Exception:
        logger.exception("Failed to query GIFs for thumbnail backfill")
        return

    if not gifs:
        return

    logger.info("Generating thumbnails for %d GIF(s) in the background", len(gifs))
    for gif in gifs:
        try:
            build_thumbnail(gif)
        except Exception:
            logger.exception("Failed to build thumbnail for gif=%s", gif.id)
    logger.info("Thumbnail backfill complete")


class GalleryConfig(AppConfig):
    name = "gallery"

    def ready(self):
        if any(arg in _SKIP_COMMANDS for arg in sys.argv):
            return
        threading.Thread(
            target=_backfill_missing_thumbnails,
            name="gallery-thumbnail-backfill",
            daemon=True,
        ).start()
