# Railway deployment for OneCLI

Railway **does not run `docker/docker-compose.yml` as a Compose stack**. It
cannot create all Compose services, profiles, networks, volumes, and startup
ordering from that file. Instead, create a Railway service for each supported
long-running container and select its config below. Set the repository Root
Directory to `/` for each Dockerfile build; these Dockerfiles need the full
repository context.

The raw self-host path in [`docs/self-hosting.md`](../docs/self-hosting.md)
remains the full-stack option: run `docker compose up -d --wait` on a Docker
host you control. Railway cannot supply the host Docker socket or the internal
fenced sandbox network required by the hosted runner.

## Container mapping

| Compose service/image | Railway config | Deploy as a Railway service? | Details |
| --- | --- | --- | --- |
| `postgres` | Railway PostgreSQL plugin/service | Yes, managed database | Reference its `DATABASE_URL` from web, API, gateway, and migration job. |
| `migrations` | `/railway/migrations.json` | One-off job only | Run successfully against the same DB before API releases; don't leave it running as a web service. |
| `api` | `/railway/api.json` | Yes | Dockerfile `docker/api.Dockerfile`, port `10256`, health `/v1/health`. |
| `web` | `/railway.json` | Yes | Dockerfile `docker/web.Dockerfile`, port `10254`, health `/healthz`; `DATABASE_URL` is required at runtime. The image starts standalone Next.js itself—do not override with `next start`. |
| `gateway` | `/railway/gateway.json` | Conditional | Dockerfile `docker/gateway.Dockerfile`, raw TCP `10255`, persistent volume `/app/data`. Requires Railway TCP exposure; HTTP domain alone is insufficient. |
| `channel-adapter` | `/railway/channel-adapter.json` | Optional | Dockerfile `docker/channel-adapter.Dockerfile`; enable only when Slack is configured. |
| `runner` | `/railway/runner.json` | **No, not on Railway** | Dockerfile `docker/runner.Dockerfile` is supplied for building the image, but runtime needs `/var/run/docker.sock` and an isolated sandbox network. Run on a Docker host you control or use the documented Kubernetes install. |
| `ssh-terminator` | `/railway/ssh-terminator.json` | **No, Docker backend not on Railway** | Dockerfile `docker/ssh-terminator.Dockerfile` needs the local Docker socket and raw SSH TCP. Run with the self-host Docker setup or supported Kubernetes backend. |
| Agent sandbox base image | `/railway/agent-base.json` | Image build only | Not a long-running container. Build/publish before the agent image. |
| Agent sandbox image | `/railway/agent.json` | Image build only | Not a long-running container. The runner starts this per sandbox; build with `AGENT_BASE_IMAGE` referencing the published base image. |
| `redis` | None for default self-host | Usually not needed | Compose's Redis is cloud-development support; don't set `REDIS_HOST` for an unlicensed self-host. |

Railway private networking replaces Compose's ordinary service-to-service
network for the Railway services, but it does not recreate the Compose `onecli`
and `sandboxes` networks or `depends_on`. Set Railway variables and private
hostnames manually. Keep one gateway instance unless licensed Redis-backed HA
is configured.

## Deploy order and required variables

1. Create Railway PostgreSQL. Reference its `DATABASE_URL` on **web, API,
gateway, and the migration job**. The web service needs this at runtime because
server-rendered dashboard pages use Prisma; build-time configuration alone is
not enough.
2. Add API, web, and gateway services using their config paths above. Configure
private addresses for API↔gateway↔web communication. Set public URLs and TCP
routing as required. The Dockerfiles use ports `10256` (API), `10254` (web),
and `10255` (gateway); set compatible `PORT` values where the service reads
that variable.
3. Run the migrations image as a one-off job before rolling out API changes.
Compose's migration ordering does not carry over to Railway. If the Railway
workflow cannot run a one-off image, use a controlled CI/deployment job with
the Railway database reference and gate API rollout on its exit status.
4. Add the channel adapter only if used; set its `CHANNEL_ADAPTER_TOKEN` equal
to the value configured on the API.
5. For hosted agents, build and publish the base then agent image, and run the
Docker-backend runner and SSH terminator on a Docker host you control. Never
expose the Docker socket over a network.

Generate secrets locally (the repository script prints values but does not
write Railway variables):

```sh
node scripts/railway-secrets.mjs
```

Store the output securely and reuse the same values across redeploys. Never
regenerate `SECRET_ENCRYPTION_KEY` after storing encrypted credentials.

- `SECRET_ENCRYPTION_KEY`: web, API, gateway.
- `GATEWAY_INTERNAL_SECRET`: API and gateway.
- `BETTER_AUTH_SECRET`: web and API.
- `RUNNER_TOKEN`: API and external runner (same value), if using hosted agents.
- `RUNNER_SESSION_KEY`: external runner, if using session resumption.
- `CHANNEL_ADAPTER_TOKEN`: API and channel adapter (same value), if enabled.
- SSH operation also requires `SSH_CA_PRIVATE_KEY`,
  `TERMINATOR_CA_PUBLIC_KEY`, `TERMINATOR_HOST_KEY`, and `SSH_TERMINATOR_SECRET`;
  use the project's setup to generate the coupled key material.

Set `ONECLI_EXTERNAL_URL` to the public dashboard URL on web, API, and gateway;
`API_URL` to the public API origin; `GATEWAY_API_URL` and
`ONECLI_AGENT_PROXY_ADDRESS` to the gateway addresses reachable by clients and
agent sandboxes. Set `API_INTERNAL_URL` and `INTERNAL_API_URL` to the API's
Railway private hostname as appropriate, and `GATEWAY_INTERNAL_URL` on web and
API to the gateway private hostname. Confirm actual Railway hostnames and ports
in your project; Compose service names such as `api` and `gateway` are not
necessarily Railway hostnames.

## Full-stack limitation

These configs let Railway build images from the repository's Dockerfiles and
run supported components individually. They do **not** make Railway execute
Compose. In particular, standard Railway services cannot run OneCLI's Docker
runner because they do not get `/var/run/docker.sock` or the Compose sandbox
isolation. For a full hosted-agent deployment use Docker Compose on a compatible
host or the supported Kubernetes installation in the self-hosting guide.
