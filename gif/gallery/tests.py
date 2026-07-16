import tempfile

from asgiref.sync import async_to_sync
from django.contrib.auth.models import User
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import Client, TestCase, override_settings

from .models import APIToken, Gif

# Smallest valid GIF: 1x1 transparent pixel.
TINY_GIF = (
    b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff"
    b"!\xf9\x04\x00\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00"
    b"\x02\x02D\x01\x00;"
)

TEMP_MEDIA = tempfile.mkdtemp(prefix="gif-test-media-")


def _wide_animated_gif_bytes(width=400, height=300, frames=3):
    """An animated GIF wide enough to trigger thumbnail generation."""
    from io import BytesIO

    from PIL import Image

    images = [Image.new("P", (width, height), color=i * 60) for i in range(frames)]
    out = BytesIO()
    images[0].save(
        out,
        format="GIF",
        save_all=True,
        append_images=images[1:],
        duration=80,
        loop=0,
    )
    return out.getvalue()


@override_settings(MEDIA_ROOT=TEMP_MEDIA)
class UploadValidationTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user("u", password="pw")
        self.client.force_login(self.user)

    def upload(self, name, content):
        return self.client.post(
            "/upload/",
            {"files": SimpleUploadedFile(name, content)},
            headers={"x-requested-with": "XMLHttpRequest"},
        )

    def test_valid_gif_accepted(self):
        response = self.upload("cat.gif", TINY_GIF)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(Gif.objects.count(), 1)

    def test_wide_gif_upload_creates_thumbnail(self):
        # Wider than THUMB_MAX_WIDTH, so the upload also generates and saves
        # a thumbnail. Regression test: the thumbnail save used to run on a
        # thread_sensitive=False worker, writing through a second SQLite
        # connection and dying with "database table is locked".
        response = self.upload("wide.gif", _wide_animated_gif_bytes())
        self.assertEqual(response.status_code, 200)
        gif = Gif.objects.get()
        self.assertTrue(gif.thumbnail.name, "thumbnail was not attached")

    def test_non_gif_rejected(self):
        response = self.upload("evil.html", b"<script>alert(1)</script>")
        self.assertEqual(response.status_code, 400)
        self.assertIn("not a GIF", response.json()["errors"][0])
        self.assertEqual(Gif.objects.count(), 0)

    def test_gif_extension_with_html_content_rejected(self):
        response = self.upload("fake.gif", b"<html><script>alert(1)</script>")
        self.assertEqual(response.status_code, 400)
        self.assertEqual(Gif.objects.count(), 0)

    @override_settings(GIF_MAX_UPLOAD_BYTES=10)
    def test_oversized_file_rejected(self):
        response = self.upload("big.gif", TINY_GIF)
        self.assertEqual(response.status_code, 400)
        self.assertIn("larger than", response.json()["errors"][0])
        self.assertEqual(Gif.objects.count(), 0)

    def test_unauthenticated_upload_rejected(self):
        self.client.logout()
        response = self.upload("cat.gif", TINY_GIF)
        self.assertEqual(response.status_code, 401)


@override_settings(MEDIA_ROOT=TEMP_MEDIA)
class BearerAuthCsrfTests(TestCase):
    """The CSRF exemption for bearer requests must apply only when the
    token actually validates — an invalid token must never lift CSRF for a
    request that falls through to session authentication."""

    def setUp(self):
        self.user = User.objects.create_user("u", password="pw")
        _, self.raw_token = APIToken.create_token(self.user)
        self.gif = Gif.objects.create(
            title="t", file=SimpleUploadedFile("t.gif", TINY_GIF)
        )
        self.csrf_client = Client(enforce_csrf_checks=True)

    def rename(self, **extra):
        return self.csrf_client.post(
            f"/gif/{self.gif.id}/rename/", {"title": "new"}, **extra
        )

    def test_valid_token_is_csrf_exempt(self):
        response = self.rename(
            headers={"authorization": f"Bearer {self.raw_token}"}
        )
        self.assertEqual(response.status_code, 200)

    def test_invalid_token_without_session_is_401(self):
        response = self.rename(headers={"authorization": "Bearer garbage"})
        self.assertEqual(response.status_code, 401)

    def test_invalid_token_does_not_fall_back_to_session(self):
        # A bearer request is CSRF-exempt, so it must never authenticate via
        # the session cookie — otherwise "Bearer garbage" + a logged-in
        # session would be a CSRF bypass.
        self.csrf_client.force_login(self.user)
        response = self.rename(headers={"authorization": "Bearer garbage"})
        self.assertEqual(response.status_code, 401)
        self.gif.refresh_from_db()
        self.assertEqual(self.gif.title, "t")

    def test_session_without_csrf_token_is_rejected(self):
        self.csrf_client.force_login(self.user)
        response = self.rename()
        self.assertEqual(response.status_code, 403)


@override_settings(MEDIA_ROOT=TEMP_MEDIA)
class ServeGifTests(TestCase):
    def make_gif(self, title):
        return Gif.objects.create(
            title=title, file=SimpleUploadedFile("t.gif", TINY_GIF)
        )

    def get(self, gif):
        response = self.client.get(f"/gif/{gif.id}.gif")
        # Consume the (async) streaming body so the file handle is closed.
        async def drain():
            return b"".join([chunk async for chunk in response.streaming_content])
        async_to_sync(drain)()
        return response

    def test_serves_gif_publicly(self):
        response = self.get(self.make_gif("plain"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response["Content-Type"], "image/gif")

    def test_emoji_title_does_not_break_header(self):
        response = self.get(self.make_gif("party 🎉"))
        self.assertEqual(response.status_code, 200)
        self.assertIn("filename*", response["Content-Disposition"])

    def test_quoted_title_is_escaped(self):
        response = self.get(self.make_gif('a"b'))
        self.assertEqual(response.status_code, 200)
        self.assertIn('\\"', response["Content-Disposition"])
