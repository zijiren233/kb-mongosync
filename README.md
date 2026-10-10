# kb-mongosync

Migrate MongoDB clusters with [mongosync](https://www.mongodb.com/docs/mongosync/): full copy, real-time incremental sync, and a commit that closes the source sync channel. mongosync runs as a Helm release; `kb-mongosync.sh` installs the chart, injects the connection config at runtime, and drives the HTTP API.

## Quick start (auto mode)

Connection strings, replica set names and credentials are discovered from KubeBlocks clusters via kubectl.

```bash
./kb-mongosync.sh --kubeconfig ~/kubeconfigs/migrator.yaml \
  --src-ns <ns> --src-cluster <src> --dst-ns <ns> --dst-cluster <dst> run

./kb-mongosync.sh ... status          # watch state and lag
./kb-mongosync.sh ... verify          # counts + dbHash on both sides
./kb-mongosync.sh ... commit --yes    # source write-blocked -> COMMITTED, destination writable
./kb-mongosync.sh ... unblock --yes   # optional: re-enable writes on the retired source
./kb-mongosync.sh ... teardown
```

## Manual mode

No kubectl discovery: provide both endpoints yourself. `deploy` installs the chart, `configure` writes the config Secret from the given URIs, and `--api-url` drives the release without kubectl.

```bash
./kb-mongosync.sh --namespace <ns> \
  --source-uri 'mongodb://user:pass@host1:27017,host2:27017/?replicaSet=rs0' \
  --destination-uri 'mongodb://user:pass@host3:27017/?replicaSet=rs1' \
  deploy

./kb-mongosync.sh --namespace <ns> --source-uri ... --destination-uri ... configure

./kb-mongosync.sh --api-url http://<svc>:27180 start
./kb-mongosync.sh --api-url http://<svc>:27180 commit --yes
./kb-mongosync.sh --namespace <ns> --source-uri ... --destination-uri ... teardown
```

## Subcommands

`check`, `deploy`, `configure`, `start`, `status`, `wait --for copy|lag|can-commit|committed`, `verify`, `commit`, `unblock`, `teardown`, `rbac`, `run`. All are idempotent; state is derived from the cluster on every invocation, so any step can be retried or resumed. `check`, `verify`, `unblock` and `rbac` require auto mode; in manual mode they print what to run instead.

## Chart

`charts/kb-mongosync` installs the workload only: Deployment (recreate strategy, readiness on `/api/v1/progress`, 2Gi limit), Service, and optional ServiceAccount/RBAC (`serviceAccount.create`, `rbac.create`). Connection config is not a chart value: the container entrypoint waits for the Secret `<release>-conf` (key `conf.json`), which `configure` creates outside Helm; the pod restarts automatically when the config changes. Published on tags as `oci://ghcr.io/zijiren233/kb-mongosync`.

## mongosync version

Pinned in `VERSION` and `charts/kb-mongosync/values.yaml` (currently 1.16.0, the newest release accepting a 6.0.20 source; 1.17+ requires source >= 6.0.24). Replica count of either cluster (1 or 3) requires no configuration change.

## Permissions

Auto mode needs: `clusters get/list`, `deployments get/list`, `pods/services/secrets/configmaps get/list/watch`, `secrets create/delete` (config injection), `pods/exec + pods/portforward create`, `pods delete`, `events get/list` — see `rbac.yaml` or generate with concrete names via the `rbac` subcommand. Helm itself requires install rights on deployments and services in the release namespace.

## Image

CI reads `VERSION`, verifies both upstream tarballs exist, and builds `linux/amd64` + `linux/arm64` to ghcr.io (docker.io too when `DOCKERHUB_*` variables are set). mongosync ships no official container image; the arm64 image bundles the upstream Amazon 2023 build (glibc compatible with the ubuntu:22.04 base).

## Commit semantics

- `commit` write-blocks the source immediately; source writes fail during the short COMMITTING window.
- After `COMMITTED` the destination is writable and the source stays blocked until `unblock`.
- Commit is final; reverse is only possible before commit.
