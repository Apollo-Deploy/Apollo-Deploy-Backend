# Machine-to-Machine (M2M) Authentication

This guide documents how Apollo's internal APIs authenticate to each other using
OAuth 2.1 `client_credentials`. It applies to all first-party services:
`apollo-platform-api`, `apollo-billing-api`, `apollo-signal-api`, and any
future API added to the fleet.

---

## Overview

The platform is the **identity provider** for all inter-service auth. Every
first-party service gets a single OAuth client registration on the platform.
When a service needs to call another service's `/internal/*` endpoints, it:

1. Fetches a short-lived JWT from the platform's token endpoint using its
   `client_id` + `client_secret`.
2. Sends that JWT as `Authorization: Bearer <token>` on every outbound
   internal request.
3. The receiving service verifies the JWT locally against the platform's public
   JWKS — no shared secret, no network call per request.

This is the only authentication pattern for internal service-to-service calls.
The legacy `INTERNAL_SERVICE_SECRET` shared-secret approach still exists as a
fallback on the platform but should not be used in new integrations.

---

## How the Token Flow Works

```
Caller Service                Platform API                 Target Service
      │                            │                              │
      │  POST /auth/oauth2/token   │                              │
      │  client_id + client_secret │                              │
      │ ─────────────────────────> │                              │
      │                            │  issues EdDSA-signed JWT     │
      │ <───────────────────────── │                              │
      │                            │                              │
      │  GET /internal/...         │                              │
      │  Authorization: Bearer JWT │                              │
      │ ─────────────────────────────────────────────────────── > │
      │                            │                              │  verifies JWT
      │                            │  GET /auth/jwks (cached)     │  via JWKS
      │                            │ <──────────────────────────  │
      │                            │  EdDSA public keys           │
      │                            │ ─────────────────────────── >│
      │                            │                              │  checks iss, aud,
      │                            │                              │  exp, azp allowlist
      │ <──────────────────────────────────────────────────────── │
```

**Key properties:**
- Tokens are EdDSA-signed (Ed25519), verified asymmetrically — no shared secret
  is needed by the verifying service.
- The JWKS is fetched once and cached for 300 seconds; key rotation is
  transparent to callers.
- Tokens expire in 3600 seconds. Clients refresh 60 seconds before expiry.
- The receiving service maintains an explicit allowlist of `client_id`s that may
  call its internal routes. It **fails closed** when the list is empty.

---

## Setting Up a New Service (Step by Step)

### Step 1 — Register an OAuth client on the platform

From the `apollo-platform-api` directory:

```bash
bun run oauth:register-clients
```

When prompted, use these settings for the new service:

| Field | Value |
|---|---|
| key | `<service-slug>` (e.g. `signal`, `deploy`) |
| grant_types | `client_credentials` (+ `authorization_code` if it also serves users) |
| skipConsent | `true` |
| scopes | `openid profile email` (+ any service-specific scopes) |

Save the returned `client_id` and `client_secret`. You will not be able to
retrieve the secret again.

---

### Step 2 — Configure the new service's environment

Add these to the new service's `.env`:

```dotenv
# Platform OAuth M2M — used to obtain service tokens
PLATFORM_URL=http://platform:3000               # in-cluster URL (no TLS needed)
PLATFORM_AUDIENCE_URL=https://api.platform.apollodeploy.com  # public URL, used as JWT resource/audience
PLATFORM_CLIENT_ID=<client_id>                  # from Step 1
PLATFORM_CLIENT_SECRET=<client_secret>          # from Step 1

# JWKS verification — used to verify tokens received from other services
AUTH_JWKS_URL=                                  # optional (defaults to {PLATFORM_URL}/auth/jwks)
AUTH_OAUTH_ISSUER_URL=https://api.platform.apollodeploy.com
AUTH_OAUTH_VALID_AUDIENCES=https://api.platform.apollodeploy.com
OAUTH_SERVICE_CLIENT_IDS=                       # comma-separated client_ids allowed to call this service's /internal/*
```

> `PLATFORM_URL` is the in-cluster URL for token requests (no TLS required).
> `PLATFORM_AUDIENCE_URL` is the public URL embedded as the `aud` claim in the
> JWT — it must match what other services put in `AUTH_OAUTH_VALID_AUDIENCES`.

---

### Step 3 — Allow the new service to call existing services

**If the new service will call `apollo-billing-api`:**

Add the new service's `client_id` to billing's `OAUTH_SERVICE_CLIENT_IDS`, then
restart billing:

```dotenv
# billing .env
OAUTH_SERVICE_CLIENT_IDS=existing-id,<new-service-client-id>
```

**If the new service will call `apollo-platform-api`'s internal routes:**

Add the new service's `client_id` to platform's `OAUTH_SERVICE_CLIENT_IDS` and
`OAUTH_TRUSTED_CLIENT_IDS`, then restart platform:

```dotenv
# platform .env
OAUTH_SERVICE_CLIENT_IDS=existing-id,<new-service-client-id>
OAUTH_TRUSTED_CLIENT_IDS=existing-id,<new-service-client-id>
```

