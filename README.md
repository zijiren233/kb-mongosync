# kb-mongosync

在 KubeBlocks 集群之间用 [mongosync](https://www.mongodb.com/docs/mongosync/)（MongoDB Cluster-to-Cluster Sync）完成 MongoDB 迁移的驱动工具：**一个脚本 + 一个工具镜像**。

只用指定：工具镜像、源 `ns/cluster`、目标 `ns/cluster`（配合一份最小权限 kubeconfig），即可完成 全量同步 → 实时增量 → 一致性校验 → commit（cutover，源端增量自动关闭）。

## 组成

```
kb-mongosync.sh          # 主脚本（子命令式、幂等、可从任意步骤重入）
Dockerfile               # mongosync 工具镜像（linux/amd64 + linux/arm64）
.github/workflows/docker.yml  # CI：读 VERSION 构建双架构镜像（ghcr.io，可选 docker.io）
rbac.yaml                # 最小权限基线（严格版用 rbac 子命令生成）
VERSION                  # 镜像内捆绑的 mongosync 版本（当前 1.16.0）
```

## 快速开始

```bash
# 0) 镜像（CI 自动构建，也可本地构建推私有仓库）
#    ghcr.io/zijiren233/kb-mongosync:mongosync-1.16.0

# 1) 一键到"全量完成"，之后逐步入
./kb-mongosync.sh \
  --kubeconfig ~/kubeconfigs/migrator.yaml \
  --image ghcr.io/zijiren233/kb-mongosync:mongosync-1.16.0 \
  --src-ns kb-db-test  --src-cluster mft-mg6 \
  --dst-ns kb-db-test  --dst-cluster mft-mg8 \
  run

# 2) 观察增量 lag（写入器在跑时应为个位数秒）
./kb-mongosync.sh ... status

# 3) 一致性校验（建议先停源端写流量；lag=0 时结果是确定性的）
./kb-mongosync.sh ... verify

# 4) 提交迁移（cutover）
./kb-mongosync.sh ... commit --yes

# 5) 切换应用连接串到目标集群

# 6) 可选：恢复源端可写（防双写，默认保持阻塞）
./kb-mongosync.sh ... unblock --yes

# 7) 清理
./kb-mongosync.sh ... teardown
```

> `...` 代表同一组全局参数（kubeconfig/image/ns/cluster），建议 shell 函数包装。

## 子命令

| 子命令 | 作用 | 幂等行为 |
|---|---|---|
| `check` | 集群 Running、版本下限、凭证、目标端空库校验 | 纯只读 |
| `deploy` | 部署 mongosync pod + 配置 Secret | 镜像/配置一致则跳过；不同需 `--force` |
| `start` | `POST /start`（cluster0→cluster1） | RUNNING/COMMITTED 直接跳过 |
| `status` | state / canCommit / canWrite / lag / 拷贝进度 | 只读 |
| `wait` | `--for copy\|lag\|can-commit\|committed`，`--timeout` 秒 | 可重复调用 |
| `verify` | 双端集合 counts + 索引数 + dbHash 对比 | 只读（lag>0 时给 WARN） |
| `commit` | 提交迁移至 COMMITTED | 已 COMMITTED 则跳过 |
| `unblock` | 解除源端用户写阻塞 | `setUserWriteBlockMode` 天然幂等 |
| `teardown` | 删 pod + 配置 Secret | `--ignore-not-found` |
| `rbac` | 打印本次迁移的最小权限 Role/RoleBinding | 只读输出 |
| `run` | check→deploy→start→wait copy→status | 内部逐步幂等 |

## commit 的写阻塞语义（重要）

- 默认配置下，`POST /commit` 时 mongosync **自动对源集群启用用户写阻塞**（`setUserWriteBlockMode global:true`），因此不强制先停工作负载；
- 但 COMMITTING 窗口内（秒级~分钟级）**源端写入会直接报错** —— 不能容忍写错误的应用仍应先停/降级写流量（这也是官方流程建议的顺序）；
- `COMMITTED` 后目标端 `canWrite=true`（应用切换点），**源端保持写阻塞**（防双写），需要归档/继续使用源端时手动 `unblock`；
- commit 之后不可回退（反向同步仅限 commit 前）。

## mongosync 版本矩阵（实测）

| mongosync | 源最低 patch | 说明 |
|---|---|---|
| 1.22.0（当前最新） | 6.0.24（目标 ≥8.0.5） | 6.0.20/8.0.4 被拒 |
| 1.17.0 ~ 1.21.0 | 6.0.24 | 同上 |
| **1.16.0** | **6.0.20 ✓**（目标 8.0.4 ✓） | **6.0.20 → 8.0.4 的最高可用版本** |

源/目标副本数（1 或 3）对 mongosync 透明，无需任何配置差异（连接串多种子自动发现拓扑）。修改 `VERSION` 可换绑其他 mongosync 版本，CI 会重出镜像（tag 形如 `mongosync-<版本>`）。

## 最小权限 kubeconfig

脚本对集群的全部操作：clusters 只读、pods 增删查 + exec/portforward、secrets 读取（`<cluster>-<component>-account-root`）与配置 Secret 增删。见 `rbac.yaml`；用 `rbac` 子命令生成填好实际 ns/集群名的版本：

```bash
./kb-mongosync.sh --src-ns A --src-cluster X --dst-ns B --dst-cluster Y rbac > my-rbac.yaml
```

跨 namespace 迁移：源、目标 ns 各一份 Role/RoleBinding。凭证只在 shell 变量与集群 Secret 之间流转，不进入日志与命令行输出。

## 镜像构建

CI（`.github/workflows/docker.yml`）读取 `VERSION` 文件，先探测两架构的上游 tarball 是否存在，再构建 `linux/amd64,linux/arm64` 并推 ghcr.io（配置了 `DOCKERHUB_*` 变量/密钥时同步推 docker.io）。本地构建：

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg MSVER=$(cat VERSION) -t <registry>/kb-mongosync:mongosync-$(cat VERSION) --push .
```

mongosync 官方不提供容器镜像，本仓库即为此而设。

## 排障速查

| 现象 | 处理 |
|---|---|
| `Expected version 6.0.24` | mongosync 版本过高，降 VERSION（6.0.20 源 ⇒ 1.16.0） |
| pod OOMKilled（exit 137） | 脚本已固定 2Gi；自定义时勿低于 2Gi |
| mongosync 崩溃后 | 直接重跑 `deploy`/`start`，按目标端元数据自动续传（INITIALIZING→RUNNING） |
| port-forward 失败 | 脚本自动换端口（27180→27189）；本机 kubectl 需 `--address` 写法已内置 |
| `/commit` 报 `expected {}` | 必须带 `{ }` body（脚本已处理） |
| 目标集群非空 | 全量要求空库；残留上次元数据时会自动续传，否则清理后重来 |
