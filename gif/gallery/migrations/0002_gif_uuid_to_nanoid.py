"""
Migrate Gif.id from UUIDField to CharField with nanoid values.

SQLite doesn't support ALTER COLUMN, so Django will recreate the table.
We use a data migration sandwiched between schema changes:
  1. Add a temporary nanoid field
  2. Populate it with nanoids for existing rows
  3. Drop the old UUID PK, rename nanoid to id
"""

from nanoid import generate

from django.db import migrations, models


def populate_nanoids(apps, schema_editor):
    Gif = apps.get_model("gallery", "Gif")
    for gif in Gif.objects.all():
        gif.nanoid = generate(size=12)
        gif.save(update_fields=["nanoid"])


class Migration(migrations.Migration):

    dependencies = [
        ("gallery", "0001_initial"),
    ]

    operations = [
        # Step 1: Add a temporary nanoid CharField
        migrations.AddField(
            model_name="gif",
            name="nanoid",
            field=models.CharField(max_length=12, null=True),
        ),
        # Step 2: Populate nanoids for existing rows
        migrations.RunPython(populate_nanoids, migrations.RunPython.noop),
        # Step 3: Remove old UUID PK and M2M (Django will recreate the table)
        migrations.RemoveField(
            model_name="gif",
            name="tags",
        ),
        migrations.RemoveField(
            model_name="gif",
            name="id",
        ),
        # Step 4: Rename nanoid to id and make it the PK
        migrations.RenameField(
            model_name="gif",
            old_name="nanoid",
            new_name="id",
        ),
        migrations.AlterField(
            model_name="gif",
            name="id",
            field=models.CharField(
                max_length=12, primary_key=True, serialize=False, editable=False,
            ),
        ),
        # Step 5: Re-add the M2M field with the new PK type
        migrations.AddField(
            model_name="gif",
            name="tags",
            field=models.ManyToManyField(blank=True, related_name="gifs", to="gallery.tag"),
        ),
    ]
