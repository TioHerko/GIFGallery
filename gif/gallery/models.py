from nanoid import generate

from django.db import models

NANOID_LENGTH = 12


def generate_nanoid():
    return generate(size=NANOID_LENGTH)


class Tag(models.Model):
    name = models.CharField(max_length=100, unique=True)
    slug = models.SlugField(max_length=100, unique=True)

    class Meta:
        ordering = ["name"]

    def __str__(self):
        return self.name


class Gif(models.Model):
    id = models.CharField(
        primary_key=True, max_length=12, default=generate_nanoid, editable=False
    )
    title = models.CharField(max_length=200)
    file = models.FileField(upload_to="gifs/")
    tags = models.ManyToManyField(Tag, blank=True, related_name="gifs")
    copy_count = models.PositiveIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-copy_count", "-created_at"]

    def __str__(self):
        return self.title
