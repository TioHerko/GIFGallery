"""Cache-backed throttling for sign-in attempts.

Limits are tracked per username and per client IP. The cache backend defaults
to Django's per-process LocMemCache; deployments with multiple workers that
need a single shared limit should configure a shared cache backend.
"""

import hashlib

from django.conf import settings
from django.core.cache import cache
from django.http import HttpResponse

THROTTLED_PATHS = frozenset({"/login/", "/admin/login/", "/setup/"})
FAILURE_STATUS_CODES = frozenset({200, 400})
SUCCESS_STATUS_CODE = 302


def _key(scope, value):
    digest = hashlib.sha256(value.encode()).hexdigest()[:32]
    return f"gif-login-throttle:{scope}:{digest}"


def _client_ip(request):
    if settings.LOGIN_THROTTLE_TRUST_PROXY:
        # Cloudflare overwrites this with the real client address.
        cloudflare_ip = request.META.get("HTTP_CF_CONNECTING_IP", "").strip()
        if cloudflare_ip:
            return cloudflare_ip
        forwarded = request.META.get("HTTP_X_FORWARDED_FOR", "")
        if forwarded:
            # The trusted proxy either replaces the header or appends the
            # address it saw, so the last entry is the one we can rely on
            # (earlier entries are client-supplied).
            return forwarded.split(",")[-1].strip()
        real_ip = request.META.get("HTTP_X_REAL_IP", "").strip()
        if real_ip:
            return real_ip
    return request.META.get("REMOTE_ADDR", "").strip()


def _record(key):
    try:
        cache.incr(key)
    except ValueError:
        cache.set(key, 1, settings.LOGIN_THROTTLE_WINDOW_SECONDS)


def _reset(keys):
    if keys:
        cache.delete_many(keys)


class LoginThrottleMiddleware:
    """Rate-limit POSTs to the login, admin login, and setup pages."""

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if request.method != "POST" or request.path not in THROTTLED_PATHS:
            return self.get_response(request)

        ip = _client_ip(request)
        username = request.POST.get("username", "").strip().casefold()
        limits = []
        if ip:
            limits.append(("ip", _key("ip", ip), settings.LOGIN_THROTTLE_IP_ATTEMPTS))
        if username:
            limits.append(
                ("user", _key("user", username), settings.LOGIN_THROTTLE_USER_ATTEMPTS)
            )

        for _, key, limit in limits:
            if cache.get(key, 0) >= limit:
                response = HttpResponse(
                    "Too many sign-in attempts. Try again later.",
                    status=429,
                    content_type="text/plain",
                )
                response["Retry-After"] = str(settings.LOGIN_THROTTLE_WINDOW_SECONDS)
                return response

        response = self.get_response(request)
        keys = [key for _, key, _ in limits]
        if response.status_code == SUCCESS_STATUS_CODE:
            _reset(keys)
        elif response.status_code in FAILURE_STATUS_CODES:
            for key in keys:
                _record(key)
        return response
