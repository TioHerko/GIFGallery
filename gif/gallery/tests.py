import shutil
import subprocess
import tempfile
import unittest
from datetime import timedelta

from asgiref.sync import async_to_sync
from django.contrib.auth.models import User
from django.core.cache import cache
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import Client, TestCase, override_settings
from django.utils import timezone
from PIL import Image

from .models import APIToken, Gif, Tag
from .video import looks_like_video

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
        self.assertEqual(Gif.objects.first().owner, self.user)

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

    @override_settings(GIF_MAX_PIXELS=0)
    def test_pixel_limit_rejected(self):
        response = self.upload("wide.gif", TINY_GIF)
        self.assertEqual(response.status_code, 400)
        self.assertIn("pixels", response.json()["errors"][0])
        self.assertEqual(Gif.objects.count(), 0)

    @override_settings(GIF_MAX_FRAMES=0)
    def test_frame_limit_rejected(self):
        response = self.upload("animated.gif", TINY_GIF)
        self.assertEqual(response.status_code, 400)
        self.assertIn("frames", response.json()["errors"][0])
        self.assertEqual(Gif.objects.count(), 0)

    def test_unauthenticated_upload_rejected(self):
        self.client.logout()
        response = self.upload("cat.gif", TINY_GIF)
        self.assertEqual(response.status_code, 401)


@override_settings(MEDIA_ROOT=TEMP_MEDIA)
class OwnerBackfillMigrationTests(TestCase):
    """Migration 0007 hands pre-multi-user (ownerless) GIFs to the original
    admin instead of leaving them invisible to every account."""

    def _backfill(self):
        from importlib import import_module

        from django.apps import apps

        migration = import_module(
            "gallery.migrations.0007_assign_orphan_gifs_to_admin"
        )
        migration.assign_orphan_gifs(apps, None)

    def test_orphans_go_to_earliest_superuser(self):
        admin = User.objects.create_user(
            "admin", password="pw", is_superuser=True, is_staff=True
        )
        later_admin = User.objects.create_user(
            "admin2", password="pw", is_superuser=True, is_staff=True
        )
        regular = User.objects.create_user("regular", password="pw")
        orphan = Gif.objects.create(
            title="old", file=SimpleUploadedFile("o.gif", TINY_GIF)
        )
        owned = Gif.objects.create(
            title="mine", owner=regular,
            file=SimpleUploadedFile("m.gif", TINY_GIF),
        )

        self._backfill()

        orphan.refresh_from_db()
        owned.refresh_from_db()
        self.assertEqual(orphan.owner, admin)
        self.assertNotEqual(orphan.owner, later_admin)
        self.assertEqual(owned.owner, regular)

    def test_falls_back_to_earliest_user_without_superuser(self):
        first = User.objects.create_user("first", password="pw")
        User.objects.create_user("second", password="pw")
        orphan = Gif.objects.create(
            title="old", file=SimpleUploadedFile("o.gif", TINY_GIF)
        )

        self._backfill()

        orphan.refresh_from_db()
        self.assertEqual(orphan.owner, first)

    def test_noop_on_empty_user_table(self):
        Gif.objects.create(title="old", file=SimpleUploadedFile("o.gif", TINY_GIF))
        self._backfill()
        self.assertIsNone(Gif.objects.first().owner)


