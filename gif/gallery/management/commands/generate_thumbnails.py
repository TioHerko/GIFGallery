from django.core.management.base import BaseCommand

from gallery.models import Gif
from gallery.thumbnails import build_thumbnail


class Command(BaseCommand):
    help = "Generate animated GIF thumbnails for any Gif missing one."

    def add_arguments(self, parser):
        parser.add_argument(
            "--all",
            action="store_true",
            help="Regenerate thumbnails even if one already exists.",
        )

    def handle(self, *args, **options):
        regenerate = options["all"]
        qs = Gif.objects.all()
        if not regenerate:
            qs = qs.filter(thumbnail="")

        total = qs.count()
        if total == 0:
            self.stdout.write("No GIFs need thumbnails.")
            return

        self.stdout.write(f"Generating thumbnails for {total} GIF(s)...")
        made = 0
        skipped = 0
        for gif in qs.iterator():
            if regenerate and gif.thumbnail:
                gif.thumbnail.delete(save=True)
            if build_thumbnail(gif):
                made += 1
            else:
                skipped += 1
        self.stdout.write(
            self.style.SUCCESS(f"Done. Created {made}, skipped {skipped}.")
        )
