# FORK.md — 本 fork 的自动化说明

本仓库是 [`HanawaBanana/workbuddy2api`](https://github.com/HanawaBanana/workbuddy2api) 的 fork。
上游本身是已删库的 `Sliverkiss/workbuddy2api` 的延续。

**本文件以及下面列出的「fork 覆盖层」文件都是本 fork 独有的，上游没有。** 同步时它们会被自动
保留（机制见第五节）。改动其他文件请注意：**上游同步采用硬重置，除覆盖层外的任何本地改动都会被丢弃。**

这个 fork 在上游网关之外多做了两件事：**把控制台面板一起装进同一套编排**，以及
**让三个组件都能在容器内自己更新**（宿主机不需要 cron）。

---

## 一、四个容器

```
                    ┌──────────────────────── 宿主机 ────────────────────────┐
   :80/:443  ───────▶ caddy ──反代──▶ wbgui ──HTTP──▶ wb2api ◀── OpenAI 兼容客户端 :7863
   （面板唯一入口）    │              （面板 8787）    （网关 7863）
                       │                 │                ▲
                       │                 └──直读 auths/ 与 config.json
                       │                                  │
                       └──▶ updater ──通过 docker.sock 指挥上面三个容器的更新
                            （无对外端口）
                    └───────────────────────────────────────────────────────┘
```

| 容器 | 作用 | 镜像来源 | 对外端口 |
| --- | --- | --- | --- |
| `wb2api` | 网关本体 | GHCR（CI 构建） | `7863` |
| `wbgui` | 可视化控制台 | **容器内从源码构建** | 无（只在内网，走 caddy） |
| `caddy` | 统一反代入口 | `caddy:2-alpine` | `80` / `443` |
| `updater` | 更新执行器 | 本地构建（`deploy/updater`） | 无 |

编排文件是 `docker-compose.fork.yml`，**它是自包含的完整栈**，不是叠加在上游
`docker-compose.yml` 上的 override —— 上游那份保持原样，仍可作为「完全按上游方式部署」的参考。

> 为什么不做成 base + override：本栈比上游多三个容器、一个网络、一套统一入口。用叠加写，
> `build:` 与 `image:` 会各定义两处、端口/卷各定义两处，读的人得在脑子里做一次合并才敢排障。
> 代价是上游改了 `docker-compose.yml` 不会自动跟进 —— 但对这个栈来说，可读性更值钱。

### 面板与控制台的取舍

`wbgui` 用的是 [`linbeize/workbuddy2api-gui`](https://github.com/linbeize/workbuddy2api-gui)
（原 `287775856/workbuddy2api-gui`，仓库已改名）。

本 fork 只部署**一个**控制台。另一个候选
[`ithtelab/workbuddy-manager`](https://github.com/ithtelab/workbuddy-manager)（Next.js + FastAPI）
与 `wbgui` 是同一件事的两种前端（manager 自己的 README 写的是「一套给 workbuddy2api 配套的
Web 管理端」）。两个都装意味着两套登录、两份凭证操作逻辑、两处可能写坏网关配置 —— 所以取更轻的
那个（`wbgui` 是单 Go 二进制，且直读网关的 `auths/` 与 `config.json`，不需要额外数据库）。

---

## 二、三条更新链路（全部在容器内完成）

宿主机上**不需要任何 cron**。所有判断与执行都在 `updater` 容器里，它只通过
`/var/run/docker.sock` 指挥宿主机的 Docker 守护进程。

| 组件 | 更新方式 | 变化检测依据 |
| --- | --- | --- |
| `wb2api` | `docker pull` 镜像后重建 | 镜像 ID 比对 |
| `wbgui` | 拉上游源码 → `docker build` → 重建 | 上游 commit sha 比对 |
| **编排本身** | `git pull` 本仓库 → 校验 → 派发 helper 重建整栈 | 本仓库 commit 比对 |

每个服务的一轮更新固定是这个顺序：

```
记下当前镜像 → 取到新镜像 → 没变化就跳过 → 有变化才重建 → 等健康检查通过 → 不通过则回滚
```

回滚点：重建之前会把当前镜像打上 `<仓库>:previous` 标签，健康检查失败时用它覆盖回来。

### 为什么更新必须由一个独立容器执行

**容器无法可靠地重建自己。** `docker compose up --force-recreate <自己>` 会先停掉目标容器，
而发起这条命令的进程就在那个容器里 —— 它会在 `stop` 这一步被一起杀掉，后面的 `create`
永远执行不到，结果是服务停着起不来。

所以由 `updater` 代劳（它不是被重建的那个容器）。同理，更新「编排文件自身」时用
`docker run -d --rm` 派发一个 detached helper 去重建整个栈 —— helper 也不是被重建的容器。

### 健康检查的语义

网关的 `/healthz` 在池里没有健康账号时返回 **503**，而 `wget` 对 503 仍算成功 ——
也就是说**进程起来了就算健康**。这正是我们要的：更新是否成功，不该被「有没有登录过账号」绑住。
判定用 `docker inspect` 读 `.State.Health.Status`，没有 HEALTHCHECK 的退回 `.State.Status`。

### 命令

```bash
# 宿主机侧（首次部署用这个，不要直接 docker compose up）
./scripts/stack.sh init      # 生成 .env / config.json / 目录，设置本地忽略
./scripts/stack.sh up        # 引导并启动整个栈

# 日常运维
./scripts/stack.sh status            # 容器状态 + 各服务镜像版本 + 更新历史
./scripts/stack.sh doctor            # 体检：路径、权限、镜像、端口
./scripts/stack.sh logs [服务]        # 跟踪日志（默认 updater）
./scripts/stack.sh update            # 立刻让容器内的更新器跑一轮
./scripts/stack.sh update --only wbgui --dry-run
./scripts/stack.sh rollback <服务>    # 回滚到上一个可用镜像
./scripts/stack.sh restart [服务] | down | config | shell <服务>
```

`updater` 本身也支持直接进容器调用（`stack.sh` 内部就是这么转发的）：
`--loop`（默认）、`--once`、`--dry-run`、`--only <服务>`、`--rollback <服务>`、`--status`。

---

## 三、从旧版（宿主机 cron）迁移

第一轮的方案是「宿主机 cron + `scripts/selfupdate.sh`」，**已经删除**。它按
`docker-compose.yml` + `docker-compose.fork.yml` 两文件**叠加**的方式重建容器，而现在
`docker-compose.fork.yml` 已是自包含完整栈 —— 再叠加会解析出冲突配置。

**如果你在旧版本里装过那条 cron，它会每 6 小时把好好的栈按过时的方式重建坏一次。请务必摘掉：**

```bash
crontab -l | grep -v wb2api-selfupdate | crontab -
```

（`./scripts/stack.sh init` 也会检测到这条 cron 并提示你摘掉。）

然后按新方式启动：

```bash
./scripts/stack.sh up     # 会自动生成 .env、构建面板镜像、起整个栈
```

已有的 `auths/`、`config.json`、`data/` 会被继续使用，不需要重新登录。

---

## 四、初始配置

`./scripts/stack.sh init` 会生成 `.env`（模板是 `.env.example`），其中：

- `STACK_DIR` —— **必填项里最重要的一个**，init 会自动填成当前目录的绝对路径。
  `updater` 要按**同一个绝对路径**挂载本目录，compose 里的 `./auths`、`./config.json`
  这类相对路径才能解析成正确的宿主机路径。写错的典型症状是：更新完之后容器挂到了空目录上，
  **账号全没了**。这是本栈最容易踩的坑。
- `WBGUI_PASSWORD` —— 随机生成并追加到 `.env` 末尾（`.env.example` 里不含明文口令）。
- `WGUI_SITE` —— 留空 = caddy 监听 80，用 `http://<服务器IP>/` 访问；填域名 =
  自动签发并续期 Let's Encrypt 证书（域名需已解析到本机、80/443 公网可达）。

面板的全部配置都由 `.env` → compose 的 `WBGUI_*` 环境变量驱动，**不挂载 `config.json` 给面板**：
面板的 `Load()` 是「默认值 → JSON 文件 → 环境变量覆盖」，挂一个 JSON 进去也会被环境变量逐项盖掉，
反而多出一个「改了没反应」的误导源。

> 价格表（把 token 用量换算成官方 API 花费）通过 `WBGUI_PRICING_FILE=/data/pricing.json`
> 指向 `wbgui-data` 卷，因此容器重建不丢。文件不存在时会退回代码内置的 DeepSeek 价目表，
> 不会导致启动失败。

---

## 五、fork 覆盖层机制（重要）

同步时 fork 独有的文件会被硬重置删掉，所以 `sync-upstream.yml` 在重置前把它们快照到临时目录，
重置后原样拷回，再一起提交。**覆盖层清单硬编码在该 workflow 的 `FORK_FILES` 环境变量里。**

```
.github/workflows/sync-upstream.yml   ← 同步与触发构建
.env.example                          ← 栈的环境变量模板
docker-compose.fork.yml               ← 四容器自包含编排
scripts/stack.sh                      ← 宿主机入口（引导 + 运维）
deploy                                ← updater 镜像与脚本、Caddyfile
FORK.md                               ← 本文件
```

`FORK_FILES` 的每一项**可以是文件也可以是目录**（目录整棵保留），所以 `deploy/` 只要写一行。
新增 fork 专属内容时，必须同时把它加进 `FORK_FILES`，否则下一次同步（最多 12 小时后）就会被抹掉。

> 覆盖层条目**缺失会直接中止同步**（`::error::` + 非零退出），不会再往下 force push。
> 因为硬重置已经把它抹掉了，推出去的就是一个「起不来的仓库」。早失败好过事后回滚。

> 细节：仓库 `.gitignore` 里有全局 `*.md` 忽略（只放行 `README.md`）和 `.env.*` 忽略，
> 所以 `FORK.md`、`.env.example` 在同步时是用 `git add -f` 强制入库的；在本地新增它们时也要
> `git add -f`，否则 `git add -A` 会静默跳过。

---

## 六、上线前的两项检查

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

### 2. 确认 workflow 都是启用状态

**fork 里 `build.yml` 的初始状态是 `disabled_fork`（禁用）**，禁用状态下无法被
`workflow_dispatch` 派发，同步链路会在最后一步静默失败。到
`Actions → 左侧选中 Build & Publish → 右侧 Enable workflow` 启用即可。

```bash
gh api repos/TaroCats/workbuddy2api/actions/workflows \
  --jq '.workflows[] | "\(.name)\t\(.state)"'
```

两个都应是 `active`。也可以在 Actions 页顶部横幅点
「I understand my workflows, go ahead and enable them」一次全开。

> 关于仓库的 `Settings → Actions → General → Workflow permissions`：**保持默认的
> Read and write 或 Read 都行**。`sync-upstream.yml` 自带
> `permissions: {contents: write, actions: write}` 显式声明，会覆盖仓库默认值——
> 已在真实运行日志里验证 `GITHUB_TOKEN Permissions: Actions: write, Contents: write`。
> 只有 `master` 开了分支保护时才需要额外允许 force push，否则同步会在 push 那步失败。

### 3. 安全提示：docker.sock

`wbgui` 和 `updater` 都挂载了 `/var/run/docker.sock`（面板的「系统」页要靠它重启网关，
updater 要靠它执行更新）。**挂上它等同于把宿主 Docker 控制权交给该容器（等价宿主 root）**。
不需要面板的一键重启能力，就把 `wbgui` 里那一行删掉，其余功能不受影响。

---

## 七、排障

### 更新相关

| 现象 | 原因 / 处理 |
| --- | --- |
| **更新一次之后账号全没了** | `STACK_DIR` 与实际目录不一致。updater 按同一个绝对路径挂载栈目录，路径不对就会把容器挂到空目录上。跑 `./scripts/stack.sh doctor` 看 `STACK_DIR 一致` 那行 |
| 日志说「取不到当前提交，跳过编排自更新」 | 容器内 git 拒绝操作宿主机属主的仓库（`dubious ownership`）。镜像里已用 `git config --system --add safe.directory '*'` 放行；若你自定义了镜像，需自己加这一条 |
| 日志说「编排仓库 pull 失败」 | 本地有未提交改动 / 历史分叉 / HEAD 不在有跟踪分支上。日志会带出 git 的原话。容器**不会**强行动你的工作区，改完就好 |
| 面板说「账号已添加但网关显示未加载」 | 面板写出的凭证属主不是网关进程的 uid。`WBGUI_AUTH_OWNER_UID=10001` 已设；宿主机侧 `chown -R 10001:10001 ./auths` |
| 更新后健康检查一直不过 → 自动回滚 | 看 `docker logs --tail 100 workbuddy2api`。回滚点标签是 `<仓库>:previous`，也可手动 `./scripts/stack.sh rollback wb2api` |
| 面板登录或写操作报同源/Origin 错误 | 反代没透传 `Host` / `X-Forwarded-Host`。caddy 默认会透传，所以正常不会遇到；自建代理时在 `.env` 里填 `WBGUI_ALLOWED_ORIGINS` |
| caddy 起不来，报 `server block without any key is global configuration` | `WGUI_SITE` 被**设成了空串**并直接交给了 caddy。Caddy 的 `{$VAR:default}` 只在变量**未设置**时才用默认值，空串会让站点块变成无标签块。经 compose 启动时不会发生（那边用 `${WGUI_SITE:-:80}`，空值也会替换）；只有绕过 compose 直接 `caddy run` 才需要自己保证非空 |
| 脚本报 `unbound variable` 且指向某个变量 | 变量后面紧跟了非 ASCII 字节（如中文），bash 会把多字节首字节并进变量名。写脚本时一律用 `${变量}` 而不是 `$变量` |

### CI 相关

| 现象 | 原因 / 处理 |
| --- | --- |
| 同步后 workflow 自己消失了 | `FORK_FILES` 里漏了 `sync-upstream.yml`。手动把文件加回来 |
| 同步任务红叉，报「覆盖层条目在工作区不存在」 | `FORK_FILES` 里写了不存在的路径。这是刻意的硬失败，避免 force push 出一个缺件的仓库 |
| `push --force-with-lease` 被拒 | 远端 `master` 被人改过，或分支保护拦了 force push。看运行日志 |
| 构建没被触发（同步任务却是绿勾） | 派发失败只打 `::warning::`，不会让任务失败——一定要看 job 日志。两个已知原因：① `build.yml` 被禁用（`disabled_fork` / `disabled_manually`），422 拒绝派发；② `gh workflow run` 没带 `--repo`，gh 选中了名为 `upstream` 的 remote，请求打到上游仓库 → `403 Resource not accessible by integration` |
| 宿主机 `docker pull` 403 | GHCR 包还是 private，见上面第 1 条 |

---

## 八、验证记录

### 第一轮：2026-09-28 首次真机实跑（CI 链路）

| 环节 | 证据 |
| --- | --- |
| 同步 | `Sync Upstream #1` / `#2` 均 success；`内容与同步前一致，跳过提交与推送`（幂等生效，未产生空提交） |
| 派发 | `#2` 日志输出 `https://github.com/TaroCats/workbuddy2api/actions/runs/36389184456` |
| 构建 | `Build & Publish #1` success，5m40s，多架构 `linux/amd64,linux/arm64` |
| 产物 | `ghcr.io/tarocats/workbuddy2api:latest` = `:89ea76d…`，index digest `sha256:7874380d…`；另附 amd64 离线 tar.gz artifact |
| 可见性 | 匿名可取 token / 列 tag / 读 manifest（均 200）→ 包是 public，宿主机可直接 pull |

首次实跑揪出了两个本地测不出的 bug（`build.yml` 在 fork 里是 `disabled_fork`；`gh workflow run`
未带 `--repo` 导致请求打到上游仓库被 403 拒绝），已在 `fix(ci)` 提交中修复。

### 第二轮：四容器栈的离线验证

本机没有 Docker，所以更新器是用**假 docker CLI + 真 git** 跑的：假 CLI 只把
`docker` 子命令记成日志并用文件模拟容器/镜像状态，git 是真的。这样能把**控制流**（分支选择、
回滚触发、幂等跳过、派发 helper）完整走一遍。

| 被测对象 | 方式 | 结果 |
| --- | --- | --- |
| `deploy/updater/stack-update.sh` | 16 个场景（A–P） | 57 条断言全部通过 |
| `sync-upstream.yml` 的同步逻辑 | 真 git 双仓库（fork / upstream 分离）复现 | 20 条断言全部通过 |
| `scripts/stack.sh` 的 helper | 单元测试（含带 `&`/`\|`/`\` 的路径） | 13 条断言全部通过 |
| `docker-compose.fork.yml` | 真实 `docker compose config`（独立二进制 v5.5.1） | 解析通过；`auths` 两容器指向同一宿主机路径、`config.json` 同一文件、`SELF_IMAGE` 与 updater 镜像名一致 |
| `deploy/caddy/Caddyfile` | 真实 `caddy validate` + 解析 | `Valid configuration`；留空监听 `:80`，填域名监听 `:443` |

更新器覆盖的关键分支：首次启动、镜像未变跳过、有新镜像且健康、新镜像不健康自动回滚、
源码模式首克隆/未变跳过/有新提交重建/构建失败不重建且不记版本、`--dry-run` 零副作用、
`--rollback`、编排更新时配置校验不过必须回退且不派发 helper、配置合法派发 detached helper、
`pull` 失败跳过且不动 HEAD、目录不是 git 仓库时跳过。

> 验证过程中被判定为**测试沙盘自身缺陷**（而非脚本缺陷）的三处，已修正并留档：
> 假 CLI 的 `tag` 不支持用镜像 ID 作源；沙盘的 sandbox 仓库默认分支不是 `master`
> 导致 `git pull` 永远失败；断言在 `cmd.log` 里找日志行（日志走 stdout，不走 docker 调用记录）。
