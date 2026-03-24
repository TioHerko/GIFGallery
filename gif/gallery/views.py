from django.contrib.auth.decorators import login_required
from django.db import models
from django.http import FileResponse, Http404, JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.utils.text import slugify

from .models import Gif, Tag


@login_required
def gallery_view(request):
    tag_slug = request.GET.get("tag")
    query = request.GET.get("q", "").strip()
    gifs = Gif.objects.prefetch_related("tags").all()
    active_tag = None

    if tag_slug:
        active_tag = get_object_or_404(Tag, slug=tag_slug)
        gifs = gifs.filter(tags=active_tag)

    if query:
        gifs = gifs.filter(
            models.Q(title__icontains=query) | models.Q(tags__name__icontains=query)
        ).distinct()

    tags = Tag.objects.all()
    return render(
        request,
        "gallery/gallery.html",
        {
            "gifs": gifs,
            "tags": tags,
            "active_tag": active_tag,
            "query": query,
        },
    )


def serve_gif(request, gif_id):
    gif = get_object_or_404(Gif, id=gif_id)
    try:
        response = FileResponse(gif.file.open("rb"), content_type="image/gif")
    except FileNotFoundError:
        raise Http404("GIF file not found")
    response["Cache-Control"] = "public, max-age=31536000, immutable"
    response["Content-Disposition"] = f'inline; filename="{gif.title}.gif"'
    return response


@login_required
def tag_gif_view(request, gif_id):
    if request.method != "POST":
        return JsonResponse({"error": "POST required"}, status=405)
    gif = get_object_or_404(Gif, id=gif_id)
    tag_names = request.POST.get("tags", "")
    tags = []
    for name in tag_names.split(","):
        name = name.strip()
        if name:
            tag, _ = Tag.objects.get_or_create(
                slug=slugify(name),
                defaults={"name": name},
            )
            tags.append(tag)
    gif.tags.set(tags)
    return JsonResponse({
        "tags": [{"name": t.name, "slug": t.slug} for t in gif.tags.all()]
    })


@login_required
def upload_view(request):
    if request.method == "POST":
        files = request.FILES.getlist("files")
        tag_names = request.POST.get("tags", "")
        title_prefix = request.POST.get("title_prefix", "").strip()

        # Parse and create tags
        tags = []
        for name in tag_names.split(","):
            name = name.strip()
            if name:
                tag, _ = Tag.objects.get_or_create(
                    slug=slugify(name),
                    defaults={"name": name},
                )
                tags.append(tag)

        created = []
        for f in files:
            title = f"{title_prefix} {f.name}" if title_prefix else f.name
            # Strip file extension from title
            if "." in title:
                title = title.rsplit(".", 1)[0]
            gif = Gif.objects.create(title=title, file=f)
            gif.tags.set(tags)
            created.append(str(gif.id))

        if request.headers.get("X-Requested-With") == "XMLHttpRequest":
            return JsonResponse({"created": created})
        return redirect("gallery:gallery")

    tags = Tag.objects.all()
    return render(request, "gallery/upload.html", {"tags": tags})
