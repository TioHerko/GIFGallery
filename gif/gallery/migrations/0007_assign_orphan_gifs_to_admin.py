# 0006 added Gif.owner as nullable but left existing rows NULL, which makes
# every pre-multi-user GIF invisible (all views filter by owner). Backfill
# them to the original admin: the earliest superuser, falling back to the
# earliest user on databases where the first account predates the superuser
# flag. No-ops on an empty user table (fresh installs have no GIFs anyway).

from django.conf import settings
from django.db import migrations


def assign_orphan_gifs(apps, schema_editor):
    Gif = apps.get_model("gallery", "Gif")
    User = apps.get_model(*settings.AUTH_USER_MODEL.split("."))
    owner = (
        User.objects.filter(is_superuser=True).order_by("date_joined", "pk").first()
        or User.objects.order_by("date_joined", "pk").first()
    )
    if owner:
        Gif.objects.filter(owner__isnull=True).update(owner=owner)


class Migration(migrations.Migration):

    dependencies = [
        ("gallery", "0006_add_gif_owner"),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        # Reverse is a no-op: un-assigning owners would re-orphan the rows.
        migrations.RunPython(assign_orphan_gifs, migrations.RunPython.noop),
    ]
