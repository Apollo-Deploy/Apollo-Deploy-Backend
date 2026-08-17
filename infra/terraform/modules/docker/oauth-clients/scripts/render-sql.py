#!/usr/bin/env python3
"""Render idempotent Better Auth oauthClient SQL from module output JSON.

Usage:
    terraform output -json clients | ./scripts/render-sql.py

The input must be the direct JSON encoding of the module's `clients` output.
Plaintext confidential-client secrets are hashed before rendering and never
appear in the generated SQL.
"""

from __future__ import annotations

import base64
import hashlib
import json
import re
import sys
import uuid
from typing import Any, NoReturn


ALLOWED_FIELDS = frozenset(
    {
        "record_id",
        "key",
        "name",
        "client_id",
        "client_secret",
        "is_public",
        "grant_types",
        "redirect_uris",
        "post_logout_redirect_uris",
        "scope",
        "skip_consent",
    }
)
ALLOWED_GRANT_TYPES = frozenset(
    {"authorization_code", "client_credentials", "refresh_token"}
)
KEY_RE = re.compile(r"^[a-z][a-z0-9_-]{0,63}$")
CLIENT_ID_RE = re.compile(r"^[A-Za-z]{32}$")
SCOPE_RE = re.compile(r"^[A-Za-z0-9._~:/-]+(?: [A-Za-z0-9._~:/-]+)*$")
URI_RE = re.compile(r"^https?://[^\s#]+$")


class InputError(ValueError):
    """Raised when the module output does not match the renderer contract."""


def fail(message: str) -> NoReturn:
    raise InputError(message)


def reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON object key: {key!r}")
        result[key] = value
    return result


def require_string(value: Any, path: str, *, maximum: int | None = None) -> str:
    if not isinstance(value, str):
        fail(f"{path} must be a string")
    if "\x00" in value:
        fail(f"{path} cannot contain a NUL byte")
    if maximum is not None and len(value) > maximum:
        fail(f"{path} must be at most {maximum} characters")
    return value


def require_bool(value: Any, path: str) -> bool:
    if type(value) is not bool:
        fail(f"{path} must be a boolean")
    return value


def require_string_list(value: Any, path: str) -> list[str]:
    if not isinstance(value, list):
        fail(f"{path} must be a list")
    result = [require_string(item, f"{path}[{index}]") for index, item in enumerate(value)]
    if len(set(result)) != len(result):
        fail(f"{path} cannot contain duplicates")
    return result


def validate_uri_list(value: Any, path: str) -> list[str]:
    uris = require_string_list(value, path)
    for index, uri in enumerate(uris):
        if len(uri) > 2048 or URI_RE.fullmatch(uri) is None:
            fail(
                f"{path}[{index}] must be an absolute HTTP(S) URI of at most "
                "2048 characters without whitespace or a fragment"
            )
    return uris


def validate_uuid(value: Any, path: str) -> str:
    record_id = require_string(value, path)
    try:
        parsed = uuid.UUID(record_id)
    except ValueError as error:
        raise InputError(f"{path} must be a canonical UUID") from error
    if str(parsed) != record_id:
        fail(f"{path} must be a lowercase canonical UUID")
    return record_id


