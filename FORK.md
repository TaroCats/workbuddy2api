# FORK.md — 本 fork 的自动化说明

本仓库是 [`HanawaBanana/workbuddy2api`](https://github.com/HanawaBanana/workbuddy2api) 的 fork。
上游本身是已删库的 `Sliverkiss/workbuddy2api` 的延续。

**本文件以及下面列出的「fork 覆盖层」文件都是本 fork 独有的，上游没有。** 同步时它们会被自动
保留（机制见下）。改动其他文件请注意：**上游同步采用硬重置，除覆盖层外的任何本地改动都会被丢弃。**

---

## 一、三条自动化链路

```
上游 HanawaBanana/workbuddy2api
        │  ① 定时检测（每 12 小时）
        ▼
sync-upstream.yml ──硬重置──▶ fork master ──② 触发──▶ build.yml
                                                        │
                                                        ▼  ③ 推送镜像
                                              ghcr.io/tarocats/workbuddy2api:latest
                                                        │
                                                        ▼  ④ 宿主机 cron 拉取
                                              scripts/selfupdate.sh → 重建容器
```

### ① / ② 上游同步 + 触发构建 — `.github/workflows/sync-upstream.yml`

- **触发**：每天北京时间 11:37 / 23:37（UTC `37 3,15 * * *`），或手动 `Run workflow`
- **策略**：硬重置（完全镜像）—— fork 的 `master` = 上游 `master` 内容 + fork 覆盖层
- **检测方式**：内容比对，不是 SHA 比对。同步后如果内容和同步前逐字节一致，就不产生提交、
  不 push、不触发构建（避免每 12 小时攒一个空提交）
- **构建触发**：用 `workflow_dispatch` 显式派发 `build.yml`。**不能**依赖 push 事件——
  GitHub 规定由 `GITHUB_TOKEN` 产生的 push 不会再触发其他 workflow（防递归），这是最容易踩的坑。
  另外派发时必须写 `--repo "${GITHUB_REPOSITORY}"`：本 workflow 中途加过名为 `upstream` 的
  remote，`gh` 解析「当前仓库」会挑中它，请求就打到了上游仓库并返回
  `403 Resource not accessible by integration`（真实踩过，见排障表）
- 手动 `Run workflow` 时勾选 `force` 可以跳过「无变化」判断，强制重建一次镜像

### ③ 构建镜像 — `.github/workflows/build.yml`（上游自带，未做任何修改）

上游的 `build.yml` 本身就已经把镜像推到 `ghcr.io/${GITHUB_REPOSITORY}`，在本 fork 里解析成
`ghcr.io/tarocats/workbuddy2api`，因此**需求满足且零改动** —— 好处是上游以后改进这个
workflow 时能直接同步过来，不会被 fork 的改动顶掉。

它产出的 tag：`latest`、`<commit-sha>`；同时导出 amd64 离线 `tar.gz` artifact。
触发方式：每日定时（UTC 04:23）、打 `v*` tag、手动 `Run workflow`，以及被上面那个 workflow 派发。

> 手动重建：Actions → **Build & Publish** → Run workflow。约 5–15 分钟。

### ④ 宿主机自更新 — `scripts/selfupdate.sh` + cron

```bash
# 首次部署：拉镜像启动（而不是本地构建）
docker compose -f docker-compose.yml -f docker-compose.fork.yml up -d --no-build

# 装 cron，之后每 6 小时自动检查一次
./scripts/selfupdate.sh --install-cron
```

脚本做四件事：`docker pull` 最新镜像 → 和当前容器所用镜像 ID 比对 → 有变化就
`up -d --no-build --force-recreate` 重建 → HTTP 健康检查通过后才算成功，最后清理旧镜像。

其他常用命令：

| 命令 | 作用 |
| --- | --- |
| `./scripts/selfupdate.sh --check` | 只检查不更新；有更新退出码 `10`，无更新 `0`，便于接监控 |
| `./scripts/selfupdate.sh --force` | 镜像没变也强制重建 |
| `./scripts/selfupdate.sh --dry-run` | 只打印将执行的命令 |
| `./scripts/selfupdate.sh --print-cron` | 打印 crontab 条目（不写入） |
| `./scripts/selfupdate.sh --install-cron --yes` | 直接安装 cron（原 crontab 备份到 `data/crontab.bak`） |

日志默认追加到 `data/selfupdate.log`（超过 1 MiB 自动轮转成 `.log.1`）。

---

## 二、fork 覆盖层机制（重要）

同步时 fork 独有的文件会被硬重置删掉，所以 `sync-upstream.yml` 在重置前把它们快照到临时目录，
重置后原样拷回，再一起提交。**覆盖层清单硬编码在该 workflow 的 `FORK_FILES` 环境变量里。**

```
.github/workflows/sync-upstream.yml   ← 同步与触发构建
scripts/selfupdate.sh                 ← 宿主机自更新
docker-compose.fork.yml               ← 给 wb2api 补 image: 指向 GHCR
FORK.md                               ← 本文件
```

**要往 fork 上加自己的文件，必须同时把它加进 `FORK_FILES`**，否则下一次同步（最多 12 小时后）
它就会被抹掉。

> 细节：仓库 `.gitignore` 里有全局 `*.md` 忽略（只放行 `README.md`），所以 `FORK.md` 在同步时
> 是用 `git add -f` 强制入库的。

---

## 三、上线前的两项检查

### 1. GHCR 包可见性（公开仓库无需操作）

**本仓库是 public，推上去的包默认就是 public —— 已实测无需任何设置**：匿名
`ghcr.io/token` → `tags/list` → 读 manifest 全部 200，宿主机可直接 `docker pull`。

只有 fork 是 **private** 仓库时才需要处理：到
`头像 → Your packages → workbuddy2api → Package settings → Change visibility → Public`，
或改成登录拉取：`docker login ghcr.io -u <用户名> -p <带 read:packages 的 PAT>`。

自查命令：

```bash
# 匿名能列出 tag 就是 public
TK=$(curl -s "https://ghcr.io/token?scope=repository:tarocats/workbuddy2api:pull&service=ghcr.io" | jq -r .token)
curl -s -H "Authorization: Bearer $TK" https://ghcr.io/v2/tarocats/workbuddy2api/tags/list
```

### 2. 确认两个 workflow 都是启用状态

**fork 里 `build.yml` 的初始状态是 `disabled_fork`（禁用）**，禁用状态下无法被
`workflow_dispatch` 派发，同步链路会在最后一步静默失败。到
`Actions → 左侧选中 Build & Publish → 右侧 Enable workflow` 启用即可。

查询状态（`gh` 或 API）：

```bash
gh api repos/TaroCats/workbuddy2api/actions/workflows \
  --jq '.workflows[] | "\(.name)\t\(.state)"'
```

三个都应是 `active`。也可以在 Actions 页顶部横幅点
「I understand my workflows, go ahead and enable them」一次全开。

> 关于仓库的 `Settings → Actions → General → Workflow permissions`：**保持默认的
> Read and write 或 Read 都行**。`sync-upstream.yml` 自带
> `permissions: {contents: write, actions: write}` 显式声明，会覆盖仓库默认值——
> 已在真实运行日志里验证 `GITHUB_TOKEN Permissions: Actions: write, Contents: write`。
> 只有 `master` 开了分支保护时才需要额外允许 force push，否则同步会在 push 那步失败。

---

## 四、两条部署路线（别混用）

| | 源码构建 | 镜像部署（本 fork 推荐） |
| --- | --- | --- |
| 命令 | `docker compose up -d --build` | `./scripts/selfupdate.sh` |
| 镜像 | CI 同 tag 的本地构建产物 | GHCR 上的 CI 产物 |
| 更新 | 手动 `git pull` + 重建 | cron 自动 |
| 适用 | 改代码、调试 | 长期跑着的机器 |

`selfupdate.sh` 走的是 `--no-build`，**永远不会**触发本地构建，所以两条路线不会互相打架。
但注意：本地 `--build` 会用同样的 tag 覆盖本地镜像，之后再跑 `selfupdate.sh` 会把它换回 GHCR 版本。

---

## 五、排障

| 现象 | 原因 / 处理 |
| --- | --- |
| 同步后 workflow 自己消失了 | 说明 `FORK_FILES` 里漏了 `sync-upstream.yml`，或快照失败。手动把文件加回来 |
| `push --force-with-lease` 被拒 | 远端 `master` 被人改过，或分支保护拦了 force push。看运行日志 |
| 构建没被触发（同步任务却是绿勾） | 派发失败只打 `::warning::`，不会让任务失败——一定要看 job 日志。两个已知原因：① `build.yml` 被禁用（`disabled_fork` / `disabled_manually`），422 拒绝派发；② `gh workflow run` 没带 `--repo`，gh 选中了名为 `upstream` 的 remote，请求打到上游仓库 → `403 Resource not accessible by integration` |
| 宿主机 `docker pull` 403 | GHCR 包还是 private，见上面第 1 条 |
| 更新后健康检查一直不过 | `docker logs --tail 100 workbuddy2api`；必要时回滚到上一个镜像 tag（`:<sha>`）并临时改 `--image` |

---

## 六、验证记录（2026-09-28 首次真机实跑）

链路已跑通并留档，日后再动这些文件时可以对照：

| 环节 | 证据 |
| --- | --- |
| 同步 | `Sync Upstream #1` / `#2` 均 success；`内容与同步前一致，跳过提交与推送`（幂等生效，未产生空提交） |
| 派发 | `#2` 日志输出 `https://github.com/TaroCats/workbuddy2api/actions/runs/36389184456` |
| 构建 | `Build & Publish #1` success，5m40s，多架构 `linux/amd64,linux/arm64` |
| 产物 | `ghcr.io/tarocats/workbuddy2api:latest` = `:89ea76d…`，index digest `sha256:7874380d…`；另附 amd64 离线 tar.gz artifact |
| 可见性 | 匿名可取 token / 列 tag / 读 manifest（均 200）→ 包是 public，宿主机可直接 pull |

首次实跑揪出了两个本地测不出的 bug（`build.yml` 在 fork 里是 `disabled_fork`；`gh workflow run`
未带 `--repo` 导致请求打到上游仓库被 403 拒绝），已在 `fix(ci)` 提交中修复，排障表有记录。
