import functools

from asgiref.sync import iscoroutinefunction
from django.http import JsonResponse
from django.utils.decorators import sync_and_async_middleware

from .models import APIToken


@sync_and_async_middleware
def bearer_csrf_exempt_middleware(get_response):
    """Mark requests bearing an `Authorization: Bearer ...` header as
    CSRF-exempt before CsrfViewMiddleware runs. Browsers don't attach
    Authorization headers to cross-origin requests, so the header's
    presence rules out CSRF. Token validity is still enforced by
    `auth_required` on each view.
    """
    if iscoroutinefunction(get_response):
        async def middleware(request):
            if request.headers.get("Authorization", "").startswith("Bearer "):
                request._dont_enforce_csrf_checks = True
            return await get_response(request)
    else:
        def middleware(request):
            if request.headers.get("Authorization", "").startswith("Bearer "):
                request._dont_enforce_csrf_checks = True
            return get_response(request)
    return middleware


async def _get_bearer_user(request):
    header = request.headers.get("Authorization", "")
    if not header.startswith("Bearer "):
        return None
    raw_token = header[7:]
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
        # Session auth (resolve lazy user object asynchronously)
        user = await request.auser()
        if user.is_authenticated:
            return await view(request, *args, **kwargs)

        # Bearer token auth (CSRF already exempted by middleware)
        user = await _get_bearer_user(request)
        if user is not None:
            request.user = user
            return await view(request, *args, **kwargs)

        return JsonResponse({"error": "Authentication required"}, status=401)

    return wrapper