@override_settings(MEDIA_ROOT=TEMP_MEDIA)
class UserIsolationTests(TestCase):
    """Each user should only see and manage their own GIFs."""

    def setUp(self):
        self.alice = User.objects.create_user("alice", password="pw")
        self.bob = User.objects.create_user("bob", password="pw")
        self.alice_gif = Gif.objects.create(
            title="alice", owner=self.alice,
            file=SimpleUploadedFile("a.gif", TINY_GIF),
        )
        self.bob_gif = Gif.objects.create(
            title="bob", owner=self.bob,
            file=SimpleUploadedFile("b.gif", TINY_GIF),
        )

    def test_gallery_only_shows_own_gifs(self):
        client = Client()
        client.force_login(self.alice)
        response = client.get("/")
        self.assertContains(response, "alice")
        self.assertNotContains(response, "bob")

    def test_api_only_shows_own_gifs(self):
        _, token = APIToken.create_token(self.alice)
        client = Client(headers={"Authorization": f"Bearer {token}"})
        response = client.get("/api/gifs/")
        gifs = response.json()["gifs"]
        self.assertEqual(len(gifs), 1)
        self.assertEqual(gifs[0]["title"], "alice")

    def test_cannot_rename_other_users_gif(self):
        client = Client()
        client.force_login(self.alice)
        response = client.post(
            f"/gif/{self.bob_gif.id}/rename/",
            {"title": "stolen"},
            headers={"x-requested-with": "XMLHttpRequest"},
        )
        self.assertEqual(response.status_code, 404)

    def test_cannot_delete_other_users_gif(self):
        client = Client()
        client.force_login(self.alice)
        response = client.post(
            f"/gif/{self.bob_gif.id}/delete/",
            headers={"x-requested-with": "XMLHttpRequest"},
        )
        self.assertEqual(response.status_code, 404)
        self.assertTrue(Gif.objects.filter(id=self.bob_gif.id).exists())

    def test_bearer_token_only_shows_own_gifs(self):
        _, token = APIToken.create_token(self.bob)
        client = Client(headers={"Authorization": f"Bearer {token}"})
        response = client.get("/api/gifs/")
        gifs = response.json()["gifs"]
        self.assertEqual(len(gifs), 1)
        self.assertEqual(gifs[0]["title"], "bob")

    def test_api_filters_by_tag_name(self):
        from .models import Tag
        tag = Tag.objects.create(name="Funny Cats", slug="funny-cats")
        self.alice_gif.tags.add(tag)
        _, token = APIToken.create_token(self.alice)
        client = Client(headers={"Authorization": f"Bearer {token}"})
        # Shortcuts passes tag names, not slugs
        response = client.get("/api/gifs/?tag=Funny Cats")
        self.assertEqual(len(response.json()["gifs"]), 1)
        response = client.get("/api/gifs/?tag=funny-cats")
        self.assertEqual(len(response.json()["gifs"]), 1)

    def test_cannot_tag_other_users_gif(self):
        client = Client()
        client.force_login(self.alice)
        response = client.post(
            f"/gif/{self.bob_gif.id}/tags/",
            {"tags": "hacked"},
            headers={"x-requested-with": "XMLHttpRequest"},
        )
        self.assertEqual(response.status_code, 404)

    def test_tagging_creates_unique_non_empty_slugs(self):
        from .models import Tag

        client = Client()
        client.force_login(self.alice)
        response = client.post(
            f"/gif/{self.alice_gif.id}/tags/",
            {"tags": "!!!, C++, C"},
            headers={"x-requested-with": "XMLHttpRequest"},
        )
        self.assertEqual(response.status_code, 200)
        slugs = [t["slug"] for t in response.json()["tags"]]
        self.assertTrue(all(slugs))
        self.assertEqual(len(slugs), len(set(slugs)))
        self.assertEqual(Tag.objects.count(), 3)


