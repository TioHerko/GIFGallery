from asgiref.sync import sync_to_async
from django.conf import settings
from django.contrib import messages
from django.contrib.auth import (
    get_user_model,
    login as auth_login,
    update_session_auth_hash,
)
from django.contrib.auth.decorators import login_required
from django.contrib.auth.forms import PasswordChangeForm, UserCreationForm
from django.contrib.auth.views import LoginView
from django.db import models, transaction
from django.shortcuts import get_object_or_404
from django.views.decorators.http import require_POST
from django.db.models import F
from django.db.models.functions import Lower
import aiofiles
from django.http import Http404, JsonResponse, StreamingHttpResponse
from django.shortcuts import aget_object_or_404, redirect, render
from django.urls import reverse
from django.utils.http import content_disposition_header
from django.utils.text import slugify

from django.core.files.base import ContentFile

from .auth import auth_required
from .models import APIToken, Gif, Tag
from .thumbnails import (
    generate_thumbnail_bytes,
    gif_limit_error,
    optimize_in_place,
    thumbnail_filename,
)
from .video import (
    VIDEO_EXTENSIONS,
    VideoConversionError,
    convert_upload_to_gif,
    looks_like_video,
)

GIF_MAGIC = (b"GIF87a", b"GIF89a")
GIF_TITLE_MAX = Gif._meta.get_field("title").max_length
TAG_NAME_MAX = Tag._meta.get_field("name").max_length
TAG_SLUG_MAX = Tag._meta.get_field("slug").max_length

# Gallery sort strategies: ``?sort=`` value -> (label, order_by arguments).
# Titles sort through Lower() because SQLite compares text binary, which would
# file every capitalised title ahead of every lowercase one. The frequency
# sorts need the created_at tiebreak — most GIFs share a copy_count of 0.
# These keys double as the Swift clients' SortOrder raw values.
GALLERY_SORTS = {
    "newest": ("Newest first", ["-created_at"]),
    "oldest": ("Oldest first", ["created_at"]),
    "az": ("Title A\u2013Z", [Lower("title").asc(), "-created_at"]),
    "za": ("Title Z\u2013A", [Lower("title").desc(), "-created_at"]),
    "most_used": ("Most used", ["-copy_count", "-created_at"]),
    "least_used": ("Least used", ["copy_count", "-created_at"]),
}
DEFAULT_SORT = "newest"
# Sorts that rank by usage, and so have to show the counts they rank on.
USAGE_COUNT_SORTS = frozenset({"most_used", "least_used"})
SESSION_SORT_KEY = "gallery_sort"


def _classify_upload(f):
    """Classify an uploaded file.

    Returns ``(kind, error)`` where ``kind`` is ``"gif"`` or ``"video"`` and
    ``error`` is ``None``, or ``(None, message)`` if the file is neither an
    acceptable GIF nor a supported video container.
    """
    if f.size > settings.GIF_MAX_UPLOAD_BYTES:
        max_mb = settings.GIF_MAX_UPLOAD_BYTES // (1024 * 1024)
        return None, f"{f.name}: larger than {max_mb} MB"
    header = f.read(12)
    f.seek(0)
    if header[:6] in GIF_MAGIC:
        limit_error = gif_limit_error(f)
        if limit_error:
            return None, f"{f.name}: {limit_error}"
        return "gif", None
    if looks_like_video(header):
        return "video", None
    return None, f"{f.name}: not a GIF or supported video (mp4, mov, mkv)"


class FirstRunLoginView(LoginView):
    """LoginView that hands off to /setup/ until an account exists."""

    template_name = "gallery/login.html"

    def dispatch(self, request, *args, **kwargs):
        if not get_user_model().objects.exists():
            return redirect("setup")
        return super().dispatch(request, *args, **kwargs)


def setup_view(request):
    """First-run page: create the admin account, then log in.

    Only reachable while the user table is empty; afterwards it permanently
    redirects to the login page. The first user is always the admin.
    """
    User = get_user_model()
    if User.objects.exists():
        return redirect("login")

    form = UserCreationForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        with transaction.atomic():
            if User.objects.exists():
                return redirect("login")
            user = form.save(commit=False)
            user.is_staff = True
            user.is_superuser = True
            user.save()
        auth_login(request, user)
        return redirect("gallery:gallery")

    return render(request, "gallery/setup.html", {"form": form})


TOKEN_DESCRIPTION_MAX = APIToken._meta.get_field("name").max_length