def validate_client(map_key: str, raw: Any) -> dict[str, Any]:
    path = f"clients[{map_key!r}]"
    if not isinstance(raw, dict):
        fail(f"{path} must be an object")

    fields = frozenset(raw)
    missing = sorted(ALLOWED_FIELDS - fields)
    unknown = sorted(fields - ALLOWED_FIELDS)
    if missing:
        fail(f"{path} is missing fields: {', '.join(missing)}")
    if unknown:
        fail(f"{path} has unknown fields: {', '.join(unknown)}")

    key = require_string(raw["key"], f"{path}.key")
    if key != map_key:
        fail(f"{path}.key must equal its containing map key")
    if KEY_RE.fullmatch(key) is None:
        fail(f"{path}.key has an invalid format")

    name = require_string(raw["name"], f"{path}.name", maximum=255)
    if not name.strip() or any(ord(character) < 32 or ord(character) == 127 for character in name):
        fail(f"{path}.name must be non-empty and contain no control characters")

    is_public = require_bool(raw["is_public"], f"{path}.is_public")
    skip_consent = require_bool(raw["skip_consent"], f"{path}.skip_consent")

    grant_types = require_string_list(raw["grant_types"], f"{path}.grant_types")
    if not grant_types or not set(grant_types).issubset(ALLOWED_GRANT_TYPES):
        fail(f"{path}.grant_types contains an unsupported grant type")
    if "refresh_token" in grant_types and "authorization_code" not in grant_types:
        fail(f"{path}.grant_types requires authorization_code when refresh_token is used")
    if is_public and "client_credentials" in grant_types:
        fail(f"{path}.grant_types cannot give client_credentials to a public client")

    redirect_uris = validate_uri_list(raw["redirect_uris"], f"{path}.redirect_uris")
    if "authorization_code" in grant_types and not redirect_uris:
        fail(f"{path}.redirect_uris is required for authorization_code")

    post_logout_redirect_uris = validate_uri_list(
        raw["post_logout_redirect_uris"], f"{path}.post_logout_redirect_uris"
    )
    if post_logout_redirect_uris and "authorization_code" not in grant_types:
        fail(f"{path}.post_logout_redirect_uris requires authorization_code")

    scope = require_string(raw["scope"], f"{path}.scope", maximum=4096)
    if SCOPE_RE.fullmatch(scope) is None or len(set(scope.split(" "))) != len(scope.split(" ")):
        fail(f"{path}.scope must contain unique, single-space-separated OAuth scope tokens")

    client_id = require_string(raw["client_id"], f"{path}.client_id")
    if CLIENT_ID_RE.fullmatch(client_id) is None:
        fail(f"{path}.client_id must contain exactly 32 ASCII letters")

    client_secret = raw["client_secret"]
    if is_public:
        if client_secret is not None:
            fail(f"{path}.client_secret must be null for a public client")
    else:
        client_secret = require_string(client_secret, f"{path}.client_secret")
        if len(client_secret) < 32:
            fail(f"{path}.client_secret must contain at least 32 characters")

    return {
        "record_id": validate_uuid(raw["record_id"], f"{path}.record_id"),
        "key": key,
        "name": name,
        "client_id": client_id,
        "client_secret": client_secret,
        "is_public": is_public,
        "grant_types": grant_types,
        "redirect_uris": redirect_uris,
        "post_logout_redirect_uris": post_logout_redirect_uris,
        "scope": scope,
        "skip_consent": skip_consent,
    }


def load_clients(raw_input: str) -> list[dict[str, Any]]:
    if not raw_input.strip():
        fail("stdin is empty")
    try:
        decoded = json.loads(raw_input, object_pairs_hook=reject_duplicate_json_keys)
    except json.JSONDecodeError as error:
        raise InputError(f"stdin is not valid JSON: {error.msg}") from error

    if not isinstance(decoded, dict) or not decoded:
        fail("stdin must be a non-empty object keyed by OAuth client key")

    clients: list[dict[str, Any]] = []
    for map_key in sorted(decoded):
        if not isinstance(map_key, str):
            fail("every client map key must be a string")
        clients.append(validate_client(map_key, decoded[map_key]))

    client_ids = [client["client_id"] for client in clients]
    if len(set(client_ids)) != len(client_ids):
        fail("client_id values must be unique")
    record_ids = [client["record_id"] for client in clients]
    if len(set(record_ids)) != len(record_ids):
        fail("record_id values must be unique")
    return clients


def hash_client_secret(secret: str) -> str:
    """Match Better Auth's SHA-256, base64url, no-padding default hasher."""
    digest = hashlib.sha256(secret.encode("utf-8")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def sql_text(value: str) -> str:
    """Return a collision-safe PostgreSQL dollar-quoted string literal."""
    if "\x00" in value:
        fail("PostgreSQL text values cannot contain a NUL byte")
    suffix = hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]
    tag = f"oauth_{suffix}"
    while f"${tag}$" in value:
        tag += "_x"
    delimiter = f"${tag}$"
    return f"{delimiter}{value}{delimiter}"


def compact_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def sql_bool(value: bool) -> str:
    return "TRUE" if value else "FALSE"


