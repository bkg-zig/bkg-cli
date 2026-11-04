# Railway deployment for OneCLI

## Important: Railway does not run `docker/docker-compose.yml`

Railway cannot deploy a Compose file as one coordinated stack. Setting
`railway.json` to a Dockerfile does not make Railway read Compose, apply its
profiles, create its networks, mount its volumes, or honor `depends_on`.
Railway needs a separately configured service for each supported long-running
container. The configuration files in this directory select the matching
Dockerfile; they are **not** a Compose installer or an automatic Railway
project bootstrapper.

The raw self-host path in [`docs/self-hosting.md`](../docs/self-hosting.md)
remains the supported one-command full-stack installation:

```sh
git clone https://github.com/onecli/onecli.git && cd onecli/docker
cat > .env <<EOF
SECRET_ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
GATEWAY_INTERNAL_SECRET=$(head -c 32 /dev/urandom | base64)
BETTER_AUTH_SECRET=$(head -c 32 /dev/urandom | base64)
COMPOSE_PROFILES=runner
EOF
chmod 600 .env
docker compose up -d --wait
```

That Compose command runs on a Docker host you control; running it inside an
ordinary Railway service is not a supported alternative.

## Compose-to-Railway map

For each Railway application service, connect this repository, set the Root
Directory to `/`, and select the Config-as-code file path below. The Dockerfiles
use the repository root as their build context. Create services individually;
Railway will not read this table or create them automatically.

| Compose entry | Railway setup | Config | Required runtime considerations |
| --- | --- | --- | --- |
| `postgres` | Use Railway PostgreSQL; reference its `DATABASE_URL` from web, API, gateway, and migration job. | Managed database, no repo config | Do not use the sample Compose database password `onecli` for a public deployment. |
| `migrations` | Run as a one-off job before deploying/releasing the API. | `/railway/migrations.json` | Must use the same `DATABASE_URL` as the application. Do not run it as an always-on server or concurrently from each API replica. |
| `api` | Long-running Railway service. | `/railway/api.json` | `PORT=10256` if not set by Railway; health path `/v1/health`. |
| `web` | Long-running public dashboard service. | `/railway.json` | **Set `DATABASE_URL` at runtime on this service too.** The server-rendered dashboard uses Prisma. This config's Dockerfile starts Next standalone via `node apps/web/server.js`; do not override it with `next start`. Health path `/healthz`. |
| `gateway` | Long-running service with raw TCP proxy exposure and persistent volume mounted at `/app/data`. | `/railway/gateway.json` | Gateway listens on TCP `10255`; an HTTP domain alone is not the CONNECT proxy. Persist `/app/data` or its generated CA/state is lost on replacement. |
| `runner` | Not deployable as the self-host Docker runner on standard Railway. Run on a Docker host you control, or use the documented Kubernetes install. | `/railway/runner.json` is only a Dockerfile/build description | Compose mounts `/var/run/docker.sock` and relies on a fenced internal sandbox network. Railway does not provide the host Docker socket or Compose network. |
| `ssh-terminator` | Docker backend must run beside the Docker host with the runner; supported Kubernetes setup is another option. | `/railway/ssh-terminator.json` is only a Dockerfile/build description | Compose mounts the Docker socket. Also needs an externally reachable SSH/TCP listener and generated SSH key material. |
| `channel-adapter` | Optional long-running outbound worker; add as a separate Railway service only if Slack is configured. | `/railway/channel-adapter.json` | No public HTTP domain is needed. It needs `CHANNEL_ADAPTER_TOKEN` matching the API and private API/gateway service addresses. |
| Agent sandbox base | Build/publish an image; not a persistent service. | `/railway/agent-base.json` | Required base image for the agent image. |
| Agent sandbox | Build/publish an image; the runner starts one per hosted sandbox. | `/railway/agent.json` | Build after the base image and configure `AGENT_BASE_IMAGE` to its published image. |
| `redis` | Not part of the production Compose self-host default. | No config | The dev Compose file uses Redis for cloud-edition development. Don't enable `REDIS_HOST` on an unlicensed self-host; Redis-backed HA requires the relevant entitlement. |

