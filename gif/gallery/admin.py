from django.contrib import admin

from .models import Gif, Tag


@admin.register(Tag)
class TagAdmin(admin.ModelAdmin):
    list_display = ("name", "slug")
    prepopulated_fields = {"slug": ("name",)}


@admin.register(Gif)
class GifAdmin(admin.ModelAdmin):
    list_display = ("title", "owner", "created_at", "tag_list")
    list_filter = ("tags", "owner")
    search_fields = ("title", "owner__username")
    filter_horizontal = ("tags",)

    def tag_list(self, obj):
        return ", ".join(t.name for t in obj.tags.all())

    tag_list.short_description = "Tags"