---

### Step 4 — Implement outbound token fetching

#### TypeScript (Bun/Node)

The platform already has a ready-made token client in
`src/utils/billing-client.ts`. For a new TypeScript service, copy the same
pattern:

```typescript
import { auth } from "@/utils/better-auth.js";

interface TokenCache {
  accessToken: string;
  expiresAt: number; // Unix ms
}

let _tokenCache: TokenCache | null = null;

async function fetchServiceToken(): Promise<string> {
  const now = Date.now();
  if (_tokenCache && _tokenCache.expiresAt - 60_000 > now) {
    return _tokenCache.accessToken;
  }

  // For the platform: invoke Better Auth in-process (no network hop).
  // For other TypeScript services: use a regular fetch() to PLATFORM_URL.
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: process.env.PLATFORM_CLIENT_ID!,
    client_secret: process.env.PLATFORM_CLIENT_SECRET!,
    resource: process.env.PLATFORM_AUDIENCE_URL!,
  });

  const res = await fetch(
    `${process.env.PLATFORM_URL}/auth/oauth2/token`,
    {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    },
  );

  if (!res.ok) {
    throw new Error(`Token fetch failed: ${res.status}`);
  }

  const json = (await res.json()) as { access_token: string; expires_in?: number };
  const expiresIn = json.expires_in ?? 3600;

  _tokenCache = {
    accessToken: json.access_token,
    expiresAt: now + expiresIn * 1000,
  };

  return _tokenCache.accessToken;
}
```

> The platform itself uses `auth.handler()` in-process instead of `fetch()` to
> avoid a network dependency on its own URL. Any other TypeScript service should
> use `fetch()` to `PLATFORM_URL`.

Inject the token as a header in every outbound internal request:

```typescript
const token = await fetchServiceToken();
const response = await fetch(`${process.env.TARGET_API_BASE_URL}/internal/...`, {
  headers: { Authorization: `Bearer ${token}` },
});
```

#### Kotlin/Ktor

Use the existing `OAuthM2mClient` class from `apollo-billing-api`. Copy it into
the new service unchanged:

```kotlin
val m2mClient = OAuthM2mClient(
    httpClient = httpClient,
    platformUrl = System.getenv("PLATFORM_URL"),
    clientId = System.getenv("PLATFORM_CLIENT_ID"),
    clientSecret = System.getenv("PLATFORM_CLIENT_SECRET"),
    timeoutMs = 5_000L,
)

// In a coroutine:
val token = m2mClient.getToken()

httpClient.get("${System.getenv("TARGET_API_BASE_URL")}/internal/...") {
    header(HttpHeaders.Authorization, "Bearer $token")
}
```

`OAuthM2mClient` is coroutine-safe, handles token caching, and refreshes
automatically 60 seconds before expiry.

---

### Step 5 — Implement inbound token verification

#### TypeScript (Fastify)

Use `serviceAuthPreHandler` from `src/utils/auth/service-auth.ts`:

```typescript
import { serviceAuthPreHandler } from "@/utils/auth/service-auth.js";

fastify.get(
  "/internal/something",
  { preHandler: [serviceAuthPreHandler] },
  async (request, reply) => {
    // request.serviceClientId is set to the verified client_id
    return { ok: true };
  },
);
```

The guard reads `OAUTH_SERVICE_CLIENT_IDS` at startup, verifies the JWT via
JWKS, and stashes the `client_id` on `request.serviceClientId`. It throws
`UnauthorizedError` or `ForbiddenError` on any failure.

#### Kotlin/Ktor

Use `oauthInternalRoutes` from `OAuthM2mInternalAuth.kt`:

```kotlin
routing {
    oauthInternalRoutes(httpClient) {
        get("/internal/something") {
            val clientId = call.authenticatedClientId()
            call.respond(mapOf("ok" to true))
        }
    }
}
```

The plugin reads `OAUTH_SERVICE_CLIENT_IDS`, `AUTH_JWKS_URL`, `AUTH_OAUTH_ISSUER_URL`,
and `AUTH_OAUTH_VALID_AUDIENCES` from `AppConfig`. It verifies the EdDSA
signature, validates standard JWT claims, checks the `azp`/`sub` allowlist, and
stores the authenticated `clientId` in Ktor call attributes.

---

## Environment Variable Reference

### Every service (caller side)

| Variable | Description | Example |
|---|---|---|
| `PLATFORM_URL` | In-cluster URL to reach the platform's token endpoint | `http://platform:3000` |
| `PLATFORM_AUDIENCE_URL` | Public URL used as the JWT `resource`/`aud` value | `https://api.platform.apollodeploy.com` |
| `PLATFORM_CLIENT_ID` | OAuth client ID issued during registration | `signal` |
| `PLATFORM_CLIENT_SECRET` | OAuth client secret (treat as a password) | `sec_…` |

### Every service (receiver side)

