import { test, expect } from "@playwright/test";

/**
 * RBAC negative tests — verifies that a USER-role JWT cannot access
 * organizer-only routes on the catalog service.
 *
 * Prerequisites:
 *   - compose-dev environment running (catalog at localhost:8081, identity at localhost:8083)
 *   - A USER-role account registered in identity (e.g. user@stampede.io / password123)
 *   - An ORGANIZER-role account registered (e.g. organizer@stampede.io / password123)
 *
 * When STAM-frontend is built, upgrade these to full UI tests that
 * navigate the SPA and assert 403 error pages.
 */

const CATALOG_BASE = process.env.CATALOG_URL ?? "http://localhost:8081";
const IDENTITY_BASE = process.env.IDENTITY_URL ?? "http://localhost:8083";

async function obtainAccessToken(
  request: any,
  email: string,
  password: string
): Promise<string> {
  // This is a placeholder — full PKCE flow requires browser interaction.
  // In a real e2e setup, use Playwright's browser context to complete the
  // OAuth2 login flow and extract the access_token from the redirect.
  // For now, this test documents the expected behavior.
  throw new Error(
    `Token acquisition not implemented yet — requires full PKCE flow via browser for ${email}`
  );
}

test.describe("RBAC negative tests", () => {
  test.skip(
    () => true,
    "Skipped until identity + catalog compose-dev environment and PKCE token helper are available"
  );

  test("USER cannot POST /api/v1/venues (organizer-only route)", async ({
    request,
  }) => {
    const userToken = await obtainAccessToken(
      request,
      "user@stampede.io",
      "password123"
    );

    const response = await request.post(`${CATALOG_BASE}/api/v1/venues`, {
      headers: { Authorization: `Bearer ${userToken}` },
      data: { name: "Hacker Venue", address: "1 Evil St", capacity: 100 },
    });

    expect(response.status()).toBe(403);
    const body = await response.json();
    expect(body.title).toBe("Forbidden");
  });

  test("USER cannot POST /api/v1/events (organizer-only route)", async ({
    request,
  }) => {
    const userToken = await obtainAccessToken(
      request,
      "user@stampede.io",
      "password123"
    );

    const response = await request.post(`${CATALOG_BASE}/api/v1/events`, {
      headers: { Authorization: `Bearer ${userToken}` },
      data: {
        venueId: "00000000-0000-0000-0000-000000000000",
        name: "Hacker Event",
      },
    });

    expect(response.status()).toBe(403);
    const body = await response.json();
    expect(body.title).toBe("Forbidden");
  });

  test("USER cannot DELETE /api/v1/events/{id} (admin-only route)", async ({
    request,
  }) => {
    const userToken = await obtainAccessToken(
      request,
      "user@stampede.io",
      "password123"
    );

    const response = await request.delete(
      `${CATALOG_BASE}/api/v1/events/00000000-0000-0000-0000-000000000000`,
      {
        headers: { Authorization: `Bearer ${userToken}` },
      }
    );

    expect(response.status()).toBe(403);
  });

  test("ORGANIZER cannot DELETE /api/v1/events/{id} (admin-only route)", async ({
    request,
  }) => {
    const organizerToken = await obtainAccessToken(
      request,
      "organizer@stampede.io",
      "password123"
    );

    const response = await request.delete(
      `${CATALOG_BASE}/api/v1/events/00000000-0000-0000-0000-000000000000`,
      {
        headers: { Authorization: `Bearer ${organizerToken}` },
      }
    );

    expect(response.status()).toBe(403);
  });
});