async def _get_or_create_tag(name):
    """Resolve a tag by name, creating a unique, non-empty slug if needed."""
    name = name.strip()[:TAG_NAME_MAX]
    if not name:
        return None

    existing = await Tag.objects.filter(name=name).afirst()
    if existing is not None:
        return existing

    base = slugify(name)[:TAG_SLUG_MAX] or "tag"
    slug = base
    suffix = 2
    while await Tag.objects.filter(slug=slug).aexists():
        suffix_text = f"-{suffix}"
        slug = f"{base[: TAG_SLUG_MAX - len(suffix_text)]}{suffix_text}"
        suffix += 1
    tag, _ = await Tag.objects.aget_or_create(slug=slug, defaults={"name": name})
    return tag


def _render_settings(
    request, password_form=None, create_user_form=None, new_token=None
):
    return render(
        request,
        "gallery/settings.html",
        {
            "password_form": password_form or PasswordChangeForm(request.user),
            "tokens": request.user.api_tokens.order_by("-created_at"),
            "new_token": new_token,
            "create_user_form": create_user_form or UserCreationForm(),
            "is_admin": request.user.is_superuser,
            "users": get_user_model().objects.order_by("-date_joined"),
        },
    )


@login_required
def settings_view(request):
    return _render_settings(request)


@login_required
@require_POST
def change_password_view(request):
    form = PasswordChangeForm(request.user, request.POST)
    if form.is_valid():
        user = form.save()
        # Rotating the password should also invalidate long-lived API tokens.
        if user.api_tokens.exists():
            user.api_tokens.all().delete()
            messages.info(request, "All API tokens were revoked.")
        # Password changes rotate the session auth hash; without this the
        # current session would be logged out immediately.
        update_session_auth_hash(request, user)
        messages.success(request, "Password changed.")
        return redirect("gallery:settings")
    return _render_settings(request, password_form=form)


@login_required
@require_POST
def create_token_view(request):
    description = request.POST.get("description", "").strip()
    if not description:
        messages.error(request, "A description is required.")
        return redirect("gallery:settings")
    if len(description) > TOKEN_DESCRIPTION_MAX:
        messages.error(
            request,
            f"Description must be at most {TOKEN_DESCRIPTION_MAX} characters.",
        )
        return redirect("gallery:settings")
    _, raw_token = APIToken.create_token(request.user, name=description)
    # Render the raw token in this response instead of stashing it in the
    # session (which would persist it server-side until the page was loaded).
    return _render_settings(
        request,
        new_token={"token": raw_token, "description": description},
    )


@login_required
@require_POST
def create_user_view(request):
    if not request.user.is_superuser:
        messages.error(request, "Only the admin can create accounts.")
        return redirect("gallery:settings")

    form = UserCreationForm(request.POST)
    if form.is_valid():
        user = form.save()
        messages.success(request, f"User “{user.username}” created.")
        return redirect("gallery:settings")
    return _render_settings(request, create_user_form=form)


@login_required
@require_POST
def delete_token_view(request, token_id):
    token = get_object_or_404(APIToken, id=token_id, user=request.user)
    token.delete()
    messages.success(request, f"Token “{token.name}” deleted.")
    return redirect("gallery:settings")


async def _resolve_sort(request):
    """The sort to apply: an explicit ``?sort=`` wins and is remembered for
    later visits; otherwise fall back to the remembered one, then the default.
    Unrecognised values are ignored rather than raising."""
    requested = request.GET.get("sort")
    if requested in GALLERY_SORTS:
        # Session access in an async view has to go through the async API —
        # the sync one hits the DB on the event loop.
        if await request.session.aget(SESSION_SORT_KEY) != requested:
            await request.session.aset(SESSION_SORT_KEY, requested)
        return requested
    remembered = await request.session.aget(SESSION_SORT_KEY)
    return remembered if remembered in GALLERY_SORTS else DEFAULT_SORT


@login_required
async def gallery_view(request):
    user = await request.auser()
    tag_slug = request.GET.get("tag")
    query = request.GET.get("q", "").strip()
    sort = await _resolve_sort(request)
    gifs = Gif.objects.prefetch_related("tags").filter(owner=user)
    active_tag = None

    if tag_slug:
        active_tag = await aget_object_or_404(Tag, slug=tag_slug)
        gifs = gifs.filter(tags=active_tag)

    if query:
        gifs = gifs.filter(
            models.Q(title__icontains=query) | models.Q(tags__name__icontains=query)
        ).distinct()

    gifs = [gif async for gif in gifs.order_by(*GALLERY_SORTS[sort][1])]
    tags = [tag async for tag in Tag.objects.all()]
    return render(
        request,
        "gallery/gallery.html",
        {
            "gifs": gifs,
            "tags": tags,
            "active_tag": active_tag,
            "query": query,
            "sort": sort,
            "sort_options": [
                (value, label) for value, (label, _) in GALLERY_SORTS.items()
            ],
            "show_counts": sort in USAGE_COUNT_SORTS,
        },
    )


