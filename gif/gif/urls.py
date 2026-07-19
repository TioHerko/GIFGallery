from django.contrib import admin
from django.contrib.auth import views as auth_views
from django.urls import include, path

from gallery import views as gallery_views

urlpatterns = [
    path("admin/", admin.site.urls),
    path("login/", gallery_views.FirstRunLoginView.as_view(), name="login"),
    path("logout/", auth_views.LogoutView.as_view(), name="logout"),
    path("setup/", gallery_views.setup_view, name="setup"),
    path("", include("gallery.urls")),
]
