# syntax=docker/dockerfile:1
# ─────────────────────────────────────────────────────────────────────────────
# 栈的更新执行器镜像
#
# 里面没有任何业务代码，只负责「检查 → 拉取/构建 → 重建 → 健康检查 → 回滚」。
# 它通过挂进来的 /var/run/docker.sock 指挥宿主机的 Docker 守护进程，因此：
#   · 宿主机上不需要 cron、不需要 git、不需要 go/node —— 只要 docker
#   · 真正的更新逻辑在 stack-update.sh 里（同目录），容器内执行
#
# 为什么需要这个独立容器：容器无法可靠地重建自己。`docker compose
# up --force-recreate <自己>` 会先停掉目标容器，而发起命令的进程就在那个容器里，
# 会在 stop 这一步被一起杀掉，后面的 create 永远执行不到 —— 结果是服务停着起不来。
# 交给本容器代劳就绕开了这个死结（更新「编排文件自身」时另用 docker run
# 派发一个 detached helper，见 stack-update.sh 的 update_orchestration）。
#
# 构建上下文刻意就是本目录（deploy/updater）：
#   compose 里写的是 `context: ./deploy/updater`。这样整个仓库的 auths/、data/、
#   src/ 都不会被当成构建上下文传进 daemon —— 那些目录可能有几百 MB 凭证与源码，
#   而且仓库根目录的 .dockerignore 是上游文件，本 fork 不能改（硬重置会覆盖）。
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:3.20

# docker-cli + docker-cli-compose：指挥守护进程（Alpine 3.20 community 提供，实测 v2.27）
# git：拉取 GUI 源码；tzdata：日志时间正确；bash：stack-update.sh 的运行时
# （bash 必须装 —— 脚本用了 ${!var} 间接展开，busybox ash 不支持，跑起来会直接报错）
# curl：容器里唯一方便排障的工具（验证 GHCR/上游仓库连通性），体积可忽略
RUN apk add --no-cache \
      docker-cli \
      docker-cli-compose \
      git \
      tzdata \
      bash \
      curl \
 && rm -rf /var/cache/apk/*

# git 从 2.35.2 起（CVE-2022-24765）拒绝操作「属主不是当前用户」的仓库，root 也不例外。
# 本容器以 root 运行，而挂进来的栈目录属主是宿主机用户（1000/501…），于是
# `git -C "$PROJECT_DIR" rev-parse HEAD` 会直接 fatal: detected dubious ownership。
# 后果是编排自更新静默失效 —— 表现为日志里一句「取不到当前提交，跳过编排自更新」，
# 而服务本身照常更新，极难联想到权限。这里显式放行。
RUN git config --system --add safe.directory '*'

ENV HOME=/root

COPY stack-update.sh /usr/local/bin/stack-update.sh
RUN chmod 755 /usr/local/bin/stack-update.sh

# 以 root 运行：挂载 docker.sock 本身就等价于宿主 root（root 进程本来就能
# `docker run -v /:/host` 拿到宿主文件系统），降权只是姿态而非实质。真正该
# 收紧的地方是不需要时不要挂 docker.sock。
ENTRYPOINT ["/usr/local/bin/stack-update.sh"]
CMD ["--loop"]
