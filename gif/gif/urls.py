from django.contrib import admin
from django.contrib.auth import views as auth_views
from django.templatetags.static import static
from django.urls import include, path
from django.views.generic import RedirectView

from gallery import views as gallery_views

urlpatterns = [
    path("admin/", admin.site.urls),
    path("login/", gallery_views.FirstRunLoginView.as_view(), name="login"),
    path("logout/", auth_views.LogoutView.as_view(), name="logout"),
    path("setup/", gallery_views.setup_view, name="setup"),
    # Browsers and link-preview bots request /favicon.ico from the root
    # regardless of <link> tags; send them to the static asset.
    path(
        "favicon.ico",
        RedirectView.as_view(url=static("gallery/favicon.ico")),
        name="favicon",
    ),
    path("", include("gallery.urls")),
]