@override_settings(MEDIA_ROOT=TEMP_MEDIA)
class BearerAuthCsrfTests(TestCase):
    """Bearer requests may skip CSRF only on the API endpoints that validate
    the token themselves; session-authenticated HTML views stay protected."""

    def setUp(self):
        self.user = User.objects.create_user("u", password="pw")
        self.token, self.raw_token = APIToken.create_token(self.user)
        self.gif = Gif.objects.create(
            title="t", owner=self.user,
            file=SimpleUploadedFile("t.gif", TINY_GIF),
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

    def test_bearer_header_does_not_exempt_session_views(self):
        # The exemption is scoped to the async API endpoints. A garbage
        # Bearer header must not turn an authenticated session POST to a
        # settings view into a CSRF-exempt request.
        self.csrf_client.force_login(self.user)
        response = self.csrf_client.post(
            "/settings/tokens/create/",
            {"description": "csrf probe"},
            headers={"authorization": "Bearer garbage"},
        )
        self.assertEqual(response.status_code, 403)
        self.assertFalse(APIToken.objects.filter(name="csrf probe").exists())

    def test_expired_token_is_rejected(self):
        APIToken.objects.filter(pk=self.token.pk).update(
            expires_at=timezone.now() - timedelta(seconds=1)
        )
        response = self.rename(
            headers={"authorization": f"Bearer {self.raw_token}"}
        )
        self.assertEqual(response.status_code, 401)
        self.gif.refresh_from_db()
        self.assertEqual(self.gif.title, "t")


class LoginThrottleTests(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user("u", password="pw")

    def login(self, password):
        return self.client.post(
            "/login/", {"username": "u", "password": password}
        )

    @override_settings(
        LOGIN_THROTTLE_USER_ATTEMPTS=2, LOGIN_THROTTLE_IP_ATTEMPTS=100
    )
    def test_repeated_failures_are_throttled(self):
        self.assertEqual(self.login("wrong").status_code, 200)
        self.assertEqual(self.login("wrong").status_code, 200)
        response = self.login("wrong")
        self.assertEqual(response.status_code, 429)
        self.assertIn("Retry-After", response)

    @override_settings(
        LOGIN_THROTTLE_USER_ATTEMPTS=2, LOGIN_THROTTLE_IP_ATTEMPTS=100
    )
    def test_successful_login_clears_failures(self):
        self.login("wrong")
        self.assertEqual(self.login("pw").status_code, 302)
        self.assertEqual(self.login("wrong").status_code, 200)
        self.assertEqual(self.login("wrong").status_code, 200)
        self.assertEqual(self.login("wrong").status_code, 429)


class SecurityHeaderTests(TestCase):
    def test_csp_header_present(self):
        response = self.client.get("/setup/")
        self.assertIn("default-src 'self'", response["Content-Security-Policy"])


@override_settings(MEDIA_ROOT=TEMP_MEDIA)
class ServeGifTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user("u", password="pw")

    def make_gif(self, title):
        return Gif.objects.create(
            title=title, owner=self.user,
            file=SimpleUploadedFile("t.gif", TINY_GIF),
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


class FirstRunSetupTests(TestCase):
    """Setup is first-run only: creates the admin account, then closes permanently."""

    def test_login_redirects_to_setup_when_no_users(self):
        response = self.client.get("/login/")
        self.assertRedirects(response, "/setup/")

    def test_login_renders_normally_once_user_exists(self):
        User.objects.create_user("u", password="pw")
        response = self.client.get("/login/")
        self.assertEqual(response.status_code, 200)

    def test_setup_creates_superuser_and_logs_in(self):
        response = self.client.post(
            "/setup/",
            {
                "username": "admin",
                "password1": "correct-horse-battery",
                "password2": "correct-horse-battery",
            },
        )
        self.assertRedirects(response, "/")
        user = User.objects.get(username="admin")
        self.assertTrue(user.is_superuser)
        self.assertTrue(user.is_staff)
        self.assertTrue(user.check_password("correct-horse-battery"))
        self.assertEqual(self.client.get("/").status_code, 200)

    def test_setup_closed_once_user_exists(self):
        User.objects.create_user("u", password="pw")
        self.assertRedirects(self.client.get("/setup/"), "/login/")
        response = self.client.post(
            "/setup/",
            {
                "username": "intruder",
                "password1": "correct-horse-battery",
                "password2": "correct-horse-battery",
            },
        )
        self.assertRedirects(response, "/login/")
        self.assertFalse(User.objects.filter(username="intruder").exists())

    def test_password_mismatch_rejected(self):
        response = self.client.post(
            "/setup/",
            {
                "username": "admin",
                "password1": "correct-horse-battery",
                "password2": "different-entirely",
            },
        )
        self.assertEqual(response.status_code, 200)
        self.assertFalse(User.objects.exists())

    def test_weak_password_rejected(self):
        response = self.client.post(
            "/setup/",
            {"username": "admin", "password1": "pw", "password2": "pw"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertFalse(User.objects.exists())


class AdminCreateUserTests(TestCase):
    """Only the admin (superuser) can create additional user accounts via
    the settings page."""

    def setUp(self):
        self.admin = User.objects.create_user(
            "admin", password="adminpw", is_superuser=True, is_staff=True
        )
        self.client.force_login(self.admin)

    def test_admin_can_create_user(self):
        response = self.client.post(
            "/settings/users/create/",
            {
                "username": "newuser",
                "password1": "correct-horse-battery",
                "password2": "correct-horse-battery",
            },
        )
        self.assertRedirects(response, "/settings/")
        user = User.objects.get(username="newuser")
        self.assertFalse(user.is_superuser)
        self.assertFalse(user.is_staff)

    def test_regular_user_cannot_create_user(self):
        regular = User.objects.create_user("regular", password="pw")
        self.client.force_login(regular)
        response = self.client.post(
            "/settings/users/create/",
            {
                "username": "intruder",
                "password1": "correct-horse-battery",
                "password2": "correct-horse-battery",
            },
        )
        self.assertRedirects(response, "/settings/")
        self.assertFalse(User.objects.filter(username="intruder").exists())

    def test_settings_page_shows_users_section_to_admin(self):
        User.objects.create_user("regular", password="pw")
        response = self.client.get("/settings/")
        self.assertContains(response, "Users")
        self.assertContains(response, "admin")
        self.assertContains(response, "regular")

    def test_settings_page_hides_users_section_from_regular(self):
        regular = User.objects.create_user("regular", password="pw")
        self.client.force_login(regular)
        response = self.client.get("/settings/")
        self.assertNotContains(response, "Users")


class SettingsPageTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user("u", password="old-horse-battery")
        self.client.force_login(self.user)

    def test_requires_login(self):
        response = Client().get("/settings/")
        self.assertEqual(response.status_code, 302)
        self.assertTrue(response["Location"].startswith("/login/"))

    def test_settings_page_renders(self):
        APIToken.create_token(self.user, name="my laptop")
        response = self.client.get("/settings/")
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "my laptop")

    def test_change_password_revokes_api_tokens(self):
        _, raw = APIToken.create_token(self.user, name="phone")
        response = self.client.post(
            "/settings/password/",
            {
                "old_password": "old-horse-battery",
                "new_password1": "new-horse-battery",
                "new_password2": "new-horse-battery",
            },
        )
        self.assertRedirects(response, "/settings/")
        self.assertFalse(APIToken.objects.filter(user=self.user).exists())
        api = Client(headers={"Authorization": f"Bearer {raw}"})
        self.assertEqual(api.get("/api/gifs/").status_code, 401)

    def test_change_password(self):
        response = self.client.post(
            "/settings/password/",
            {
                "old_password": "old-horse-battery",
                "new_password1": "new-horse-battery",
                "new_password2": "new-horse-battery",
            },
        )
        self.assertRedirects(response, "/settings/")
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password("new-horse-battery"))
        # update_session_auth_hash keeps the current session logged in.
        self.assertEqual(self.client.get("/settings/").status_code, 200)

    def test_change_password_wrong_old_password(self):
        response = self.client.post(
            "/settings/password/",
            {
                "old_password": "wrong",
                "new_password1": "new-horse-battery",
                "new_password2": "new-horse-battery",
            },
        )
        self.assertEqual(response.status_code, 200)  # re-rendered with errors
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password("old-horse-battery"))

    def test_create_token_shows_raw_token_once(self):
        response = self.client.post(
            "/settings/tokens/create/",
            {"description": "phone"},
            follow=True,
        )
        token = APIToken.objects.get(user=self.user, name="phone")
        raw = response.context["new_token"]["token"]
        self.assertEqual(APIToken.hash_token(raw), token.token_hash)
        self.assertContains(response, raw)
        # A second visit no longer shows the raw token anywhere.
        response = self.client.get("/settings/")
        self.assertNotContains(response, raw)

    def test_created_token_authenticates(self):
        response = self.client.post(
            "/settings/tokens/create/", {"description": "phone"}, follow=True
        )
        raw = response.context["new_token"]["token"]
        api = Client(headers={"Authorization": f"Bearer {raw}"})
        self.assertEqual(api.get("/api/gifs/").status_code, 200)

    def test_create_token_requires_description(self):
        response = self.client.post(
            "/settings/tokens/create/", {"description": "   "}
        )
        self.assertRedirects(response, "/settings/")
        self.assertFalse(APIToken.objects.exists())

    def test_delete_token(self):
        token, raw = APIToken.create_token(self.user, name="old phone")
        response = self.client.post(f"/settings/tokens/{token.id}/delete/")
        self.assertRedirects(response, "/settings/")
        self.assertFalse(APIToken.objects.filter(id=token.id).exists())
        api = Client(headers={"Authorization": f"Bearer {raw}"})
        self.assertEqual(api.get("/api/gifs/").status_code, 401)

    def test_cannot_delete_other_users_token(self):
        other = User.objects.create_user("other", password="pw")
        token, _ = APIToken.create_token(other, name="not yours")
        response = self.client.post(f"/settings/tokens/{token.id}/delete/")
        self.assertEqual(response.status_code, 404)
        self.assertTrue(APIToken.objects.filter(id=token.id).exists())


class FaviconTests(TestCase):
    def test_root_favicon_redirects_to_static(self):
        response = self.client.get("/favicon.ico")
        self.assertEqual(response.status_code, 302)
        self.assertEqual(response["Location"], "/static/gallery/favicon.ico")

    def test_pages_link_favicon(self):
        User.objects.create_user("u", password="pw")
        response = self.client.get("/login/")
        self.assertContains(response, "/static/gallery/favicon-32.png")


_HAVE_FFMPEG = bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))


