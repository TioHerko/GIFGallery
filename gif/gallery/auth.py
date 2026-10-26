import functools
import re

from asgiref.sync import iscoroutinefunction
from django.http import JsonResponse
from django.utils import timezone
from django.utils.decorators import sync_and_async_middleware

from .models import APIToken

# Only the async endpoints that validate a Bearer token themselves may skip
# CSRF checks. Applying the exemption globally would also exempt the
# session-authenticated HTML views (settings, admin, logout) from CSRF, where
# a request merely carrying an Authorization header would authenticate via the
# session cookie.
_BEARER_CSRF_EXEMPT_PATHS = re.compile(
    r"^/gif/[^/]+/(?:tags|rename|copy|delete)/$"
)
_BEARER_CSRF_EXEMPT_FIXED_PATHS = frozenset({"/upload/"})


def _has_bearer_header(request):
    return request.headers.get("Authorization", "").startswith("Bearer ")


def _is_bearer_csrf_exempt_path(path):
    return (
        path in _BEARER_CSRF_EXEMPT_FIXED_PATHS
        or _BEARER_CSRF_EXEMPT_PATHS.match(path) is not None
    )


@sync_and_async_middleware
def bearer_csrf_exempt_middleware(get_response):
    """Mark Bearer requests to the token-authenticated API endpoints as
    CSRF-exempt before CsrfViewMiddleware runs.

    Browsers don't attach Authorization headers to cross-origin requests
    without a CORS preflight (which this app never approves), so the header's
    presence rules out CSRF — PROVIDED such requests can only authenticate via
    the token itself, and provided the exemption is scoped to those endpoints.
    `auth_required` guarantees the first part; the path allowlist above
    guarantees the second. Session-authenticated HTML views (settings, admin,
    logout) are never exempted.
    """
    if iscoroutinefunction(get_response):
        async def middleware(request):
            if _has_bearer_header(request) and _is_bearer_csrf_exempt_path(
                request.path
            ):
                request._dont_enforce_csrf_checks = True
            return await get_response(request)
    else:
        def middleware(request):
            if _has_bearer_header(request) and _is_bearer_csrf_exempt_path(
                request.path
            ):
                request._dont_enforce_csrf_checks = True
            return get_response(request)
    return middleware


async def _get_bearer_user(request):
    raw_token = request.headers.get("Authorization", "")[7:]
    token_hash = APIToken.hash_token(raw_token)
    try:
        api_token = await APIToken.objects.select_related("user").aget(
            token_hash=token_hash
        )
    except APIToken.DoesNotExist:
        return None
    if api_token.expires_at is not None and api_token.expires_at <= timezone.now():
        return None
    return api_token.user


def auth_required(view):
    @functools.wraps(view)
    async def wrapper(request, *args, **kwargs):
        # A request that carries a Bearer header was CSRF-exempted by the
        # middleware, so it must authenticate via the token alone — falling
        # back to session auth here would let an invalid token turn into a
        # CSRF bypass for session-cookie requests.
        if _has_bearer_header(request):
            user = await _get_bearer_user(request)
            if user is None:
                return JsonResponse({"error": "Invalid token"}, status=401)
            request.user = user
            return await view(request, *args, **kwargs)

        # Session auth (resolve lazy user object asynchronously)
        user = await request.auser()
        if user.is_authenticated:
            request.user = user
            return await view(request, *args, **kwargs)

        return JsonResponse({"error": "Authentication required"}, status=401)

    return wrapper
