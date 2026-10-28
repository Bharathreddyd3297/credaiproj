"""Keycloak access-token validation for the AIOps API.

Every /api/ai call (except the health probes) needs
`Authorization: Bearer <access token>` from the admin portal: the token's
signature is checked against Keycloak's published keys, its issuer,
audience and expiry are verified, and it must carry the ADMIN realm role.
Same rules as payment-service (payment-service/app/auth.py).
"""

from __future__ import annotations

import json
import urllib.request
from functools import lru_cache

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config.settings import Settings, get_settings

_bearer = HTTPBearer(auto_error=False)


@lru_cache(maxsize=4)
def _jwks_client(issuer_uri: str, jwks_uri: str) -> jwt.PyJWKClient:
    """Finds Keycloak's signing keys once; PyJWKClient caches the keys."""
    if not jwks_uri:
        discovery_url = f"{issuer_uri}/.well-known/openid-configuration"
        with urllib.request.urlopen(discovery_url, timeout=5) as response:
            jwks_uri = json.load(response)["jwks_uri"]
    return jwt.PyJWKClient(jwks_uri, cache_keys=True)


def _unauthorized(detail: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


def token_claims(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    settings: Settings = Depends(get_settings),
) -> dict:
    """Validates the bearer token and returns its claims."""
    if credentials is None:
        raise _unauthorized("Sign in to continue")
    try:
        # Reject malformed tokens before contacting Keycloak for keys
        jwt.get_unverified_header(credentials.credentials)
        signing_key = _jwks_client(settings.oidc_issuer_uri, settings.oidc_jwks_uri).get_signing_key_from_jwt(
            credentials.credentials
        )
        return jwt.decode(
            credentials.credentials,
            signing_key.key,
            algorithms=["RS256"],
            audience=settings.oidc_audience,
            issuer=settings.oidc_issuer_uri,
            options={"require": ["exp", "iat", "sub"]},
        )
    except jwt.PyJWTError:
        raise _unauthorized("Your session is invalid or has expired")
    except OSError:
        # Keycloak unreachable: fail closed, but say why
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="Sign-in service unavailable")


def require_admin(
    claims: dict = Depends(token_claims), settings: Settings = Depends(get_settings)
) -> dict:
    """The token must carry the required realm role (ADMIN by default)."""
    roles = claims.get("realm_access", {}).get("roles", [])
    if settings.required_role not in roles:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Access denied")
    return claims