## Railway setup order

1. Create Railway PostgreSQL. Reference `DATABASE_URL` from it on the **web,
   API, gateway and migration job**. The web service's runtime variable is
   required even though its Docker image uses a dummy database URL only during
   static build steps.
2. Add the API, web and gateway as separate services with the config paths in
the table. Configure Railway private networking for internal calls and add
public domains/TCP exposure only where required. Use service private hostnames
for `API_INTERNAL_URL`, `INTERNAL_API_URL`, `GATEWAY_INTERNAL_URL`, and the
other internal URLs; Compose names like `api` and `gateway` are not guaranteed
to be Railway hostnames.
3. Run the migrations image as a one-off job against the production database
before the API rollout. Compose's migration dependency ordering does not carry
over to Railway. If the Railway workflow cannot run a one-off image, use a
controlled CI/deployment job with the Railway database reference and gate the
API rollout on success.
4. Add the channel adapter only if used. Build and publish the agent base then
the agent image if a compatible external runner will launch it.
5. Run the runner and Docker-backend SSH terminator on a Docker host you
control. Never expose `/var/run/docker.sock` over a network.

## Environment and secrets

The raw Compose example generates the three minimum secrets locally. The
repo's generator can make the required keys plus service tokens:

```sh
node scripts/railway-secrets.mjs
```

It prints values to stdout; it does not create Railway variables or persist
them. Copy each value to Railway's secret variables, keep coupled services on
the same value, and save the output securely for recovery. Never regenerate
`SECRET_ENCRYPTION_KEY` after storing encrypted credentials.

- `SECRET_ENCRYPTION_KEY`: web, API, gateway.
- `GATEWAY_INTERNAL_SECRET`: API and gateway.
- `BETTER_AUTH_SECRET`: web and API.
- `RUNNER_TOKEN`: API and external runner; same value, if using hosted agents.
- `RUNNER_SESSION_KEY`: external runner, if using session resumption.
- `CHANNEL_ADAPTER_TOKEN`: API and channel adapter, same value, if enabled.
- SSH: a working SSH deployment additionally needs the API's `SSH_CA_PRIVATE_KEY`,
  the terminator's `TERMINATOR_CA_PUBLIC_KEY`, `TERMINATOR_HOST_KEY`, and the
  shared `SSH_TERMINATOR_SECRET`. Generate and store those using the supported
  self-host setup; `scripts/railway-secrets.mjs` does not mint SSH key pairs.

Set `ONECLI_EXTERNAL_URL` to the public dashboard URL on web, API, and gateway;
set `API_URL` to the public API origin. Configure `GATEWAY_API_URL` and
`ONECLI_AGENT_PROXY_ADDRESS` to the gateway origins reachable by the dashboard
and agent containers. Set `API_INTERNAL_URL` and `INTERNAL_API_URL` to the API's
private hostname as appropriate, and `GATEWAY_INTERNAL_URL` to the gateway's
private hostname on API and web. Verify actual Railway-generated hostnames and
ports in your project.

## What Railway cannot reproduce from Compose

Railway automatically provides private service networking, but it does not
recreate the Compose-defined `onecli` and `sandboxes` networks, Compose volume
lifecycle, `depends_on` startup ordering, or Compose profiles. Configure
variables, service networking, persistent storage, and migration sequencing
in Railway itself. Most importantly, standard Railway services do not provide
the local Docker socket and isolated network needed by the hosted-agent Docker
runner. Therefore these Dockerfile configs describe/build all of the Compose
images, but **cannot turn the entire Compose application—including hosted
sandbox execution—into a working Railway deployment**. Use Docker Compose on a
Docker-capable host or the project's supported Kubernetes deployment for the
full hosted-agent stack.
