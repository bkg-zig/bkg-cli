# Railway + Railpack deployment

This repository is a monorepo, not a single web process. Deploy the dashboard,
API, gateway, and (optionally) channel adapter as separate Railway services. The
service configs in this directory use Railpack; `railway.json` configures the
web service. Attach the same GitHub repository to each service and set its
configuration file path as listed below.

## Services

Create a Railway PostgreSQL service first. For the Node services, set the Root
Directory to `/` so Railpack can see the pnpm workspace and lockfile.

| Service | Config file | Root directory | Notes |
| --- | --- | --- | --- |
| Web dashboard | `/railway.json` | `/` | Public HTTP domain; health check is `/healthz`. |
| API server | `/railway/api.json` | `/` | Public HTTP domain; applies Prisma migrations before starting. Keep one replica while using this start-time migration. |
| Gateway | `/railway/gateway.json` | `/apps/gateway` | Add a persistent Railway volume mounted at `/app/data` to retain its generated CA and state. Set up a TCP proxy for agent CONNECT traffic; the gateway is not just an HTTP web server. |
| Channel adapter | `/railway/channel-adapter.json` | `/` | Optional; enable only when configuring Slack. |

Configure each service's **Config-as-code file path** in Railway service settings.
The gateway root directory is intentionally different: its Cargo workspace is
self-contained under `apps/gateway`.

## Environment and networking

Provision PostgreSQL and use its Railway `DATABASE_URL` reference on the API,
web, and gateway services. Do not commit generated credentials or put them in
the repository. Generate the app's initial random keys on your own machine:

```sh
node scripts/railway-secrets.mjs
```

Copy the output into Railway's service variables, sharing each key only with
the services that need it:

- `BETTER_AUTH_SECRET`: web and API (same value).
- `SECRET_ENCRYPTION_KEY`: web, API, and gateway (same value). Back it up securely; replacing it makes previously stored credentials unreadable.
- `GATEWAY_INTERNAL_SECRET`: API and gateway (same value).
- `RUNNER_TOKEN` and `RUNNER_SESSION_KEY`: only if registering an external runner; see the limitation below.
- `CHANNEL_ADAPTER_TOKEN`: API and channel-adapter (same value) when enabling that service.

The generator does not create Railway variables or persist values. Run it once
for an installation, retain the values in your password manager, and reuse
them for redeploys. Never regenerate `SECRET_ENCRYPTION_KEY` for an installation
that already contains encrypted credentials.

Set `ONECLI_EXTERNAL_URL` to the public dashboard URL on web, API, and gateway.
Set `API_URL` to the API's public HTTPS URL on web and API. Set
`GATEWAY_API_URL` to the gateway address reachable by the dashboard and users;
set `ONECLI_AGENT_PROXY_ADDRESS` to the gateway TCP-proxy host and port that
agent containers can reach. For service-to-service traffic, use Railway private
hostnames, for example `http://api.railway.internal:10256` for
`INTERNAL_API_URL` on the gateway and `API_INTERNAL_URL` on web. Verify the
actual service names and ports in your Railway project before using these
examples. Set `PORT` to the service's listening port if Railway does not provide
one automatically.

The API service needs the generated `BETTER_AUTH_SECRET`,
`SECRET_ENCRYPTION_KEY`, and `GATEWAY_INTERNAL_SECRET`. The gateway needs the
same `SECRET_ENCRYPTION_KEY` and `GATEWAY_INTERNAL_SECRET`. The web service
needs the same auth and encryption keys. Ensure the API and gateway can reach
each other over Railway's private network.

## Important hosted-agent limitation

Railway services do not provide this app's runner with the host Docker socket
and isolated sandbox-network controls required by `apps/runner`. The runner and
SSH terminator Docker deployment in `docker/docker-compose.yml` therefore
cannot be made equivalent by selecting Railpack or by deploying them as ordinary
Railway services. This setup deploys the dashboard/API/gateway control plane;
for hosted agent sandboxes, run the runner on a Docker host you control and
register it with the same `RUNNER_TOKEN` (and `RUNNER_SESSION_KEY`) configured
on the API. Do not expose the Docker socket over the network.

The gateway also handles raw TCP CONNECT proxy traffic. A Railway HTTP domain
alone is not sufficient for agent egress; configure and test Railway TCP
proxying and persistent storage before treating the deployment as production
ready. If your Railway plan/network setup cannot provide the required TCP
routing, run the gateway on infrastructure that can.
