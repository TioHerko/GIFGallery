from django.urls import path

from . import views

app_name = "gallery"

urlpatterns = [
    path("", views.gallery_view, name="gallery"),
    path("gif/<str:gif_id>.gif", views.serve_gif, name="serve_gif"),
    path("gif/<str:gif_id>/tags/", views.tag_gif_view, name="tag_gif"),
    path("upload/", views.upload_view, name="upload"),
]