async def serve_gif(request, gif_id):
    gif = await aget_object_or_404(Gif, id=gif_id)

    async def stream_file():
        try:
            async with aiofiles.open(gif.file.path, "rb") as f:
                while chunk := await f.read(8192):
                    yield chunk
        except FileNotFoundError:
            raise Http404("GIF file not found")

    response = StreamingHttpResponse(stream_file(), content_type="image/gif")
    response["Cache-Control"] = "public, max-age=31536000, immutable"
    # content_disposition_header handles quoting and non-latin-1 titles
    # (RFC 5987) — raw interpolation breaks the header on quotes and 500s
    # on e.g. emoji.
    response["Content-Disposition"] = content_disposition_header(
        as_attachment=False, filename=f"{gif.title}.gif"
    )
    return response


async def serve_thumbnail(request, gif_id):
    gif = await aget_object_or_404(Gif, id=gif_id)
    if not gif.thumbnail or not gif.thumbnail.name:
        return redirect("gallery:serve_gif", gif_id=gif.id)

    path = gif.thumbnail.path

    async def stream_file():
        try:
            async with aiofiles.open(path, "rb") as f:
                while chunk := await f.read(8192):
                    yield chunk
        except FileNotFoundError:
            raise Http404("Thumbnail file not found")

    response = StreamingHttpResponse(stream_file(), content_type="image/gif")
    response["Cache-Control"] = "public, max-age=31536000, immutable"
    return response


async def embed_gif(request, gif_id):
    gif = await aget_object_or_404(Gif, id=gif_id)
    gif_url = request.build_absolute_uri(
        reverse("gallery:serve_gif", args=[gif.id])
    )
    embed_url = request.build_absolute_uri(
        reverse("gallery:embed_gif", args=[gif.id])
    )
    return render(
        request,
        "gallery/embed.html",
        {"gif": gif, "gif_url": gif_url, "embed_url": embed_url},
    )


@auth_required
async def tag_gif_view(request, gif_id):
    if request.method != "POST":
        return JsonResponse({"error": "POST required"}, status=405)
    gif = await aget_object_or_404(Gif, id=gif_id, owner=request.user)
    tag_names = request.POST.get("tags", "")
    tags = []
    for name in tag_names.split(","):
        tag = await _get_or_create_tag(name)
        if tag is not None:
            tags.append(tag)
    await gif.tags.aset(tags)
    return JsonResponse({
        "tags": [{"name": t.name, "slug": t.slug} async for t in gif.tags.all()]
    })


@auth_required
async def rename_gif_view(request, gif_id):
    if request.method != "POST":
        return JsonResponse({"error": "POST required"}, status=405)
    gif = await aget_object_or_404(Gif, id=gif_id, owner=request.user)
    title = request.POST.get("title", "").strip()[:GIF_TITLE_MAX]
    if not title:
        return JsonResponse({"error": "Title is required"}, status=400)
    gif.title = title
    await gif.asave(update_fields=["title"])
    return JsonResponse({"title": gif.title})


@auth_required
async def delete_gif_view(request, gif_id):
    if request.method != "POST":
        return JsonResponse({"error": "POST required"}, status=405)
    gif = await aget_object_or_404(Gif, id=gif_id, owner=request.user)
    gif.file.delete(save=False)
    if gif.thumbnail:
        gif.thumbnail.delete(save=False)
    await gif.adelete()
    return JsonResponse({"deleted": True})


@auth_required
async def copy_gif_view(request, gif_id):
    if request.method != "POST":
        return JsonResponse({"error": "POST required"}, status=405)
    gif = await aget_object_or_404(Gif, id=gif_id, owner=request.user)
    gif.copy_count = F("copy_count") + 1
    await gif.asave(update_fields=["copy_count"])
    await gif.arefresh_from_db(fields=["copy_count"])
    return JsonResponse({"copy_count": gif.copy_count})


