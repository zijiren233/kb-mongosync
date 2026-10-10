# kb-mongosync

Migrate MongoDB clusters managed by KubeBlocks using
[mongosync](https://www.mongodb.com/docs/mongosync/): full copy, real-time
incremental sync, and a commit that closes the source sync channel. One script,
one prebuilt tool image.

## Quick start

```bash
IMG=ghcr.io/zijiren233/kb-mongosync:mongosync-1.16.0
K=~/kubeconfigs/migrator.yaml

./kb-mongosync.sh --kubeconfig $K --image $IMG \
  --src-ns <ns> --src-cluster <src> --dst-ns <ns> --dst-cluster <dst> run

./kb-mongosync.sh ... status          # watch state and lag
./kb-mongosync.sh ... verify          # counts + dbHash on both sides
./kb-mongosync.sh ... commit --yes    # source write-blocked -> COMMITTED, destination writable
./kb-mongosync.sh ... unblock --yes   # optional: re-enable writes on the retired source
./kb-mongosync.sh ... teardown
```

`...` stands for the same global options; wrap them in a shell function.

## Subcommands

`check`, `deploy`, `start`, `status`, `wait --for copy|lag|can-commit|committed`,
`verify`, `commit`, `unblock`, `teardown`, `rbac`, `run`. All are idempotent;
state is derived from the cluster on every invocation, so any step can be
retried or resumed.

## mongosync version

Pinned in `VERSION` (currently 1.16.0, the newest release accepting a 6.0.20
source; 1.17+ requires source >= 6.0.24). Changing `VERSION` rebuilds the image
with tag `mongosync-<version>`. Replica count of either cluster (1 or 3)
requires no configuration change.

## Permissions

Minimal Role: `clusters get/list`, `pods` CRUD + `exec`/`portforward`,
`secrets get/create/delete`, `events get/list`. See `rbac.yaml`, or generate a
copy with concrete names:

```bash
./kb-mongosync.sh --src-ns A --src-cluster X --dst-ns B --dst-cluster Y rbac > my-rbac.yaml
```

## Image

CI reads `VERSION`, verifies both upstream tarballs exist, and builds
`linux/amd64` + `linux/arm64` to ghcr.io (docker.io too when `DOCKERHUB_*`
variables are set). mongosync ships no official container image; the arm64
image bundles the upstream Amazon 2023 build (glibc compatible with the
ubuntu:22.04 base).

## Commit semantics

- `commit` write-blocks the source immediately; source writes fail during the
  short COMMITTING window.
- After `COMMITTED` the destination is writable and the source stays blocked
  until `unblock`.
- Commit is final; reverse is only possible before commit.
