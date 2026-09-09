# ompweb-docker

Containerized packaging of **[oh-my-pi](https://github.com/can1357/oh-my-pi)** (the `omp` CLI, an AI coding agent by can1357) and **[ompweb](https://github.com/kahme247/ompweb)** (the matching web UI by kahme247), bundled into a single Docker image and auto-published to GitHub Container Registry on every push.

Use this instead of running `omp` on bare metal. State lives in a Docker volume; upgrades are a `docker compose pull`.

---

## Why a wrapper repo?

The upstream `ompweb` repo has **no Docker artifacts at all** — it's distributed only via `npm install -g @kahme247/ompweb`. This wrapper repo contains just the Docker infrastructure (Dockerfile, compose, workflow, docs) and pulls both upstream projects at image build time.

| Component | Upstream | License |
|---|---|---|
| Web UI | <https://github.com/kahme247/ompweb> | MIT |
| Agent CLI | <https://github.com/can1357/oh-my-pi> | (see repo) |
| This wrapper | — | MIT |

---

## Quick start

Requires Docker 24+ and Compose v2.

```sh
# 1. Get the wrapper files
git clone https://github.com/<you>/ompweb-docker.git
cd ompweb-docker

# 2. Configure
cp .env.example .env
$EDITOR .env            # set OMP_WEB_PASSWORD at minimum

# 3. Run
docker compose pull
docker compose up -d

# 4. Open http://localhost:30177
```

The first run pulls the image from `ghcr.io/<owner>/ompweb:latest`. Use `docker compose logs -f ompweb` to watch Next.js boot.

---

## Image tags

The workflow in `.github/workflows/docker.yml` produces:

| Event | Tags pushed |
|---|---|
| Push to `main` | `main`, `main-<sha>`, `latest` |
| Tag `v1.2.3` | `1.2.3`, `1.2`, `1`, `v1.2.3` (and `latest` if this is the newest release) |
| Pull request | *(no push — build only, image is discarded)* |
| Manual dispatch | tags for the current ref |

Pin to a specific tag for reproducibility:

```yaml
# docker-compose.yml
image: ghcr.io/<owner>/ompweb:v18.1.15-ompweb-main
```

---

## Persistent data

The container stores two kinds of state:

| What | Where | How to persist |
|---|---|---|
| omp config, models, MCP servers, session index | `/data/omp` (mapped to `~/.omp/agent`) | Named volume `ompweb_data` (default) |
| Project session JSONLs, project memory | The cwd being worked on | Bind-mount your source code (`./workspace:/workspace`) |

By default only `ompweb_data` is mounted. To let `omp` actually edit your code, uncomment the workspace line in `docker-compose.yml` and set `WORKSPACE_DIR` in `.env` to the directory you want to work on. In the ompweb UI, set the project cwd to `/workspace/<your-project>`.

### Backups

```sh
docker run --rm \
  -v ompweb_data:/data \
  -v "$PWD":/backup \
  alpine tar czf /backup/ompweb-data.tgz -C / data
```

### Restore

```sh
docker run --rm \
  -v ompweb_data:/data \
  -v "$PWD":/backup \
  alpine tar xzf /backup/ompweb-data.tgz -C /
```

---

## Exposing to the internet

Do **not** put this container directly on a public IP — `OMP_WEB_PASSWORD` is the only auth, and there is no rate limiting. Always front it with a reverse proxy.

### Caddy (recommended — automatic HTTPS)

```sh
# 1. Edit Caddyfile, replace ompweb.example.com with your domain
cp Caddyfile /etc/caddy/Caddyfile.d/ompweb.caddy
$EDITOR /etc/caddy/Caddyfile.d/ompweb.caddy

# 2. Include it from your main Caddyfile:
echo "import Caddyfile.d/*.caddy" >> /etc/caddy/Caddyfile

# 3. Reload
systemctl reload caddy
```

A sample `Caddyfile` for this repo shows the right headers (`X-Forwarded-*`, `X-Real-IP`) so ompweb sees the real client IP through the proxy.

### nginx

```nginx
server {
    listen 443 ssl http2;
    server_name ompweb.example.com;

    ssl_certificate     /etc/letsencrypt/live/ompweb.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/ompweb.example.com/privkey.pem;

    client_max_body_size 50m;
    proxy_read_timeout   3600s;
    proxy_send_timeout   3600s;

    location / {
        proxy_pass         http://127.0.0.1:30177;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
    }
}
```

---

## Updating

```sh
docker compose pull
docker compose up -d
```

The CI rebuilds on every push to `main` and pushes `latest`. Tagged releases (`vX.Y.Z`) push immutable semver tags.

To force a rebuild with a pinned version of `omp` (instead of `latest`):

```sh
docker build --build-arg OMP_VERSION=18.1.15 --build-arg OMPWEB_REF=main -t ompweb:custom .
docker compose up -d   # if your compose points at this local tag
```

---

## Architecture

```
┌──────────────────────────────────────────────────┐
│ Container (ghcr.io/<owner>/ompweb)               │
│                                                  │
│  ENTRYPOINT: tini → docker-entrypoint.sh         │
│      └─ validates OMP_WEB_PASSWORD (if LAN bind) │
│      └─ mkdir -p $PI_CODING_AGENT_DIR            │
│      └─ exec node bin/omp-web.js                 │
│              ├─ listens on 0.0.0.0:30177         │
│              └─ spawns `omp --mode rpc-ui`       │
│                 (NDJSON over stdio, per session) │
│                                                  │
│  /              rootfs (node:26-slim, Debian)    │
│  /app           ompweb Next.js app               │
│  /usr/local/bin/omp  static omp binary (glibc)   │
│  /data          persistent volume                │
│      └─ omp/   → ~/.omp/agent  (config, etc.)    │
│  /workspace     bind-mounted from host           │
└──────────────────────────────────────────────────┘
```

### Why bundle both?

`ompweb` does not embed `omp`. It locates the `omp` binary via `OMP_WEB_OMP_BIN` (or `$PATH`) and spawns it with `--mode rpc-ui`, exchanging **NDJSON frames over stdio**. There is no HTTP server in `omp`. So the two must run together, and the simplest deployment is one container.

### Why Debian slim?

We use `node:26-slim` (Debian Bookworm, glibc) rather than Alpine for two reasons:

1. **Current Node** — `node:26-slim` tracks the latest 26.x release, which is what users coming to this project expect in 2026.
2. **glibc-compatible omp binary** — `oh-my-pi` ships a glibc `omp-linux-x64` binary that runs cleanly on Debian with no extra runtime needed (no Bun, no musl loader).

The size penalty vs Alpine (~80MB base vs ~50MB) is small compared to the bundled Next.js build and omp binary (~150MB). To pin a specific Node patch, build with `--build-arg NODE_VERSION=26.8.1-slim`.

### Why not `output: 'standalone'` for Next.js?

ompweb doesn't enable `output: 'standalone'` upstream. Adding it would require either forking or carrying a tiny patch. `npm prune --omit=dev` in the build stage already strips devDependencies, which is the biggest size win without forking. A future optimization (~120MB instead of ~250MB) is documented as a follow-up.

---

## Security notes

- **`OMP_WEB_PASSWORD` is the only authentication boundary.** Pick something strong; don't reuse another service's password.
- The container runs as **UID 1001** (non-root), with `cap_drop: [ALL]` and `no-new-privileges`. Subprocess `omp` runs as the same user.
- The `ompweb_data` volume is the only place persistent state lives. Back it up regularly.
- API keys are passed via environment variables — never bake them into the image. See `.env.example`.
- The image is scanned by **Trivy** on every build; results surface in the Actions run summary.

---

## Troubleshooting

### "OMP_WEB_PASSWORD must be set when OMP_WEB_HOSTNAME is not 127.0.0.1"

You bound the container to `0.0.0.0` but didn't set a password. Either set `OMP_WEB_PASSWORD` in `.env`, or bind to localhost only (`OMP_WEB_HOSTNAME=127.0.0.1`) and access via a reverse proxy.

### Container is healthy but the UI is blank

`docker compose logs ompweb`. If you see `bind: address already in use`, something else is on port 30177. Change `ports:` in `docker-compose.yml` or stop the conflicting process.

### "omp: command not found" inside the container

The `omp` binary lives at `/usr/local/bin/omp` and is set as `OMP_WEB_OMP_BIN` in the Dockerfile. If you've mounted over `/usr/local/bin`, you've hidden it. Remove the override.

### Image build fails resolving "latest"

The Docker build stage calls `api.github.com` for the latest `omp` release. If GitHub rate-limits you (60/hr unauthenticated), pin a version explicitly: `--build-arg OMP_VERSION=18.1.15`.

### I want a different version of ompweb

```sh
docker build --build-arg OMPWEB_REF=v0.4.2 -t ompweb:custom .
```

Where `v0.4.2` is any tag/branch from <https://github.com/kahme247/ompweb/tags>.

---

## Development

### Build locally

```sh
docker build --build-arg OMPWEB_REF=main -t ompweb:dev .
docker run --rm ompweb:dev omp --version    # sanity check
```

### Run with a local compose override

```sh
docker compose -f docker-compose.yml -f docker-compose.override.yml up -d
```

A typical override might point at a locally-built image:

```yaml
# docker-compose.override.yml
services:
  ompweb:
    image: ompweb:dev
    build: .
```

### Lint the workflow / Dockerfile

```sh
# Docker
docker run --rm -i hadolint/hadolint < Dockerfile

# GitHub Actions
actionlint .github/workflows/docker.yml
```

---

## License

MIT for the wrapper files in this repo. See upstream projects for their own licenses.