def render_client(client: dict[str, Any]) -> str:
    key_literal = sql_text(client["key"])
    client_id_literal = sql_text(client["client_id"])
    secret_literal = (
        "NULL"
        if client["client_secret"] is None
        else sql_text(hash_client_secret(client["client_secret"]))
    )
    scopes_literal = sql_text(compact_json(client["scope"].split(" ")))
    redirects_literal = sql_text(compact_json(client["redirect_uris"]))
    post_logout_literal = (
        "NULL"
        if not client["post_logout_redirect_uris"]
        else sql_text(compact_json(client["post_logout_redirect_uris"]))
    )
    grants_literal = sql_text(compact_json(client["grant_types"]))
    response_types_literal = sql_text(compact_json(["code"]))
    token_auth_method = "none" if client["is_public"] else "client_secret_basic"
    client_type = "user-agent-based" if client["is_public"] else "web"
    metadata_literal = sql_text(
        compact_json(
            {
                "firstPartyKey": client["key"],
                "firstParty": client["skip_consent"],
            }
        )
    )

    return f"""-- Client {client['key']}:
--   Replacing its random_string.client_id is an explicit client-ID rotation.
--   The DELETE removes prior rows with this firstPartyKey and cascades their tokens.
--   Replacing its random_password.client_secret explicitly invalidates the old secret.
DELETE FROM "oauthClient"
WHERE metadata->>'firstPartyKey' = {key_literal}
  AND "clientId" <> {client_id_literal};

INSERT INTO "oauthClient" (
  id,
  "clientId",
  "clientSecret",
  disabled,
  "skipConsent",
  "enableEndSession",
  scopes,
  "userId",
  "createdAt",
  "updatedAt",
  name,
  "redirectUris",
  "postLogoutRedirectUris",
  "tokenEndpointAuthMethod",
  "grantTypes",
  "responseTypes",
  public,
  type,
  "referenceId",
  metadata
) VALUES (
  {sql_text(client['record_id'])},
  {client_id_literal},
  {secret_literal},
  FALSE,
  {sql_bool(client['skip_consent'])},
  TRUE,
  {scopes_literal},
  NULL,
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP,
  {sql_text(client['name'])},
  {redirects_literal},
  {post_logout_literal},
  {sql_text(token_auth_method)},
  {grants_literal},
  {response_types_literal},
  {sql_bool(client['is_public'])},
  {sql_text(client_type)},
  NULL,
  {metadata_literal}::jsonb
)
ON CONFLICT ("clientId") DO UPDATE SET
  id = EXCLUDED.id,
  "clientSecret" = EXCLUDED."clientSecret",
  disabled = EXCLUDED.disabled,
  "skipConsent" = EXCLUDED."skipConsent",
  "enableEndSession" = EXCLUDED."enableEndSession",
  scopes = EXCLUDED.scopes,
  "userId" = EXCLUDED."userId",
  "updatedAt" = CURRENT_TIMESTAMP,
  name = EXCLUDED.name,
  "redirectUris" = EXCLUDED."redirectUris",
  "postLogoutRedirectUris" = EXCLUDED."postLogoutRedirectUris",
  "tokenEndpointAuthMethod" = EXCLUDED."tokenEndpointAuthMethod",
  "grantTypes" = EXCLUDED."grantTypes",
  "responseTypes" = EXCLUDED."responseTypes",
  public = EXCLUDED.public,
  type = EXCLUDED.type,
  "referenceId" = EXCLUDED."referenceId",
  metadata = EXCLUDED.metadata;
"""


def render_sql(clients: list[dict[str, Any]]) -> str:
    body = "\n".join(render_client(client) for client in clients)
    return f"""-- Generated by oauth-clients/scripts/render-sql.py. DO NOT EDIT.
-- Plaintext client secrets are intentionally absent; only Better Auth SHA-256 hashes follow.
-- Terraform random resources are stable by client key. Any -replace operation is an
-- explicit credential rotation and should be coordinated with every client consumer.
BEGIN;

-- Serialize duplicate cleanup and upserts because metadata.firstPartyKey has no unique index.
LOCK TABLE "oauthClient" IN SHARE ROW EXCLUSIVE MODE;

{body}
COMMIT;
"""


def main() -> int:
    try:
        clients = load_clients(sys.stdin.read())
        sys.stdout.write(render_sql(clients))
    except InputError as error:
        print(f"render-sql.py: error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