@auth_required
async def upload_view(request):
    if request.method == "POST":
        files = request.FILES.getlist("files")
        tag_names = request.POST.get("tags", "")
        title_prefix = request.POST.get("title_prefix", "").strip()

        # Classify (and, for videos, transcode) every file before creating any
        # Gif, so the batch stays all-or-nothing. Uploads are stored under
        # their original extension, so accepting arbitrary content (e.g.
        # HTML/SVG) would plant scriptable files on this origin; videos are
        # never stored — only the GIF ffmpeg produces from them is.
        prepared = []  # (title, source_file) where source_file is a GIF
        errors = []
        for f in files:
            kind, error = _classify_upload(f)
            if error:
                errors.append(error)
                continue
            title = f"{title_prefix} {f.name}" if title_prefix else f.name
            # Strip file extension from title
            if "." in title:
                title = title.rsplit(".", 1)[0]
            title = title[:GIF_TITLE_MAX]
            if kind == "video":
                try:
                    gif_bytes = await sync_to_async(
                        convert_upload_to_gif, thread_sensitive=False
                    )(f)
                except VideoConversionError as exc:
                    errors.append(f"{f.name}: {exc}")
                    continue
                prepared.append((title, ContentFile(gif_bytes, name=f"{title}.gif")))
            else:
                prepared.append((title, f))

        if errors:
            return JsonResponse({"errors": errors}, status=400)

        # Parse and create tags
        tags = []
        for name in tag_names.split(","):
            tag = await _get_or_create_tag(name)
            if tag is not None:
                tags.append(tag)

        created = []
        for title, source in prepared:
            gif = await Gif.objects.acreate(
                title=title, file=source, owner=request.user
            )
            await gif.tags.aset(tags)
            await sync_to_async(optimize_in_place, thread_sensitive=False)(
                gif.file.path
            )
            # Pillow work runs on a free thread, but the DB write must go
            # through the request's connection (thread_sensitive default):
            # writing from another thread means a second SQLite connection,
            # which races the request and the startup backfill thread and
            # fails with "database is locked".
            data = await sync_to_async(generate_thumbnail_bytes, thread_sensitive=False)(
                gif.file.path
            )
            if data is not None:
                await sync_to_async(gif.thumbnail.save)(
                    thumbnail_filename(gif), ContentFile(data)
                )
                await sync_to_async(optimize_in_place, thread_sensitive=False)(
                    gif.thumbnail.path
                )
            created.append(str(gif.id))

        if request.headers.get("X-Requested-With") == "XMLHttpRequest":
            return JsonResponse({"created": created})
        return redirect("gallery:gallery")

    tags = [tag async for tag in Tag.objects.all()]
    return render(
        request,
        "gallery/upload.html",
        {"tags": tags, "max_video_seconds": settings.VIDEO_MAX_DURATION_SECONDS},
    )


@auth_required
async def api_config(request):
    """Upload limits, so clients can validate (e.g. video duration) before
    sending a large request. Values come straight from settings."""
    return JsonResponse({
        "video_max_duration_seconds": settings.VIDEO_MAX_DURATION_SECONDS,
        "video_max_width": settings.VIDEO_MAX_WIDTH,
        "max_upload_bytes": settings.GIF_MAX_UPLOAD_BYTES,
        "gif_max_pixels": settings.GIF_MAX_PIXELS,
        "gif_max_frames": settings.GIF_MAX_FRAMES,
        "video_extensions": [ext.lstrip(".") for ext in VIDEO_EXTENSIONS],
    })


@auth_required
async def api_list_gifs(request):
    tag_slug = request.GET.get("tag")
    query = request.GET.get("q", "").strip()
    gifs = Gif.objects.prefetch_related("tags").filter(owner=request.user)

    if tag_slug:
        gifs = gifs.filter(
            models.Q(tags__slug=tag_slug) | models.Q(tags__name__iexact=tag_slug)
        )

    if query:
        gifs = gifs.filter(
            models.Q(title__icontains=query) | models.Q(tags__name__icontains=query)
        ).distinct()

    results = []
    async for gif in gifs:
        results.append({
            "id": gif.id,
            "title": gif.title,
            "url": request.build_absolute_uri(
                reverse("gallery:serve_gif", args=[gif.id])
            ),
            "thumbnail_url": request.build_absolute_uri(
                reverse("gallery:serve_thumbnail", args=[gif.id])
            ),
            "embed_url": request.build_absolute_uri(
                reverse("gallery:embed_gif", args=[gif.id])
            ),
            "tags": [{"name": t.name, "slug": t.slug} async for t in gif.tags.all()],
            "copy_count": gif.copy_count,
            "created_at": gif.created_at.isoformat(),
        })

    return JsonResponse({"gifs": results})
