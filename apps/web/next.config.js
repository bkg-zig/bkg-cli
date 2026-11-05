import { readFileSync } from "node:fs";
import path from "node:path";

const isCloud = process.env.NEXT_PUBLIC_EDITION === "cloud";

// Build-time app version, exposed to the app as NEXT_PUBLIC_APP_VERSION (client +
// server, inlined by Next). Cloud stamps APP_VERSION (semver + short git sha, e.g.
// "1.38.0+f6cca6e5") as a build arg; onprem / self-host / local falls back to the
// monorepo root package.json version, else "dev". process.cwd() is apps/web here.
const resolveAppVersion = () => {
  if (process.env.APP_VERSION) return process.env.APP_VERSION;
  try {
    const pkg = JSON.parse(
      readFileSync(
        path.join(process.cwd(), "..", "..", "package.json"),
        "utf8",
      ),
    );
    return pkg.version || "dev";
  } catch {
    return "dev";
  }
};
const appVersion = resolveAppVersion();

// `next dev` only (see `rewrites` below): NODE_ENV is "development" exactly
// under the dev server, so production builds bake no rewrites at all.
const isDev = process.env.NODE_ENV === "development";

// Where the web proxies `/v1`, better-auth and the gateway to. These are the
// services' addresses on the local network — deliberately NOT the public
// `API_URL`/`GATEWAY_API_URL`: a dev who points those at a tunnel would send
// the proxy hop back out through the tunnel it came from (web → tunnel → web,
// a loop). The same internal-address vars the rest of the stack already uses.
const apiUpstream = (
  process.env.INTERNAL_API_URL ??
  process.env.API_INTERNAL_URL ??
  "http://localhost:10256"
).replace(/\/+$/, "");
const gatewayUpstream = (
  process.env.GATEWAY_INTERNAL_URL ?? "http://localhost:10255"
).replace(/\/+$/, "");

// Production single-origin mode.
//
// A deployment whose dashboard and api-server cannot share a host needs the
// api behind the dashboard's own origin: the session cookie is host-scoped,
// and two hosts that share no registrable domain make it a THIRD-PARTY
// cookie — `SameSite=Lax` then keeps the browser from ever sending it, and
// the dashboard's server-rendered pages never see a session (the sign-up
// request succeeds and the UI still bounces to the login).
//
// Railway's random `*.up.railway.app` domains are exactly that case:
// `up.railway.app` is a public suffix (the PSL's private section), so every
// generated hostname is its own registrable domain and no cookie can span
// two of them. `ONECLI_SINGLE_ORIGIN_PROXY=1` turns on the same hop `pnpm
// dev` does — the api's prefixes and the gateway under the dashboard's
// origin — so the cookie belongs to ONE host.
//
// OFF unless a deployment asks for it: the compose stack and the Helm chart
// serve the api on the same hostname (ports differ, cookies do not care).
const singleOriginProxy = process.env.ONECLI_SINGLE_ORIGIN_PROXY === "1";

