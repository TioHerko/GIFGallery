from django.contrib import admin

from .models import Gif, Tag


@admin.register(Tag)
class TagAdmin(admin.ModelAdmin):
    list_display = ("name", "slug")
    prepopulated_fields = {"slug": ("name",)}


@admin.register(Gif)
class GifAdmin(admin.ModelAdmin):
    list_display = ("title", "created_at", "tag_list")
    list_filter = ("tags",)
    search_fields = ("title",)
    filter_horizontal = ("tags",)

    def tag_list(self, obj):
        return ", ".join(t.name for t in obj.tags.all())

    tag_list.short_description = "Tags"
