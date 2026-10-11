# kb-mongosync

Migrate MongoDB clusters with [mongosync](https://www.mongodb.com/docs/mongosync/): full copy, real-time incremental sync, and a commit that closes the source sync channel. The Helm chart deploys mongosync and the pod resolves its own config at startup; `kb-mongosync.sh` installs the chart and drives the HTTP API — from your laptop or from inside the pod.

## Quick start (serviceAccount mode)

Connection strings, replica set names and credentials are discovered in-pod via the chart's ServiceAccount. From the laptop:

```bash
./kb-mongosync.sh --kubeconfig ~/kubeconfigs/migrator.yaml \
  --src-ns <ns> --src-cluster <src> --dst-ns <ns> --dst-cluster <dst> run

./kb-mongosync.sh ... status          # watch state and lag
./kb-mongosync.sh ... verify          # counts + dbHash on both sides
./kb-mongosync.sh ... commit --yes    # source write-blocked -> COMMITTED, destination writable
./kb-mongosync.sh ... unblock --yes   # optional: re-enable writes on the retired source
./kb-mongosync.sh ... teardown
```

Or exec into the pod and drive it there (no kubeconfig needed on the pod side):

```bash
kubectl exec -it <pod> -- kb-mongosync status
kubectl exec -it <pod> -- kb-mongosync commit --yes
```

## Manual mode

Provide both endpoints yourself; nothing is discovered in-cluster and no ServiceAccount is created. Pair with `--api-url` to drive a release without kubectl.

```bash
./kb-mongosync.sh --namespace <ns> \
  --source-uri 'mongodb://user:pass@host1:27017,host2:27017/?replicaSet=rs0' \
  --destination-uri 'mongodb://user:pass@host3:27017/?replicaSet=rs1' \
  deploy

./kb-mongosync.sh --namespace <ns> --source-uri ... --destination-uri ... status
./kb-mongosync.sh --namespace <ns> --source-uri ... --destination-uri ... commit --yes
./kb-mongosync.sh --namespace <ns> --source-uri ... --destination-uri ... teardown
```

## Chart

`charts/kb-mongosync` takes the full configuration as values. `source`/`destination` each accept either `uri` (manual mode) or `namespace` + `cluster` (+ optional `component`; serviceAccount mode, needs `serviceAccount.create: true` and `rbac.create: true`, the defaults). The chart renders a ServiceAccount, a Role in both the source and destination namespaces, a Secret for manual URIs, and a Deployment whose entrypoint builds the config (in-pod discovery via kubectl or direct URIs) and execs mongosync. Probes exec inside the container because the mongosync API binds localhost only. Published on tags as `oci://ghcr.io/zijiren233/kb-mongosync-chart/kb-mongosync`.

```bash
helm install msync oci://ghcr.io/zijiren233/kb-mongosync-chart/kb-mongosync --version 0.2.0 \
  --set source.namespace=db --set source.cluster=mg6 \
  --set destination.namespace=db --set destination.cluster=mg8
```

## Subcommands

`check`, `deploy`, `render-conf`, `start`, `status`, `wait --for copy|lag|can-commit|committed`, `verify`, `commit`, `unblock`, `teardown`, `rbac`, `run`. All are idempotent; state is derived from the cluster on every invocation, so any step can be retried or resumed. `check`, `verify`, `unblock` and `rbac` require auto mode; in manual mode they print what to run instead.

## mongosync version

Pinned in `VERSION` and `charts/kb-mongosync/values.yaml` (currently 1.16.0, the newest release accepting a 6.0.20 source; 1.17+ requires source >= 6.0.24). Replica count of either cluster (1 or 3) requires no configuration change.

## Permissions

serviceAccount mode grants the pod: `clusters get/list`, `pods get/list`, `secrets get`, `pods/exec create` in the source and destination namespaces (chart-managed via `rbac.create`). The laptop-side script needs the same reads plus `pods/portforward` and release-management rights for helm — see `rbac.yaml` or the `rbac` subcommand.

## Image

CI reads `VERSION`, verifies both upstream tarballs exist, and builds `linux/amd64` + `linux/arm64` to ghcr.io (docker.io too when `DOCKERHUB_*` variables are set). The image bundles mongosync, kubectl (in-pod discovery) and kb-mongosync; the arm64 build bundles the upstream Amazon 2023 artifact (glibc compatible with the ubuntu:22.04 base).

## Commit semantics

- `start` sends `enableUserWriteBlocking: true` to mongosync by default (`--no-write-blocking` to opt out); 1.16.0 accepts it (`Mode: sourceAndDestination`).
- With the flag on, mongosync write-blocks the source when it receives commit: ordinary application users get immediate "User writes blocked" errors from then on, and commit completes cleanly even with such a writer still running (verified live on 1.16.0: COMMITTED, zero fatals, a non-privileged 5/s writer rejected fail-fast from the commit POST onward). The docs still say to stop application writes before commit, and the quiet gate below enforces that.
- The block does not fence privileged users: the built-in `root`, `restore` and `__system` roles hold `bypassWriteBlockingMode` and write straight through it (documented server behavior, verified live on 6.0.20). A write from such a user that lands after final verification begins still kills mongosync 1.16 fatally — reproduced with a root writer whose insert landed one oplog position after verification started. The quiet gate (or an explicit freeze) is what covers this residual case.
- Recommended cutover: stop application writers (or `block --yes`, which sets the official user write block on the source — the same mechanism mongosync itself uses; application writes fail fast with "User writes blocked", engagement verified by a probe write from a short-lived unprivileged user, since root bypasses the block) -> `commit --yes` -> switch the app to the destination -> `unblock --yes`. The manual block persists after the setting process exits (verified live past four minutes).
- `commit` also gates on a quiet source by itself (oplog quiescence over an 8s window wherever the tool can reach the clusters, strict all-zero lag in manual mode) — mongosync 1.16 fatals if a write races its final verification, and a mid-commit death requires recreating the destination. `--force` overrides.
- If mongosync dies mid-commit, release any leftover source block with `unblock --yes` (it clears setUserWriteBlockMode and any fsync locks); by hand: `db.adminCommand({setUserWriteBlockMode: 1, global: false})`.
- After `COMMITTED` the destination is writable and the source stays blocked until `unblock`.
- Commit is final; reverse is only possible before commit.

## Recovery and scope

- A restarted or redeployed sync (pod recycle, node drain, teardown + deploy) resumes from metadata stored on the destination; no re-copy.
- To start over from scratch instead, recreate the destination cluster or drop its mongosync metadata databases (`mongosync_reserved_for_internal_use`, `__mdb_internal_mongosync`); `check` reports them.
- Scope: replica-set clusters with SCRAM auth and no TLS. Not supported: sharded clusters, arbiters, timeseries collections and views (`check` rejects these), remote API exposure (mongosync binds localhost; use `kubectl exec` or port-forward).
- On clusters with NetworkPolicies, the release pod must be allowed to reach both MongoDB clusters on 27017.
