# omp-sandbox

A turnkey container that hosts **[oh-my-pi](https://github.com/can1357/oh-my-pi)** (the `omp` coding-agent engine) and **[ompweb](https://github.com/kahme247/ompweb)** (its web UI) in one image, with persistent state, host-UID alignment, and Docker access for the agent.

The image contains the launcher, the engine, and the UI. At runtime the container starts as root only long enough to remap `PUID`/`PGID`, join the mounted Docker socket's group, chown the volumes, and seed a workspace registry — then drops to the unprivileged `omp` user with `gosu` before any user code runs.

| Component | Upstream | How it gets in the image |
|---|---|---|
| Agent engine | <https://github.com/can1357/oh-my-pi> | `OMP_BUILD=release`: platform release binary. `OMP_BUILD=source`: cloned + built (cargo/napi addon). |
| Web UI | <https://github.com/kahme247/ompweb> | Cloned and built with `next build`, then `npm prune --omit=dev`. |
| This wrapper | — | MIT |

Both upstream sources are selected at build time via `OMP_REPO`/`OMP_REF` and `OMPWEB_REPO`/`OMPWEB_REF`, so a fork or an unreleased ref is one `--build-arg` away.

---

## Quick start

Requires Docker 24+ (or Podman 5+) with Compose v2.

```sh
git clone https://github.com/Heretek-AI/ompweb-docker.git
cd ompweb-docker

cp .env.example .env
$EDITOR .env                                  # set OMP_WEB_PASSWORD at minimum

mkdir -p workspace data/omp data/config data/ssh
chmod 700 data/ssh                            # SSH keys are mounted read-only

docker compose pull
docker compose up -d
# open http://localhost:3000
```

`docker compose logs -f ompweb` shows the entrypoint banner, the engine-version line, and the Next.js boot output.

---

## Volumes

Every state path is a bind mount, so backup is a `tar` over `./data` and your files are visible on the host.

| Container path | Host default | Contents |
|---|---|---|
| `/workspace` | `./workspace` | Your code — the workspace omp edits. |
| `/home/omp/.omp` | `./data/omp` | Agent state: `agent/sessions/`, blobs, `agent/projects.json`, `agent/models.yml`, `agent/config.yml`, `agent.db`, `skills/`, `agents/`. |
| `/home/omp/.config` | `./data/config` | Tool config: `gh` auth, `git/config`. |
| `/home/omp/.ssh` | `./data/ssh` (read-only) | SSH keys for git/remote access. |
| `/var/run/docker.sock` | host socket | Docker CLI access from inside the container. |

Backup and restore:

```sh
tar czf omp-sandbox-backup.tgz -C . data workspace
tar xzf omp-sandbox-backup.tgz -C .
```

---

## Build arguments

| Argument | Default | Purpose |
|---|---|---|
| `OMP_REPO` | `can1357/oh-my-pi` | Agent source repository. |
| `OMP_REF` | `main` | Branch, tag, or SHA. |
| `OMP_BUILD` | `release` | `release` downloads the platform binary; `source` clones and builds. |
| `OMP_VERSION` | `latest` | Release tag to download (release mode). `latest` resolves via the GitHub API. |
| `OMPWEB_REPO` | `kahme247/ompweb` | Web UI source repository. |
| `OMPWEB_REF` | `main` | Branch, tag, or SHA. |
| `BUN_VERSION` | `1.4.2` | Bun runtime (the engine runs on Bun). |
| `UV_VERSION` | `0.12.17` | uv/uvx for Python tooling. |
| `NODE_VERSION` | `24-bookworm-slim` | Node base image for the builder and runtime stages. |

Default targets are upstream. For a fork or a patched UI:

```sh
docker build \
  --build-arg OMPWEB_REPO=Heretek-AI/ompweb \
  --build-arg OMPWEB_REF=my-branch \
  -t omp-sandbox:fork .
```

Private repositories are reachable without baking a token into image history:

```sh
docker build --secret id=github_token,src=<(printf %s "$GITHUB_TOKEN") .
```

Omitting the secret is valid for public repos.

---

## `OMP_BUILD=release` vs `OMP_BUILD=source`

| | `release` (default) | `source` |
|---|---|---|
| What it does | Downloads `omp-linux-<arch>` from the release for the resolved tag and verifies its SHA-256 against `SHA256SUMS.txt`. | Clones the repo, installs the workspace with Bun, builds the native addon through cargo/napi, and generates the tool-view bundle. |
| Build time | Seconds to a couple of minutes. | Tens of minutes (Rust + napi). |
| Works for | Any published release. | Arbitrary refs, forks, and unreleased commits. |
| Requirement | A release must exist for the tag. | The Rust toolchain in the builder (already in the `omp-source` stage). |

`OMP_REF` does not participate in release mode: when it is not itself version-shaped, the newest release is used and the build prints `WARNING: OMP_BUILD=release ignores OMP_REF; using latest release <tag>`. Use `OMP_BUILD=source` when you need the exact commit.

---

## Docker inside the agent

The image ships the Docker **client only**; the daemon is the host's, reached through the mounted socket. At startup the entrypoint reads the socket's GID, reuses or creates a matching group, and adds `omp` to it, so `docker ps` works inside the container without running as root.

- Hosts without a Docker daemon: Docker creates a **directory** at a missing bind source. Comment out the socket line in `docker-compose.yml`; the entrypoint detects the absence and logs `docker socket not mounted; skipping docker group`.
- **Security:** socket access is equivalent to root on the host. Only expose this container to people you would give host root.

This is what makes MCP servers and sibling-container workflows usable from inside the sandbox.

---

## Credential persistence

| Credential | How to set it | Where it persists |
|---|---|---|
| API keys | `.env` → `env_file` | Never written to disk by the container. |
| GitHub CLI auth | `docker exec -it ompweb gh auth login` | `/home/omp/.config/gh` → `./data/config`. |
| Git identity | `docker exec ompweb git config --global user.email ...` | `/home/omp/.config/git/config` → `./data/config`. |
| SSH keys | Place them in `./data/ssh` (`chmod 700`) | Mounted read-only at `/home/omp/.ssh`. |

---

## Custom OpenAI-compatible provider

Set the six `OMP_PROVIDER_*` variables and the entrypoint writes `~/.omp/agent/models.yml` and `config.yml` on first start. It is idempotent: existing files are never overwritten, so your manual edits survive restarts.

| Variable | Example |
|---|---|
| `OMP_PROVIDER_LABEL` | `openrouter` |
| `OMP_PROVIDER_BASE_URL` | `https://openrouter.ai/api/v1` |
| `OMP_PROVIDER_API_KEY` | `sk-or-v1-...` |
| `OMP_PROVIDER_API` | `openai-completions` |
| `OMP_PROVIDER_MODEL_ID` | `anthropic/claude-3.5-sonnet` |
| `OMP_PROVIDER_MODEL_NAME` | optional, defaults to `OMP_PROVIDER_MODEL_ID` |
| `OMP_DEFAULT_MODEL` | optional `modelRoles.default`; needed when the model ID itself contains `/` |

**OpenRouter:**

```sh
OMP_PROVIDER_LABEL=openrouter
OMP_PROVIDER_BASE_URL=https://openrouter.ai/api/v1
OMP_PROVIDER_API_KEY=sk-or-v1-...
OMP_PROVIDER_API=openai-completions
OMP_PROVIDER_MODEL_ID=anthropic/claude-3.5-sonnet
OMP_PROVIDER_MODEL_NAME=Claude 3.5 Sonnet
OMP_DEFAULT_MODEL=openrouter/anthropic/claude-3.5-sonnet
```

**LM Studio (host):**

```sh
OMP_PROVIDER_LABEL=lmstudio
OMP_PROVIDER_BASE_URL=http://host.docker.internal:1234/v1
OMP_PROVIDER_API_KEY=lm-studio
OMP_PROVIDER_API=openai-completions
OMP_PROVIDER_MODEL_ID=qwen2.5-coder-7b
```

**Ollama (host):**

```sh
OMP_PROVIDER_LABEL=ollama
OMP_PROVIDER_BASE_URL=http://host.docker.internal:11434/v1
OMP_PROVIDER_API_KEY=ollama
OMP_PROVIDER_API=openai-completions
OMP_PROVIDER_MODEL_ID=qwen2.5-coder:7b
```

`host.docker.internal` resolves on Linux because compose sets `extra_hosts: host.docker.internal:host-gateway`.

To regenerate from environment variables, delete the seeded files and restart:

```sh
docker exec ompweb rm /home/omp/.omp/agent/models.yml /home/omp/.omp/agent/config.yml
docker compose restart
```

---

## Sidecar processes

`ompweb` spawns `omp --mode rpc-ui` per session itself; nothing else needs to run for normal use. For an additional long-running omp service (for example a shared credential vault), set `OMP_SIDECAR_CMD`. It runs as the unprivileged `omp` user in the same sandbox, its output is prefixed with `sidecar |`, and it is terminated when the container stops.

```sh
# Remote credential vault
OMP_SIDECAR_CMD=omp auth-broker serve --bind=127.0.0.1:8765

# Auth gateway (itself a broker client)
OMP_SIDECAR_CMD=omp auth-gateway serve --bind=127.0.0.1:4000
```

---

## Workspace seeding

On first start the entrypoint writes `/home/omp/.omp/agent/projects.json` with the workspace as a registered project, so the UI's project sidebar lists `/workspace` immediately instead of requiring a UI click. The file lives on a bind-mounted volume, so the seed survives restarts and never overwrites your edits. Remove the entry in the UI (or delete the file) to change it.

---

## Updating and image tags

```sh
docker compose pull
docker compose up -d
```

The workflow publishes four tag families:

| Tag | Meaning |
|---|---|
| `latest` | Newest successful build (push to `main`, daily schedule, or dispatch with `push_latest`). |
| `<omp_tag>-<ompweb_tag>` | Exact pair, e.g. `v18.2.7-1a2b3c4`. Immutable; use for reproducibility. |
| `omp-<omp_tag>` | Tracks the engine only. |
| `ompweb-<ompweb_tag>` | Tracks the UI only. |

CI resolves the upstream commits on each run and skips the build when the resulting version tag is already published — the daily cron is a no-op unless upstream moved. Dispatch `.github/workflows/docker.yml` manually to pick repos/refs, choose `release` vs `source`, or force a rebuild.

---

## Troubleshooting

**`Refusing to listen on 0.0.0.0 without OMP_WEB_PASSWORD`** — set `OMP_WEB_PASSWORD` in `.env`, or bind to loopback (`OMP_WEB_HOSTNAME=127.0.0.1`) behind a reverse proxy.

**Port already in use** — change `OMPWEB_PORT` in `.env` (host side only; the container always listens on 3000).

**`omp: command not found`** — the engine lives at `/usr/local/bin/omp`. Do not mount anything over `/usr/local/bin`; it would hide the engine and the Bun shim.

**Build fails resolving a release** — no release asset exists for the resolved tag or arch. Build with `OMP_BUILD=source` instead.

**SSH permission warnings** — `chmod 700 data/ssh`; ssh refuses group/other-readable key material.

**`docker: command not found` inside the container** — the socket mount creates a directory when the host path is missing. Check the logs for `docker socket not mounted; skipping docker group` and remove the socket line if the host has no daemon.

**Ownership mismatches in `./workspace`** — set `PUID`/`PGID` in `.env` to `id -u` / `id -g` on the host and restart. The entrypoint remaps the `omp` user on every start.

**`Permission denied` on `/home/omp/.omp` during startup (Fedora/RHEL/CentOS)** — SELinux is enforcing and the bind mounts carry the wrong label. Append `:Z` to the bind mounts in `docker-compose.yml`:

```yaml
    volumes:
      - ${WORKSPACE_DIR:-./workspace}:/workspace:Z
      - ${OMP_DATA_DIR:-./data/omp}:/home/omp/.omp:Z
      - ${OMP_CONFIG_DIR:-./data/config}:/home/omp/.config:Z
      - ${OMP_SSH_DIR:-./data/ssh}:/home/omp/.ssh:ro,Z
```

`:Z` relabels the host directories to a container-private label, so other services will lose access to them; use `:z` instead if more than one container needs them.

---

## Exposing to the internet

Do **not** put this container directly on a public IP. `OMP_WEB_PASSWORD` is the only authentication boundary and there is no rate limiting. Front it with a reverse proxy.

The bundled `Caddyfile` shows the correct headers (`X-Forwarded-For`, `X-Forwarded-Proto`, `X-Real-IP`) and unbounded timeouts for long agent turns:

```sh
cp Caddyfile /etc/caddy/Caddyfile.d/ompweb.caddy
$EDITOR /etc/caddy/Caddyfile.d/ompweb.caddy     # set your domain
echo "import Caddyfile.d/*.caddy" >> /etc/caddy/Caddyfile
systemctl reload caddy
```

nginx equivalent:

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
        proxy_pass         http://127.0.0.1:3000;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
    }
}
```

---

## Security notes

- `OMP_WEB_PASSWORD` is the only auth boundary; pick a strong, unique value.
- The runtime process runs as an unprivileged user (`omp`, UID 1000 by default or your `PUID`). `omp`, Node, and every spawned subprocess share that identity.
- The container starts as root solely to remap UID/GID, join the Docker socket group, and chown mounted volumes. The capability set is deliberately minimal: `CHOWN`, `DAC_OVERRIDE`, `FOWNER` for the volume fix-ups and `SETUID`/`SETGID` for the `gosu` drop, with `cap_drop: [ALL]` and `no-new-privileges: true`.
- API keys stay in `.env`; the image never contains them. Trivy scans run on every publish (advisory, non-gating).

---

## Architecture

```
┌────────────────────────────────────────────────────────┐
│ Container (ghcr.io/<owner>/ompweb-docker)              │
│                                                        │
│ ENTRYPOINT: tini → docker-entrypoint.sh  (root)        │
│   ├─ remap PUID/PGID, join docker-socket group         │
│   ├─ chown + seed /workspace, projects.json            │
│   ├─ optional OMP_PROVIDER_* seeding, engine probe     │
│   └─ exec gosu omp:omp node bin/omp-web.js  (:3000)    │
│            └─ next start  (cwd = /app/ompweb)          │
│                 └─ spawns `omp --mode rpc-ui` per session │
│                    (NDJSON over stdio)                 │
│                                                        │
│ /opt/omp      engine payload (binary or Bun + /pi tree)│
│ /app/ompweb   built UI: .next/, node_modules/, bin/    │
│ /workspace    your code (bind mount)                   │
│ /home/omp/.omp  agent state (bind mount)               │
└────────────────────────────────────────────────────────┘
```

`ompweb` does not embed `omp`: it resolves the binary through `OMP_WEB_OMP_BIN` and spawns it with `--mode rpc-ui`, exchanging NDJSON frames over stdio. There is no HTTP server in the engine, which is why both ship in one image.

Bookworm (glibc) is the base because the release binaries, the napi addon, tree-sitter, and Python wheels all target glibc. The `node` base is 24.x: active LTS (EOL 2028-04-30), satisfying ompweb's `engines.node >= 22.19.0` and Next 16's `>=20.9.0`. Node 22 is maintenance-only since 2025-10-21, and ompweb imports `node:sqlite` (`lib/usage-db.ts`), which Node 22 still flags with an `ExperimentalWarning` on every process start. ompweb's own `.nvmrc` pins 22.19.0, so upstream CI runs one LTS behind this image.

---

## License

MIT for the wrapper files in this repo. See the upstream projects for their own licenses.