/** @type {import('next').NextConfig} */
const nextConfig = {
  output: "standalone",
  poweredByHeader: false,
  // Cloud edition: the edge in front of it compresses. Onprem prod: Next.js
  // compresses.
  // Dev: OFF — the dev server's gzip middleware buffers proxied responses, and
  // the single-origin rewrites now carry the conversation SSE stream and the
  // approvals long-poll through it; compressing those would stall live chat
  // until the stream ended. Dev has no bandwidth concern to trade for it.
  compress: !isCloud && !isDev,
  serverExternalPackages: ["@onecli/db", "@1password/sdk"],
  env: {
    // One codebase, two editions selected at runtime: `cloud` (the hosted
    // platform) or `onprem` (self-hosted — the default). No build-time module
    // swapping: code branches on the CAPS/IS_CLOUD capability layer instead.
    NEXT_PUBLIC_EDITION: process.env.NEXT_PUBLIC_EDITION || "onprem",
    NEXT_PUBLIC_APP_VERSION: appVersion,
    // Baked ONLY when a value was actually provided — full URLs first (what
    // CI passes), the bare-domain vars as a DEPRECATED fallback for
    // older build invocations. LEGACY(next-major): delete the fallback here
    // and the API_DOMAIN/GATEWAY_API_DOMAIN rows in turbo.json together
    // (ledger: packages/api/src/lib/public-origins.ts).
    //
    // No localhost fallback here, deliberately: an env{} key is INLINED into
    // the SERVER bundle too, where a baked localhost would read as a
    // configured override and beat the resolver's runtime derivation (the
    // prebuilt self-host image would advertise localhost regardless of
    // ONECLI_EXTERNAL_URL). Left un-baked, the server reads runtime env and
    // the browser bottoms out at the resolver's identical code default.
    ...(process.env.NEXT_PUBLIC_API_URL || process.env.API_DOMAIN
      ? {
          NEXT_PUBLIC_API_URL:
            process.env.NEXT_PUBLIC_API_URL ||
            `${isCloud && process.env.NODE_ENV !== "development" ? "https" : "http"}://${process.env.API_DOMAIN}`,
        }
      : {}),
    ...(process.env.NEXT_PUBLIC_GATEWAY_API_URL ||
    process.env.GATEWAY_API_DOMAIN
      ? {
          NEXT_PUBLIC_GATEWAY_API_URL:
            process.env.NEXT_PUBLIC_GATEWAY_API_URL ||
            `${isCloud && process.env.NODE_ENV !== "development" ? "https" : "http"}://${process.env.GATEWAY_API_DOMAIN}`,
        }
      : {}),
  },
  // `redirects()` carries MOVED routes only — never retired ones. The legacy
  // Rules page and the policyMode toggle still 404 like any other removed
  // route, because there is nowhere left to send them.
  //
  // The /p/ → /w/ rules exist only for the project→workspace rename
  // (temporary — remove with the compat layer, see
  // packages/api/src/lib/legacy-project-compat.ts): ids survived the rename
  // migration verbatim, so old /p/ deep links map 1:1 onto /w/.
  redirects: async () => [
    // Every pre-rename deep link ever delivered (bookmarks, Slack approval
    // notifications, gateway-minted connect URLs). Permanent: /p/ is never
    // coming back, so a cached 308 stays correct even after this rule goes.
    // `:path+` (not `*`): a bare /p never existed, so it stays a plain 404
    // instead of a permanently-cached redirect to an equally-bare /w.
    { source: "/p/:path+", destination: "/w/:path+", permanent: true },
    // The docs' two hardcoded pre-org dashboard links.
    { source: "/projects", destination: "/", permanent: false },
    // The retired invite-your-team step's slot MOVED into the create step's
    // boot screen. /onboarding resumes by saved progress, so a mid-flow
    // refresh (or stale tab) lands on the right step instead of a 404
    // in the middle of first-run. Non-permanent: onboarding's shape is
    // the least settled surface we have.
    {
      source: "/onboarding/team",
      destination: "/onboarding",
      permanent: false,
    },
    // Install did not retire, it moved under Workspace Settings, and the
    // setup one-liner it shows is exactly the kind of page people bookmark
    // and paste to a teammate. Permanent, because the move is.
    {
      source: "/w/:workspaceId/install",
      destination: "/w/:workspaceId/settings/install",
      permanent: true,
    },
    // Org-wide administration moved under Organization Settings. Whole
    // subtrees, so every deep link (a Global Connections tab, an app's page)
    // keeps landing, not just the section root. Non-permanent: the settings
    // layout is still settling, and a cached 308 would outlive a second move.
    {
      source: "/org/:orgId/global-connections/:path*",
      destination: "/org/:orgId/settings/global-connections/:path*",
      permanent: false,
    },
    {
      source: "/org/:orgId/policy",
      destination: "/org/:orgId/settings/policy",
      permanent: false,
    },
    // Domains folded into the Single sign-on page (its step 1).
    {
      source: "/org/:orgId/settings/domains",
      destination: "/org/:orgId/settings/sso",
      permanent: false,
    },
  ],
  //
  // `rewrites()` exists for exactly one reason: to serve the whole stack on
  // a SINGLE ORIGIN. better-auth issues the session cookie for the host
  // that answered, and browsers scope cookies by host — so in dev, where the
  // dashboard (:10254), api-server (:10256) and gateway (:10255) are separate
  // processes, one tunnel (ngrok, Cloudflare Tunnel) in front of any single
  // port could never carry a session. Proxying the API's prefixes and the
  // gateway under the dev server's own origin means one tunnel to :10254
  // serves the whole product, and the cookie is always same-origin.
  //
  // The same hop, in production, for deployments whose hosts share no
  // registrable domain (Railway's random `*.up.railway.app` domains) —
  // opt-in via ONECLI_SINGLE_ORIGIN_PROXY=1, see `singleOriginProxy` above.
  //
  // `afterFiles`, never `beforeFiles`: the filesystem router must win first,
  // or these would shadow the dashboard's own `/auth/login`, `/auth/signup`,
  // `/auth/cli` pages and the `/v1/health` deploy probe. `/gw` is a stripped
  // prefix of our own invention — the gateway's browser routes live under
  // `/v1/*` too, so they'd collide with the api-server's without one. For the
  // cloud-dev tunnel, set BOTH baked vars at dev-server start —
  // NEXT_PUBLIC_API_URL=<tunnel-origin> and
  // NEXT_PUBLIC_GATEWAY_API_URL=<tunnel-origin>/gw — since cloud skips the
  // runtime origin injection onprem gets; these rewrites then carry both legs.
  rewrites:
    !isDev && !singleOriginProxy
      ? undefined
      : async () => ({
          afterFiles: [
            { source: "/v1/:path*", destination: `${apiUpstream}/v1/:path*` },
            {
              source: "/auth/:path*",
              destination: `${apiUpstream}/auth/:path*`,
            },
            { source: "/gw/:path*", destination: `${gatewayUpstream}/:path*` },
          ],
        }),
  // The proxy above holds long-lived responses open — the approvals long-poll
  // sits silent for ~30s and the conversation stream is an indefinite SSE.
  // Next's proxy defaults to a 30s timeout, which would clip both; this is an
  // inactivity timeout, so heartbeat-bearing streams live indefinitely under
  // it. Inert outside dev (no rewrites exist to proxy).
  experimental: {
    proxyTimeout: 120_000,
  },
};

export default nextConfig;
