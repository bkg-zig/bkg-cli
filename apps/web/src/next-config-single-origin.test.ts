import { afterEach, describe, expect, it, vi } from "vitest";

// The single-origin proxy is what makes a deployment whose dashboard and
// api-server cannot share a host work at all: the session cookie is
// host-scoped, and two hosts without a shared registrable domain make it a
// third-party cookie that SameSite=Lax never sends. Railway's random
// `*.up.railway.app` domains are exactly that case (`up.railway.app` is a
// public suffix), so the web has to serve the api's prefixes and the
// gateway under its own origin — the same hop `pnpm dev` does.
//
// The switch is opt-in, so the tests pin BOTH sides: off by default (the
// compose stack and the Helm chart share one hostname already) and on when
// a deployment asks for it.

interface RewriteRule {
  source: string;
  destination: string;
}

interface NextConfig {
  rewrites?: () => Promise<{ afterFiles: RewriteRule[] }>;
}

const ORIGINAL_ENV = { ...process.env };

const loadConfig = async (
  env: Record<string, string | undefined>,
): Promise<NextConfig> => {
  vi.resetModules();
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }
  const mod = await import("../next.config.js");
  return mod.default as NextConfig;
};

afterEach(() => {
  process.env = { ...ORIGINAL_ENV };
  vi.resetModules();
});

describe("production single-origin proxy", () => {
  it("is off unless a deployment asks for it", async () => {
    const config = await loadConfig({
      ONECLI_SINGLE_ORIGIN_PROXY: undefined,
    });
    expect(config.rewrites).toBeUndefined();
  });

  it("proxies the api's prefixes and the gateway under the dashboard's origin", async () => {
    const config = await loadConfig({
      ONECLI_SINGLE_ORIGIN_PROXY: "1",
      INTERNAL_API_URL: "http://api.railway.internal:10256",
      GATEWAY_INTERNAL_URL: "http://gateway.railway.internal:10255",
    });
    expect(config.rewrites).toBeTypeOf("function");
    const rules = (await config.rewrites!()).afterFiles;
    expect(rules).toEqual([
      {
        source: "/v1/:path*",
        destination: "http://api.railway.internal:10256/v1/:path*",
      },
      {
        source: "/auth/:path*",
        destination: "http://api.railway.internal:10256/auth/:path*",
      },
      {
        source: "/gw/:path*",
        destination: "http://gateway.railway.internal:10255/:path*",
      },
    ]);
  });

  it("never proxies the PUBLIC api origin (web → tunnel → web loop)", async () => {
    const config = await loadConfig({
      ONECLI_SINGLE_ORIGIN_PROXY: "1",
      INTERNAL_API_URL: "http://api.railway.internal:10256",
      GATEWAY_INTERNAL_URL: "http://gateway.railway.internal:10255",
      API_URL: "https://api-production-f27ca.up.railway.app",
      GATEWAY_API_URL: "https://gateway-production-b061.up.railway.app",
    });
    const rules = (await config.rewrites!()).afterFiles;
    expect(
      rules.every((rule) => rule.destination.includes("railway.internal")),
    ).toBe(true);
  });
});
