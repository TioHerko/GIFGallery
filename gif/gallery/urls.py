from django.urls import path

from . import views

app_name = "gallery"

urlpatterns = [
    path("", views.gallery_view, name="gallery"),
    path("gif/<str:gif_id>/", views.embed_gif, name="embed_gif"),
    path("gif/<str:gif_id>.gif", views.serve_gif, name="serve_gif"),
    path("gif/<str:gif_id>/tags/", views.tag_gif_view, name="tag_gif"),
    path("gif/<str:gif_id>/rename/", views.rename_gif_view, name="rename_gif"),
    path("gif/<str:gif_id>/copy/", views.copy_gif_view, name="copy_gif"),
    path("gif/<str:gif_id>/delete/", views.delete_gif_view, name="delete_gif"),
    path("upload/", views.upload_view, name="upload"),
    path("api/gifs/", views.api_list_gifs, name="api_list_gifs"),
]