def _make_video(seconds, size="64x64", rate=10):
    """Render a tiny test video with ffmpeg and return its bytes."""
    tmp = tempfile.mkdtemp(prefix="gif-test-video-")
    path = f"{tmp}/clip.mp4"
    subprocess.run(
        [
            "ffmpeg", "-nostdin", "-y", "-loglevel", "error",
            "-f", "lavfi",
            "-i", f"testsrc=duration={seconds}:size={size}:rate={rate}",
            "-pix_fmt", "yuv420p",
            path,
        ],
        check=True,
        capture_output=True,
    )
    with open(path, "rb") as f:
        data = f.read()
    shutil.rmtree(tmp, ignore_errors=True)
    return data


class APIConfigTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user("c", password="pw")

    def test_requires_auth(self):
        self.assertEqual(self.client.get("/api/config/").status_code, 401)

    @override_settings(VIDEO_MAX_DURATION_SECONDS=10, VIDEO_MAX_WIDTH=640)
    def test_reports_limits(self):
        token, raw = APIToken.create_token(self.user, name="t")
        response = self.client.get(
            "/api/config/", headers={"authorization": f"Bearer {raw}"}
        )
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["video_max_duration_seconds"], 10)
        self.assertEqual(body["video_max_width"], 640)
        self.assertIn("mp4", body["video_extensions"])
        self.assertTrue(all("." not in ext for ext in body["video_extensions"]))
        self.assertGreater(body["max_upload_bytes"], 0)


