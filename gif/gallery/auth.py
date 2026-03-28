import functools

from django.http import JsonResponse

from .models import APIToken


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

        # Bearer token auth
        user = await _get_bearer_user(request)
        if user is not None:
            request.user = user
            # Skip CSRF for token-authenticated requests
            request._dont_enforce_csrf_checks = True
            return await view(request, *args, **kwargs)

        return JsonResponse({"error": "Authentication required"}, status=401)

    return wrapper
