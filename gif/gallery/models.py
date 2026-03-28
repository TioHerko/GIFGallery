import hashlib
import secrets

from nanoid import generate

from django.conf import settings
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


class APIToken(models.Model):
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="api_tokens"
    )
    name = models.CharField(max_length=100)
    token_hash = models.CharField(max_length=64, unique=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.name} ({self.user})"

    @classmethod
    def hash_token(cls, raw_token):
        return hashlib.sha256(raw_token.encode()).hexdigest()

    @classmethod
    def create_token(cls, user, name="default"):
        raw_token = secrets.token_urlsafe(32)
        token = cls.objects.create(
            user=user, name=name, token_hash=cls.hash_token(raw_token)
        )
        return token, raw_token
