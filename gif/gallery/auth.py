import functools

from asgiref.sync import iscoroutinefunction
from django.http import JsonResponse
from django.utils.decorators import sync_and_async_middleware

from .models import APIToken


def _has_bearer_header(request):
    return request.headers.get("Authorization", "").startswith("Bearer ")


@sync_and_async_middleware
def bearer_csrf_exempt_middleware(get_response):
    """Mark requests bearing an `Authorization: Bearer ...` header as
    CSRF-exempt before CsrfViewMiddleware runs. Browsers don't attach
    Authorization headers to cross-origin requests without a CORS preflight
    (which this app never approves), so the header's presence rules out CSRF
    — PROVIDED such requests can only authenticate via the token itself.
    `auth_required` guarantees that: when a Bearer header is present it never
    falls back to session auth, so this exemption can't be combined with a
    browser's ambient session cookie.
    """
    if iscoroutinefunction(get_response):
        async def middleware(request):
            if _has_bearer_header(request):
                request._dont_enforce_csrf_checks = True
            return await get_response(request)
    else:
        def middleware(request):
            if _has_bearer_header(request):
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
