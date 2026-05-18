"""Provision or clean up the Authentik fixture for remote-access SSH smoke tests.

Run inside `ak shell`; the wrapper script feeds this file to the Authentik pod.
"""

import json
import os
from datetime import timedelta

from django.utils import timezone

from authentik.core.models import Application, Group, User
from authentik.lib.generators import generate_id
from authentik.providers.oauth2.models import AuthorizationCode, OAuth2Provider, ScopeMapping


ACTION = os.environ.get("SR_AUTHENTIK_SMOKE_ACTION", "provision")
SLUG = os.environ.get("SR_AUTHENTIK_SMOKE_SLUG", "serviceradar-remote-access-smoke")
NAME = os.environ.get("SR_AUTHENTIK_SMOKE_NAME", "ServiceRadar Remote Access Smoke")
REDIRECT_URI = os.environ.get(
    "SR_AUTHENTIK_SMOKE_REDIRECT_URI",
    "http://localhost:4000/auth/oidc/callback",
)
USERNAME = os.environ.get("SR_AUTHENTIK_SMOKE_USERNAME", "serviceradar-remote-access-smoke")
EMAIL = os.environ.get("SR_AUTHENTIK_SMOKE_EMAIL", USERNAME + "@example.test")
GROUP_NAME = os.environ.get("SR_AUTHENTIK_SMOKE_GROUP", "serviceradar-remote-access-smoke")
CLIENT_SECRET = os.environ.get("SR_AUTHENTIK_SMOKE_CLIENT_SECRET") or generate_id(96)
NONCE = os.environ.get("SR_AUTHENTIK_SMOKE_NONCE") or generate_id()
DISCOVERY_BASE = os.environ.get("SR_AUTHENTIK_SMOKE_DISCOVERY_BASE", "https://auth.carverauto.dev")


def cleanup():
    Application.objects.filter(slug=SLUG).delete()
    OAuth2Provider.objects.filter(name=NAME).delete()
    ScopeMapping.objects.filter(name=f"{NAME} groups").delete()
    User.objects.filter(username=USERNAME).delete()
    Group.objects.filter(name=GROUP_NAME).delete()
    print("SR_AUTHENTIK_FIXTURE_JSON=" + json.dumps({"action": "cleanup", "slug": SLUG}))


def scope_mappings(group_mapping):
    default_scopes = list(
        ScopeMapping.objects.filter(scope_name__in=["openid", "email", "profile"]).order_by("name")
    )
    return default_scopes + [group_mapping]


def provision():
    template = OAuth2Provider.objects.exclude(authorization_flow=None).first()
    if template is None:
        raise RuntimeError("no existing Authentik OAuth2 provider is available to copy flows from")

    provider, _ = OAuth2Provider.objects.update_or_create(
        name=NAME,
        defaults={
            "authentication_flow": template.authentication_flow,
            "authorization_flow": template.authorization_flow,
            "invalidation_flow": template.invalidation_flow,
            "client_type": "confidential",
            "client_id": generate_id(40),
            "client_secret": CLIENT_SECRET,
            "_redirect_uris": [{"url": REDIRECT_URI, "matching_mode": "strict"}],
            "include_claims_in_id_token": True,
            "access_code_validity": "minutes=5",
            "access_token_validity": "minutes=10",
            "refresh_token_validity": "minutes=10",
            "refresh_token_threshold": "minutes=0",
            "sub_mode": "user_username",
            "issuer_mode": "per_provider",
            "signing_key": template.signing_key,
        },
    )

    group_mapping, _ = ScopeMapping.objects.update_or_create(
        name=f"{NAME} groups",
        defaults={
            "scope_name": "groups",
            "description": "ServiceRadar remote-access smoke-test group claim",
            "expression": (
                'return {"groups": sorted(set(group.name for group in request.user.groups.all()))}'
            ),
        },
    )
    provider.property_mappings.set(scope_mappings(group_mapping))

    app, _ = Application.objects.update_or_create(
        slug=SLUG,
        defaults={"name": NAME, "provider": provider},
    )

    group, _ = Group.objects.get_or_create(name=GROUP_NAME)
    user, _ = User.objects.update_or_create(
        username=USERNAME,
        defaults={
            "email": EMAIL,
            "name": "ServiceRadar Remote Access Smoke",
            "is_active": True,
        },
    )
    user.groups.add(group)

    AuthorizationCode.objects.filter(provider=provider, user=user).delete()
    auth_code = AuthorizationCode.objects.create(
        provider=provider,
        user=user,
        expires=timezone.now() + timedelta(minutes=5),
        auth_time=timezone.now(),
        code=generate_id(48),
        nonce=NONCE,
    )
    auth_code.scope = ["openid", "email", "profile", "groups"]
    auth_code.save()

    discovery_url = f"{DISCOVERY_BASE.rstrip('/')}/application/o/{app.slug}"
    payload = {
        "action": "provision",
        "application_slug": app.slug,
        "client_id": provider.client_id,
        "discovery_url": discovery_url,
        "redirect_uri": REDIRECT_URI,
        "code": auth_code.code,
        "nonce": NONCE,
        "username": user.username,
        "email": user.email,
        "group": group.name,
    }
    print("SR_AUTHENTIK_FIXTURE_JSON=" + json.dumps(payload, sort_keys=True))


if ACTION == "cleanup":
    cleanup()
else:
    provision()