class VideoSniffTests(TestCase):
    def test_mp4_header_detected(self):
        self.assertTrue(looks_like_video(b"\x00\x00\x00\x18ftypmp42"))

    def test_mkv_header_detected(self):
        self.assertTrue(looks_like_video(b"\x1a\x45\xdf\xa3\x01\x00\x00\x00"))

    def test_gif_is_not_video(self):
        self.assertFalse(looks_like_video(TINY_GIF[:12]))


@override_settings(MEDIA_ROOT=TEMP_MEDIA)
class VideoUploadTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user("v", password="pw")
        self.client.force_login(self.user)

    def upload(self, name, content):
        return self.client.post(
            "/upload/",
            {"files": SimpleUploadedFile(name, content)},
            headers={"x-requested-with": "XMLHttpRequest"},
        )

    def test_upload_page_communicates_limit(self):
        response = self.client.get("/upload/")
        self.assertContains(response, "up to 10 seconds")

    def test_non_media_rejected_with_clear_message(self):
        response = self.upload("notes.txt", b"just some text, definitely not media")
        self.assertEqual(response.status_code, 400)
        self.assertIn(
            "not a GIF or supported video", response.json()["errors"][0]
        )
        self.assertEqual(Gif.objects.count(), 0)

    @unittest.skipUnless(_HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
    def test_short_video_converted_to_gif(self):
        response = self.upload("clip.mp4", _make_video(seconds=1))
        self.assertEqual(response.status_code, 200, response.content)
        self.assertEqual(Gif.objects.count(), 1)
        gif = Gif.objects.get()
        # The stored file is a real GIF produced by ffmpeg, not the movie.
        self.assertTrue(gif.file.name.endswith(".gif"))
        with gif.file.open("rb") as f:
            self.assertIn(f.read(6), (b"GIF87a", b"GIF89a"))

    @unittest.skipUnless(_HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
    @override_settings(VIDEO_MAX_DURATION_SECONDS=2)
    def test_video_over_limit_rejected(self):
        response = self.upload("long.mp4", _make_video(seconds=4, size="32x32", rate=4))
        self.assertEqual(response.status_code, 400)
        self.assertIn("the limit is 2 seconds", response.json()["errors"][0])
        self.assertEqual(Gif.objects.count(), 0)

    @unittest.skipUnless(_HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
    def test_small_dimensions_and_frames_preserved(self):
        response = self.upload("clip.mp4", _make_video(seconds=1, size="48x64", rate=10))
        self.assertEqual(response.status_code, 200, response.content)
        gif = Gif.objects.get()
        with Image.open(gif.file.path) as im:
            # Under the width cap, so dimensions are untouched.
            self.assertEqual(im.size, (48, 64))
            self.assertGreater(getattr(im, "n_frames", 1), 1)

    @unittest.skipUnless(_HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
    @override_settings(VIDEO_MAX_WIDTH=640)
    def test_wide_video_downscaled_to_max_width(self):
        # 1280x720 source → capped to 640 wide, aspect ratio preserved (360h).
        response = self.upload(
            "big.mp4", _make_video(seconds=1, size="1280x720", rate=8)
        )
        self.assertEqual(response.status_code, 200, response.content)
        gif = Gif.objects.get()
        with Image.open(gif.file.path) as im:
            self.assertEqual(im.width, 640)
            self.assertEqual(im.height, 360)

@override_settings(MEDIA_ROOT=TEMP_MEDIA)
class GallerySortTests(TestCase):
    """Sort strategies on the gallery page, and the counts that go with them."""

    def setUp(self):
        self.user = User.objects.create_user("sorter", password="pw")
        self.client.force_login(self.user)
        # Mixed case on purpose: SQLite orders binary, so a naive title sort
        # would put "Banana" ahead of "apple".
        self.make_gif("apple", days_ago=3, copies=5)
        self.make_gif("Banana", days_ago=2, copies=0)
        self.make_gif("cherry", days_ago=1, copies=2)

    def make_gif(self, title, days_ago, copies):
        gif = Gif.objects.create(
            title=title,
            owner=self.user,
            copy_count=copies,
            file=SimpleUploadedFile(f"{title}.gif", TINY_GIF),
        )
        # created_at is auto_now_add, so it can only be set after the fact.
        Gif.objects.filter(pk=gif.pk).update(
            created_at=timezone.now() - timedelta(days=days_ago)
        )
        return gif

    def titles(self, query=""):
        response = self.client.get(f"/{query}")
        self.assertEqual(response.status_code, 200)
        return [gif.title for gif in response.context["gifs"]]

    def test_default_sort_is_newest_first(self):
        self.assertEqual(self.titles(), ["cherry", "Banana", "apple"])

    def test_model_default_ordering_is_newest_first(self):
        self.assertEqual(
            list(Gif.objects.values_list("title", flat=True)),
            ["cherry", "Banana", "apple"],
        )

    def test_sort_oldest_first(self):
        self.assertEqual(self.titles("?sort=oldest"), ["apple", "Banana", "cherry"])

    def test_alphabetical_sort_ignores_case(self):
        self.assertEqual(self.titles("?sort=az"), ["apple", "Banana", "cherry"])

    def test_reverse_alphabetical_sort_ignores_case(self):
        self.assertEqual(self.titles("?sort=za"), ["cherry", "Banana", "apple"])

    def test_sort_by_most_used(self):
        self.assertEqual(self.titles("?sort=most_used"), ["apple", "cherry", "Banana"])

    def test_sort_by_least_used(self):
        self.assertEqual(self.titles("?sort=least_used"), ["Banana", "cherry", "apple"])

    def test_equally_used_gifs_are_ordered_newest_first(self):
        self.make_gif("durian", days_ago=0, copies=5)
        self.assertEqual(
            self.titles("?sort=most_used")[:2], ["durian", "apple"]
        )

    def test_unknown_sort_falls_back_to_newest(self):
        self.assertEqual(self.titles("?sort=bogus"), ["cherry", "Banana", "apple"])

    def test_sort_choice_persists_across_requests(self):
        self.titles("?sort=az")
        self.assertEqual(self.titles(), ["apple", "Banana", "cherry"])

    def test_unknown_sort_does_not_replace_remembered_choice(self):
        self.titles("?sort=az")
        self.assertEqual(self.titles("?sort=bogus"), ["apple", "Banana", "cherry"])

    def test_sort_survives_tag_filtering(self):
        tag = Tag.objects.create(name="Fruit", slug="fruit")
        for gif in Gif.objects.all():
            gif.tags.add(tag)
        self.titles("?sort=az")
        self.assertEqual(self.titles("?tag=fruit"), ["apple", "Banana", "cherry"])

    def test_sort_applies_to_search_results(self):
        # Searching joins tags and de-duplicates, and "apple" matches through
        # two tags at once — so this is where ordering by Lower("title") has
        # to survive .distinct().
        apple = Gif.objects.get(title="apple")
        for name in ("Apricot", "Avocado"):
            apple.tags.add(Tag.objects.create(name=name, slug=name.lower()))
        # "cherry" has no "a", so only two GIFs match.
        self.assertEqual(self.titles("?q=a&sort=az"), ["apple", "Banana"])

    def test_usage_counts_shown_when_sorting_by_most_used(self):
        response = self.client.get("/?sort=most_used")
        self.assertContains(response, "usage-count")

    def test_usage_counts_shown_when_sorting_by_least_used(self):
        response = self.client.get("/?sort=least_used")
        # Zero is exactly what "least used" is ranking, so it must be shown.
        self.assertContains(response, 'data-usage-count="0"')

    def test_usage_counts_hidden_for_other_sorts(self):
        for sort in ("newest", "oldest", "az", "za"):
            with self.subTest(sort=sort):
                response = self.client.get(f"/?sort={sort}")
                self.assertNotContains(response, "usage-count")

    def test_sort_control_offers_every_strategy(self):
        response = self.client.get("/")
        for value in ("newest", "oldest", "az", "za", "most_used", "least_used"):
            with self.subTest(value=value):
                self.assertContains(response, f'value="{value}"')
