import {
  defineRailway,
  github,
  postgres,
  project,
  service,
  volume,
} from "railway/iac";

// Railway deployment of the OneCLI stack, built from the `tango` branch of
// bkg-zig/bkg-cli with the repository's own Dockerfiles (docker/*.Dockerfile).
//
// Variables are unmanaged on purpose: the shared secrets (BETTER_AUTH_SECRET,
// SECRET_ENCRYPTION_KEY, GATEWAY_INTERNAL_SECRET) already exist in the
// Railway project and must never be regenerated — a fresh
// SECRET_ENCRYPTION_KEY would orphan every encrypted credential in the
// database. scripts/deploy-railway.sh owns the variables and the deploy
// order; this file owns the topology (services, sources, builds, networking,
// volumes, database).
export default defineRailway(() => {
  const Postgres = postgres("Postgres", { region: "sfo" });
  Postgres.networking = { privateNetworkEndpoint: "postgres" };

  const gatewayVolume = volume("gateway-volume", {
    alerts: { usage: { "100": {}, "80": {}, "95": {} } },
    allowOnlineResize: true,
    region: "sfo",
    sizeMB: 5000,
  });
  const postgresVolume = volume("postgres-volume", {
    alerts: { usage: { "100": {}, "80": {}, "95": {} } },
    allowOnlineResize: true,
    region: "sfo",
    sizeMB: 5000,
  });

  // One-off job: runs the Prisma migrations and exits. Railway must not
  // restart it — a failed migration has to surface as a failed deployment.
  const migrations = service("migrations", {
    source: github("bkg-zig/bkg-cli", { branch: "tango", checkSuites: false }),
    build: {
      buildEnvironment: "V3",
      builder: "DOCKERFILE",
      dockerfilePath: "docker/migrations.Dockerfile",
    },
    deploy: { restartPolicyType: "NEVER" },
    replicas: { sfo: 1 },
  });

  const api = service("api", {
    source: github("bkg-zig/bkg-cli", { branch: "tango", checkSuites: false }),
    build: {
      buildEnvironment: "V3",
      builder: "DOCKERFILE",
      dockerfilePath: "docker/api.Dockerfile",
    },
    healthcheck: "/v1/health",
    replicas: { sfo: 1 },
    networking: {
      serviceDomains: {
        "api-production-f27ca.up.railway.app": { port: 10256 },
      },
    },
  });

  // The dashboard. The image serves the Next.js standalone server on 10254
  // (docker/web.Dockerfile), so the domain points at that port.
  const web = service("bkg-one-cli", {
    source: github("bkg-zig/bkg-cli", { branch: "tango", checkSuites: false }),
    build: {
      buildEnvironment: "V3",
      builder: "DOCKERFILE",
      dockerfilePath: "docker/web.Dockerfile",
    },
    healthcheck: "/healthz",
    start: "",
    replicas: { sfo: 1 },
    networking: {
      serviceDomains: {
        "bkg-one-cli-production.up.railway.app": { port: 10254 },
      },
    },
  });

  // The MITM gateway. It keeps the CA in /app/data (Railway volume) and is
  // reachable over plain HTTP on 10255 — Railway's edge terminates TLS.
  const gateway = service("gateway", {
    source: github("bkg-zig/bkg-cli", { branch: "tango", checkSuites: false }),
    build: {
      buildEnvironment: "V3",
      builder: "DOCKERFILE",
      dockerfilePath: "docker/gateway.Dockerfile",
    },
    healthcheck: "/healthz",
    replicas: { sfo: 1 },
    networking: {
      serviceDomains: {
        "gateway-production-b061.up.railway.app": { port: 10255 },
      },
      tcpProxies: { "10255": {} },
    },
    volumeMounts: { "/app/data": gatewayVolume },
  });

  return project("magnificent-reflection", {
    variables: { managed: false },
    resources: [
      migrations,
      api,
      web,
      gateway,
      Postgres,
      gatewayVolume,
      postgresVolume,
    ],
  });
});