| Variable | Description | Example |
|---|---|---|
| `OAUTH_SERVICE_CLIENT_IDS` | Comma-separated list of `client_id`s allowed to call `/internal/*` | `signal,deploy` |
| `AUTH_JWKS_URL` | Where to fetch the platform's public JWKS (defaults to `{PLATFORM_URL}/auth/jwks`) | _(usually left blank)_ |
| `AUTH_OAUTH_ISSUER_URL` | Expected `iss` claim in incoming tokens (defaults to `PLATFORM_URL`) | `https://api.platform.apollodeploy.com` |
| `AUTH_OAUTH_VALID_AUDIENCES` | Expected `aud` claim(s), comma-separated | `https://api.platform.apollodeploy.com` |
| `IAM_REQUEST_TIMEOUT_MS` | Timeout for JWKS fetches in milliseconds | `5000` |

### Platform-specific (additional)

| Variable | Description |
|---|---|
| `OAUTH_TRUSTED_CLIENT_IDS` | `client_id`s that skip the consent screen (set alongside `OAUTH_SERVICE_CLIENT_IDS`) |

---

## Token Verification Details

When a service receives a request on an `/internal/*` route, it verifies:

| Claim | Check |
|---|---|
| Signature | EdDSA (Ed25519) against public key from JWKS |
| `iss` | Must be in `AUTH_OAUTH_ISSUER_URL` |
| `aud` | Must include at least one value from `AUTH_OAUTH_VALID_AUDIENCES` |
| `exp` | Must not be expired (30-second clock-skew tolerance) |
| `iat` | Must not be issued in the future (30-second tolerance) |
| `azp` or `sub` | Must be in `OAUTH_SERVICE_CLIENT_IDS` |

JWKS are fetched once on first use and cached for 300 seconds. On cache miss or
unknown `kid`, the cache is refreshed. This means key rotations propagate within
5 minutes without a service restart.

---

## Current Service Map

| Service | Role | Calls | Is called by |
|---|---|---|---|
| `apollo-platform-api` | Token issuer + JWKS host | `apollo-billing-api` (internal billing endpoints) | `apollo-billing-api`, `apollo-signal-api` |
| `apollo-billing-api` | Kotlin/Ktor | `apollo-platform-api` (audit log ingest) | `apollo-platform-api`, `apollo-signal-api` |
| `apollo-signal-api` | Kotlin/Ktor | `apollo-billing-api` (enforcement, usage, checkout) | _(none currently)_ |

---

## Revoking a Service

To cut off a service's access without waiting for token expiry:

1. Remove its `client_id` from `OAUTH_SERVICE_CLIENT_IDS` on every service it
   calls, then restart those services.
2. Remove its `client_id` from `OAUTH_SERVICE_CLIENT_IDS` and
   `OAUTH_TRUSTED_CLIENT_IDS` on the platform, then restart the platform.
3. Rotate the `client_secret` via `bun run oauth:register-clients → rotate
   secret` so any leaked credentials are invalidated.

Tokens already in flight expire within 3600 seconds at most. Because the
allowlist check happens on every request, removing a `client_id` from the list
takes effect immediately on restart — you do not need to wait for token expiry.

---

## Security Notes

- **Never log tokens, client secrets, or JWKS private keys.** Tokens are in the
  `Authorization` header; log the `client_id` from the verified claims instead.
- **Never call internal endpoints from browser or mobile clients.** Service
  tokens carry machine-level trust and must only be used server-side.
- **Always validate `orgId` server-side** before forwarding it to another
  service. A valid service token does not substitute for authorization.
- **`OAUTH_SERVICE_CLIENT_IDS` fails closed when empty.** If the list is blank on
  startup, all calls to `/internal/*` are rejected with `403`. This is
  intentional — misconfiguration is safer than open access.
- **Token refresh is non-blocking.** Both `OAuthM2mClient` (Kotlin) and the
  TypeScript token cache use a single-writer lock so only one coroutine/thread
  issues a refresh at a time; all others wait for the result.

---

## Checklist for a New Service

- [ ] Register OAuth client on the platform (`bun run oauth:register-clients`)
- [ ] Set `PLATFORM_CLIENT_ID` + `PLATFORM_CLIENT_SECRET` + `PLATFORM_URL`
      + `PLATFORM_AUDIENCE_URL` in the new service's `.env`
- [ ] Set `AUTH_OAUTH_ISSUER_URL` + `AUTH_OAUTH_VALID_AUDIENCES` in the new service's
      `.env` (must match the platform's values exactly)
- [ ] Implement `OAuthM2mClient` (Kotlin) or the `fetchServiceToken` pattern
      (TypeScript) for outbound calls
- [ ] Implement `oauthInternalRoutes` (Kotlin) or `serviceAuthPreHandler`
      (TypeScript) for inbound `/internal/*` routes
- [ ] Add the new service's `client_id` to `OAUTH_SERVICE_CLIENT_IDS` on every
      service it will call, then restart those services
- [ ] Add the new service's `client_id` to `OAUTH_SERVICE_CLIENT_IDS` +
      `OAUTH_TRUSTED_CLIENT_IDS` on the platform, then restart the platform
- [ ] Verify the integration: call a protected endpoint and confirm you get `200`
      with a valid token and `401`/`403` with a missing or tampered token
