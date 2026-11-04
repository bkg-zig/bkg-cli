# Railway deployment for OneCLI's Docker-based self-host stack

I read [`docs/self-hosting.md`](../docs/self-hosting.md). Its raw Compose setup
creates `docker/.env` with random `SECRET_ENCRYPTION_KEY`,
`GATEWAY_INTERNAL_SECRET`, and `BETTER_AUTH_SECRET`, sets
`COMPOSE_PROFILES=runner`, then runs `docker compose up -d --wait` from the
`docker/` directory.

Railway does **not** run that Compose command or consume `docker/.env`. Create
one Railway service per long-running container, use the Dockerfile configs
below, and add the environment variables separately in Railway. All Dockerfiles
expect the repository root as the build context, so set each service's Root
Directory to `/` and configure the specified Config-as-code file path.

## Dockerfiles and Railway configs

| Compose service / image | Railway config file | Dockerfile | Deployment guidance |
| --- | --- | --- | --- |
| `web` | `/railway.json` | `docker/web.Dockerfile` | Long-running dashboard; public domain, port `10254`, health `/healthz`. |
| `api` | `/railway/api.json` | `docker/api.Dockerfile` | Long-running API; port `10256`, health `/v1/health`. |
| `gateway` | `/railway/gateway.json` | `docker/gateway.Dockerfile` | Long-running raw TCP CONNECT proxy; port `10255`, persistent volume at `/app/data`. HTTP domain alone is not enough. |
| `channel-adapter` | `/railway/channel-adapter.json` | `docker/channel-adapter.Dockerfile` | Optional outbound Slack worker; no public port. |
| `migrations` | `/railway/migrations.json` | `docker/migrations.Dockerfile` | One-shot job, not an always-on server. Run against the same Postgres before the API rollout. |
| `runner` | `/railway/runner.json` | `docker/runner.Dockerfile` | Build config only: a normal Railway service cannot provide the local Docker socket and fenced sandbox network this runner requires. Run it on a Docker host you control. |
| `ssh-terminator` | `/railway/ssh-terminator.json` | `docker/ssh-terminator.Dockerfile` | Build config only for Docker mode: requires Docker socket and raw SSH TCP. Run with the self-host Docker setup or supported Kubernetes backend, not as an ordinary Railway service. |
| Agent sandbox base image | `/railway/agent-base.json` | `docker/agent-base.Dockerfile` | Image build only; not a long-running Railway service. |
| Agent sandbox image | `/railway/agent.json` | `docker/agent.Dockerfile` | Image build only; requires `AGENT_BASE_IMAGE` to reference the built base image. The external runner launches it per sandbox. |
| `postgres` | — | `postgres:18-alpine` in Compose | Use Railway PostgreSQL and reference its `DATABASE_URL`; don't create a second app container for it. |
| `redis` | — | `redis:7-alpine` in dev Compose only | Not needed for the unlicensed single-instance self-host. Cloud mode has additional requirements; Redis alone does not configure cloud mode. |

The `railway/*.json` Docker build paths use the same Dockerfiles as the
self-hosted Compose stack. Keep the Root Directory `/` even for the Rust
gateway: its Dockerfile builds from the full repository context.

The web config uses the repository's Dockerfile, which starts Next.js in
standalone mode (`node apps/web/server.js`). Do not override it with `next
start`: this app sets `output: "standalone"`, and Next.js warns that `next
start` is unsupported for that output mode.

## Railway setup

1. Create Railway PostgreSQL. Provide its `DATABASE_URL` to the API, web,
gateway, and the migration job. **The web service needs this at runtime too**:
its server-rendered account/dashboard code uses Prisma. Supplying the URL only
to the API, or only during the web image build, is insufficient. In the web
service's Railway Variables, add `DATABASE_URL` as a reference to the PostgreSQL
service's `DATABASE_URL` (select the actual database service name in Railway).
2. Add the Railway services for web, API, and gateway, using the configs above.
Set ports to `10254`, `10256`, and `10255` respectively if Railway does not
supply compatible `PORT` values. The API image reads `PORT`; gateway needs
`--port 10255` and a matching Railway TCP listener.
3. Run the migrations image as a one-off job against the same database before
releasing API changes. The Compose stack orders this automatically; separate
Railway services do not. Don't start a migration process as a continuously
restarting web service or run it concurrently from every API replica.
4. Add the optional channel-adapter only if Slack is configured.
5. Build/publish the agent base image, then the agent image with
`AGENT_BASE_IMAGE` pointing at the published base. Configure the external
runner's `RUNNER_AGENT_IMAGE` to that published image.

If your Railway plan/workflow cannot run the migrations image as a one-off job,
run it from a controlled CI/deployment job with Railway's `DATABASE_URL` and
block the API rollout until it exits successfully.

## Secrets and settings

The three values in the self-hosting raw Compose example are the required base
secrets. Generate them locally (don't commit them), or run the repo's generator
for the additional optional service tokens too:

```sh
node scripts/railway-secrets.mjs
```

The generator prints random values to your terminal. It does not configure
Railway or save the values. Put the **same value** on each listed service, and
keep the values unchanged for redeploys:

- `SECRET_ENCRYPTION_KEY`: web, API, and gateway. Back this up securely; losing
  or replacing it makes previously encrypted credentials unreadable.
- `GATEWAY_INTERNAL_SECRET`: API and gateway.
- `BETTER_AUTH_SECRET`: web and API (also gateway as passed through by Compose).
- `RUNNER_TOKEN`: API and the external runner, same value. Required if you
  actually enable hosted agents; the short raw Compose example's
  `COMPOSE_PROFILES=runner` does not itself generate this token.
- `RUNNER_SESSION_KEY`: external runner, when using session resumption.
- `CHANNEL_ADAPTER_TOKEN`: API and channel-adapter when enabled.

Set `ONECLI_EXTERNAL_URL` to the public dashboard URL on web, API, and gateway.
Set `API_URL` to the API's public HTTPS URL. Set `GATEWAY_API_URL` and
`ONECLI_AGENT_PROXY_ADDRESS` to the gateway addresses reachable by the
browser and agent sandboxes. Set `INTERNAL_API_URL` for the gateway and
`API_INTERNAL_URL` for web to the API's Railway private hostname. Set
`GATEWAY_INTERNAL_URL` on web and API to the gateway private hostname. Verify
actual Railway private hostnames and ports in your project; the Compose service
names `api` and `gateway` won't necessarily be Railway hostnames.

Railway services don't inherit `COMPOSE_PROFILES`; in this split-service setup
add `runner` and `channel-adapter` as separate services only if their runtime
requirements can be met. `COMPOSE_PROFILES=runner` is a Docker Compose setting,
not a Railway variable that starts a Compose profile.

## Limits compared with the self-host Docker Compose stack

Railway service configs build and run the Dockerfiles; they do not reproduce the
whole Compose topology. In particular, standard Railway services do not mount
the host's `/var/run/docker.sock`, create the private internal sandbox network,
or automatically wire service dependencies and migration ordering. Therefore
the Docker-backend runner and SSH terminator cannot provide hosted sandboxes on
Railway as ordinary services. Run those on a compatible Docker host, or use
the supported Kubernetes deployment described in the self-hosting guide.

The gateway handles raw TCP CONNECT, and the gateway CA/state is kept under
`/app/data`. Before production, verify your Railway TCP proxy configuration
and attach persistent storage there. If TCP forwarding or persistent volumes
aren't available for your Railway setup, run the gateway on infrastructure
that supports them. These constraints mean the Railway configs are not a
one-command replacement for `docker compose up -d --wait`.
