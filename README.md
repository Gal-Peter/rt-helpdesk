# RT Helpdesk on AWS: DevOps final project

Individual DevOps final project: deploy and operate the supplied RT Helpdesk (Flask + PostgreSQL) on AWS with Docker, Terraform, Kubernetes (kind), Jenkins, Prometheus and Grafana.

The original package README is kept at [docs/SUPPLIED_README.md](docs/SUPPLIED_README.md).

**Status:** Milestone 1 (packaging, Git, CI) in progress. Later sections are placeholders.

## Contents

1. [Architecture](#architecture)
2. [Ports and access](#ports-and-access)
3. [Milestone 1: Container packaging, Git and CI](#milestone-1-container-packaging-git-and-ci)
4. [Milestone 2: AWS with Terraform](#milestone-2-aws-with-terraform) (todo)
5. [Milestone 3: Linux and Kubernetes](#milestone-3-linux-and-kubernetes) (todo)
6. [Milestone 4: Jenkins release and rollback](#milestone-4-jenkins-release-and-rollback) (todo)
7. [Milestone 5: Monitoring and restore](#milestone-5-monitoring-and-restore) (todo)
8. [Cleanup and teardown](#cleanup-and-teardown) (todo)

## Architecture

_Diagram to be added in Milestone 2/3._ Planned: two EC2 hosts in one VPC and one public subnet. The CI host runs the Jenkins controller and a separate agent. The app host runs a single-node kind cluster with `helpdesk` and `monitoring` namespaces. Terraform state and backups live in private S3 buckets.

Known limits: one app host and one database mean no high availability, and kind's local volumes do not survive deletion of the cluster. Recovery relies on S3 backups.

## Ports and access

| Service | Address | Notes |
|---|---|---|
| Helpdesk UI and API (local Compose) | http://localhost:8000 | Bound to 127.0.0.1 only |
| Health / readiness / version / metrics | `/healthz`, `/readyz`, `/version`, `/metrics` | Same port |
| Prometheus (local, monitoring profile) | http://localhost:9090 | Local only |
| Grafana (local, monitoring profile) | http://localhost:3000 | Local only |

_AWS access (SSH, tunnels, port-forward) to be added in Milestones 2-3._

## Milestone 1: Container packaging, Git and CI

### Dockerfile

Three named stages in one `Dockerfile`:

| Stage | Purpose |
|---|---|
| `base` | `python:3.12-slim-bookworm`, creates user/group 10001, installs `requirements.txt`, then copies `app/` and `gunicorn.conf.py` |
| `test` | Extends `base`, adds `requirements-dev.txt`, `pytest.ini` and `tests/`; default command runs pytest; final user is 10001:10001 |
| `runtime` | Extends `base`; sets `APP_VERSION`, `USER 10001:10001`, `EXPOSE 8000`, starts Gunicorn |

`runtime` is the **last** stage, so `docker build` without `--target` produces the web image. `test` extends `base`, not `runtime`, so it is never the default result. Compose, GitHub Actions and Jenkins refer to `runtime` by name.

**Dependency caching.** `requirements.txt` is copied and installed before `app/` is copied. A source-only change (for example a CSS edit) reruns only the `COPY app/` layers. I checked this: after adding a CSS comment the `pip install` layer showed `CACHED`.

**Non-root user.** The image runs as UID/GID 10001 (`app`), with `nologin` and no home directory. Application files are owned by root and are read-only to that user. Verified with `id` inside the container and `docker image inspect` (`10001:10001`).

**Writable `/tmp` and read-only root.** The app only needs `/tmp` (Gunicorn's `worker_tmp_dir`). Compose runs it with `read_only: true` and a `tmpfs` on `/tmp`. I verified a `touch /tmp/...` works with `docker run --read-only --tmpfs /tmp`.

**Runtime secrets.** No credentials are in build arguments, the Dockerfile or image layers. Database settings come from environment variables supplied by Compose from a generated `.env` (git-ignored and Docker-ignored). The only build argument is `APP_VERSION`, which is not a secret. Release images will use the commit SHA.

**Ports and data.** The app listens on 8000 inside the container (`EXPOSE 8000`); Compose publishes it on `127.0.0.1:8000`. The image holds no data. Tickets live in PostgreSQL's named volume `pgdata`, which survives `docker compose restart` and `down` (not `down -v`).

**Why tests stay in the build context but out of the runtime image.** `.dockerignore` filters the context for both targets, and the test target needs `tests/`, `pytest.ini` and `requirements-dev.txt`, so they cannot be ignored. The runtime image stays clean because its stage never copies them. Verified: `pip show pytest` fails in the runtime image.

### .dockerignore

Excludes Git history and editor files, `.env*`, keys and kubeconfigs, virtualenvs, bytecode and test caches, backups, dumps and logs, Terraform state/plans/variable files, and folders neither image needs (`docs/`, `reference/`, `monitoring/`, `postgres/`, `scripts/`). It deliberately keeps `tests/`, `pytest.ini`, `requirements-dev.txt` and `app/schema.sql`. Patterns use `**/` so subfolders are covered. The build context dropped to about 20 kB.

### Local verification results

| Check | Command | Result |
|---|---|---|
| Three builds | `docker build --target runtime ...`, `--target test ...`, plain build | All succeeded |
| Default command | `docker image inspect ... .Config.Cmd` | `["gunicorn","--config","gunicorn.conf.py","app:create_app()"]` |
| Non-root | `docker image inspect ... .Config.User` | `10001:10001` |
| Read-only run | `docker run --read-only --tmpfs /tmp ... touch /tmp/...` | Succeeded; `/app` has only `app`, `gunicorn.conf.py`, `requirements.txt` |
| Runtime has no pytest | `pip show pytest` in runtime image | "Package(s) not found" |
| Baked version | `printenv APP_VERSION` | `packaging-check` |
| Layer caching | CSS change, rebuild | `pip install` layer `CACHED` |
| Compose startup | `docker compose up --build -d` | `db` and `api` healthy; `migrate` exited 0 |
| Tests | `docker compose --profile test run --build --rm tests` | **36 passed**, none skipped ([output](https://github.com/Gal-Peter/rt-helpdesk/blob/main/evidence/Git_Bash_MS1_Run.txt))|
| Persistence | Create a ticket, `docker compose restart api db` | Ticket still present afterwards |

Note for Windows/Git Bash: commands containing Linux paths like `/tmp` need `MSYS_NO_PATHCONV=1` in front, or Git Bash rewrites them.

### Git and CI

- Repository: https://github.com/Gal-Peter/rt-helpdesk (private).
- Excluded from Git by `.gitignore`: `.env`, keys, Terraform state and plans, kubeconfigs, backups.
- Workflow: `.github/workflows/ci.yml` runs tests (with a PostgreSQL service) and builds the runtime image on pull requests and pushes to `main`. Test results are uploaded as an artifact (`test-results`) even if a later step fails.

| Run | What happened | Link |
|---|---|---|
| App CI #1 (push to `main`) | **Failed** at "Build runtime image": `open Dockerfile: no such file or directory`. Tests passed; `main` had no Dockerfile yet | https://github.com/Gal-Peter/rt-helpdesk/actions/runs/43119547749 |
| App CI #2 (PR #1) | Passed after adding the Dockerfile and `.dockerignore` | https://github.com/Gal-Peter/rt-helpdesk/actions/runs/43121318752 |
| App CI #3 (merge to `main`) | Passed | https://github.com/Gal-Peter/rt-helpdesk/actions/runs/43122323070 |
| Instructor failing-test fixture: fails | _todo_ | _link_ |
| Instructor failing-test fixture removed: passes | _todo_ | _link_ |

Pull requests so far: #1 "Add Dockerfile and .dockerignore" (self-reviewed checklist, merged after CI passed). Required-check setting: _record here whether the repo plan supports it; otherwise note that checks were verified green before each merge_.

## Milestone 2: AWS with Terraform

_Todo._

## Milestone 3: Linux and Kubernetes

_Todo._

## Milestone 4: Jenkins release and rollback

_Todo._

## Milestone 5: Monitoring and restore

_Todo._

## Cleanup and teardown

_Todo. Must include the Terraform destroy order and checks that resources are gone._
