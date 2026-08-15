# Security — RBAC & Authorization

## JWT Claims

The identity service (`STAM-identity`) issues JWTs containing custom claims that downstream services use for authorization decisions:

| Claim    | Type           | Description                                      |
|----------|----------------|--------------------------------------------------|
| `sub`    | String         | Opaque user identifier (Spring Auth Server default) |
| `user_id`| UUID (String)  | Internal user ID, used for ownership checks      |
| `email`  | String         | User's email address                             |
| `roles`  | List\<String\> | Assigned roles: `USER`, `ORGANIZER`, `ADMIN`     |

Resource servers convert the `roles` claim into Spring Security `ROLE_*` granted authorities via a custom `JwtAuthenticationConverter`.

## Catalog Service — Endpoint Authorization Matrix

Authorization is enforced at two layers for defense in depth:

1. **URL-level** — Spring Security filter chain rules in `SecurityConfig`
2. **Method-level** — `@PreAuthorize` annotations on controller methods

| Endpoint                       | Method | Anonymous | USER | ORGANIZER | ADMIN | Extra Check        |
|--------------------------------|--------|-----------|------|-----------|-------|--------------------|
| `GET /api/v1/venues`           | list   | 200       | 200  | 200       | 200   | —                  |
| `GET /api/v1/venues/{id}`      | get    | 200       | 200  | 200       | 200   | —                  |
| `POST /api/v1/venues`          | create | 401       | 403  | 201       | 403*  | —                  |
| `GET /api/v1/events`           | list   | 200       | 200  | 200       | 200   | —                  |
| `GET /api/v1/events/{id}`      | get    | 200       | 200  | 200       | 200   | —                  |
| `POST /api/v1/events`          | create | 401       | 403  | 201       | 403*  | —                  |
| `PUT /api/v1/events/{id}`      | update | 401       | 403  | 200       | 403*  | BOLA ownership     |
| `DELETE /api/v1/events/{id}`   | delete | 401       | 403  | 403       | 204   | —                  |
| `GET /api/v1/shows`            | list   | 200       | 200  | 200       | 200   | —                  |
| `GET /api/v1/shows/{id}`       | get    | 200       | 200  | 200       | 200   | —                  |
| `POST /api/v1/shows`           | create | 401       | 403  | 201       | 403*  | —                  |

\* ADMIN does not currently inherit ORGANIZER permissions — roles are flat, not hierarchical. An ADMIN-role user calling an ORGANIZER-only endpoint receives 403. If role hierarchy is needed, add `RoleHierarchy` bean to `SecurityConfig`.

## BOLA / IDOR Protection

Broken Object Level Authorization (BOLA) is the OWASP API Security #1 risk. The catalog service protects against it on mutation endpoints where ownership matters:

- **`PUT /api/v1/events/{id}`** — after finding the event, the controller compares the JWT `user_id` claim against the event's `organizerId`. If they differ, the request is rejected with 403 (`AccessDeniedException: "You do not own this event"`).
- The `organizerId` is set automatically from the JWT when an event is created — organizers cannot specify it in the request body.
- Events with a `null` organizerId (legacy data created before this migration) are currently editable by any ORGANIZER. This is intentional during the migration window and should be tightened once all events have an owner.

## 403 Response Format

All 403 responses use RFC 9457 Problem Detail JSON (`application/problem+json`):

```json
{
  "type": "about:blank",
  "title": "Forbidden",
  "status": 403,
  "detail": "Access Denied"
}
```

This is handled at two levels:
- **Filter-chain denials** (wrong role at URL level) — custom `AccessDeniedHandler` in `SecurityConfig`
- **Method-level denials** (`@PreAuthorize` / manual `AccessDeniedException`) — `@ExceptionHandler` in `GlobalExceptionHandler`

## Test Coverage

| Test Class           | Scope                                    | Count |
|----------------------|------------------------------------------|-------|
| `RbacSecurityTest`   | @WebMvcTest — role-based access per endpoint, BOLA ownership check, 403 shape | 10 |
| `EventControllerTest`| @WebMvcTest — business logic with ORGANIZER JWT | 5 |
| `VenueSecurityTest`  | @WebMvcTest — venue POST role enforcement | 3 |
| `rbac-negative.spec.ts` | Playwright API — e2e RBAC negative tests (skipped until compose-dev ready) | 4 |

## Future Work

- **Role hierarchy**: consider `RoleHierarchy` so ADMIN inherits ORGANIZER permissions
- **Venue/Show BOLA**: extend ownership checks to venue and show mutation endpoints
- **Per-field authorization**: restrict which fields ORGANIZER vs ADMIN can update
- **Rate limiting by role**: different rate-limit tiers in `STAM-gateway` per role
