#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 容器内自更新执行器
#
# 跑在 updater 容器里，只通过 /var/run/docker.sock 指挥宿主机的 Docker 守护进程。
# 宿主机上**不需要任何 cron** —— 更新的判断与执行整体都在容器内完成。
#
# 两类更新源：
#   pull   从镜像仓库拉取（wb2api 的镜像由 GitHub Actions 构建并推送到 GHCR）
#   build  从 git 源码构建（wbgui 上游只提供源码，没有现成镜像）
#
# 单个服务的更新流程固定为：
#   记下当前镜像 → 取到新镜像 → 有变化才重建 → 等健康检查通过 → 不通过则回滚
#
# 为什么更新由一个独立容器执行，而不是每个容器更新自己：
#   容器无法可靠地重建自己。`docker compose up --force-recreate <自己>` 会先停掉
#   目标容器，而发起这条命令的进程就在那个容器里 —— 它会在 stop 这一步被一起杀掉，
#   后面的 create 永远执行不到，结果是服务停着起不来。所以由本容器代劳。
#   （同样原因，「编排文件自更新」也用 docker run 派发一个 detached helper 去做，
#     helper 不是被重建的容器，不会中途被杀。）
#
# 用法：
#   stack-update.sh --loop             常驻循环（compose 里的默认命令）
#   stack-update.sh --once             所有服务检查一遍就退出
#   stack-update.sh --once --only wbgui
#   stack-update.sh --dry-run          只报告会做什么，不实际动手
#   stack-update.sh --rollback wbgui   回滚到上一个已知可用的镜像
#   stack-update.sh --status           打印各服务当前镜像与版本记录
#   stack-update.sh --help
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# ── 配置（全部可由环境变量覆盖，见 docker-compose.fork.yml）────────────────
PROJECT_DIR="${PROJECT_DIR:-/stack}"                        # 与宿主机同路径挂载
COMPOSE_FILE="${COMPOSE_FILE:-${PROJECT_DIR}/docker-compose.fork.yml}"
STATE_DIR="${STATE_DIR:-/state}"                            # 持久化命名卷
SERVICES="${SERVICES:-wb2api wbgui}"                        # 顺序即更新顺序
UPDATE_INTERVAL="${UPDATE_INTERVAL:-21600}"                 # 秒，默认 6 小时
INITIAL_DELAY="${INITIAL_DELAY:-30}"                        # 启动后先等一会儿（避开开机风暴）
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"                     # 单服务健康检查超时（秒）
SELF_UPDATE="${SELF_UPDATE:-1}"                             # 是否让编排文件也自动跟随
SELF_IMAGE="${SELF_IMAGE:-workbuddy-stack-updater:local}"
LOG_KEEP="${LOG_KEEP:-5}"                                   # 保留多少份更新记录
HELPER_WAIT="${HELPER_WAIT:-90}"                            # 派发 helper 后等自己被重建的秒数

DRY_RUN=0
ONLY=""
MODE="loop"
ROLLBACK_SVC=""

# 每个服务的参数按「服务名转大写下划线_键名」从环境变量读取，例如：
#   wb2api  → WB2API_MODE / WB2API_IMAGE / ...
#   wbgui   → WBGUI_MODE  / WBGUI_REPO  / WBGUI_REF / WBGUI_SRC / WBGUI_IMAGE
# 因此新增一个服务只要加环境变量，不需要改本脚本的逻辑。
cfg() { # cfg <svc> <KEY> [默认值]
  local svc key def var
  svc="$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"
  key="$2"
  def="${3:-}"
  var="${svc}_${key}"
  printf '%s' "${!var:-$def}"
}

# ── 日志 ────────────────────────────────────────────────────────────────────
log()  { printf '%s INFO  %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '%s WARN  %s\n' "$(date '+%F %T')" "$*"; }
err()  { printf '%s ERROR %s\n' "$(date '+%F %T')" "$*" >&2; }

die() { err "$*"; exit 1; }

# ── 小工具 ──────────────────────────────────────────────────────────────────
short_id() { # sha256:abcdef... → abcdef123456
  local s="${1#sha256:}"
  printf '%s' "${s:0:12}"
}

repo_of() { # 去掉 tag，留仓库名：ghcr.io/a/b:latest → ghcr.io/a/b
  local ref="$1"
  case "${ref##*/}" in
    *:*) printf '%s' "${ref%:*}" ;;
    *)   printf '%s' "$ref" ;;
  esac
}

compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$PROJECT_DIR" "$@"
}

container_of() { # 服务对应的容器 ID；空 = 未创建/未运行
  compose ps -q "$1" 2>/dev/null | head -n1
}

running_image_id() {
  local cid
  cid="$(container_of "$1")"
  [ -n "$cid" ] || return 1
  docker inspect --format '{{.Image}}' "$cid" 2>/dev/null
}

image_id() { docker image inspect --format '{{.Id}}' "$1" 2>/dev/null; }

# 把当前镜像留一份 :previous 标签，供 --rollback 使用
tag_previous() {
  local ref="$1" id="$2"
  local prev="$(repo_of "$ref"):previous"
  docker tag "$id" "$prev" >/dev/null 2>&1 \
    || warn "留档 $prev 失败（回滚能力受影响）"
}

record() { # 追加一行更新记录（只保留最近 LOG_KEEP 行）
  local f="${STATE_DIR}/history.log"
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$f" 2>/dev/null
  if [ -f "$f" ]; then
    tail -n "$LOG_KEEP" "$f" > "${f}.tmp" 2>/dev/null && mv "${f}.tmp" "$f" 2>/dev/null
  fi
}

# ── 健康检查门 ──────────────────────────────────────────────────────────────
# 镜像自带 HEALTHCHECK 的（wb2api / wbgui 都有）用 .State.Health.Status；
# 没有的退回到 .State.Status。网关的 /healthz 在「池里没有健康账号」时返回 503，
# 但 wget 对 503 仍算成功 —— 也就是说进程起来了就算健康，这正是我们想要的语义。
wait_healthy() { # wait_healthy <svc> [超时秒]
  local svc="$1" timeout="${2:-$HEALTH_TIMEOUT}" waited=0 cid status
  while [ "$waited" -lt "$timeout" ]; do
    cid="$(container_of "$svc")"
    if [ -z "$cid" ]; then
      warn "[$svc] 容器不存在，可能在重建中…"
    else
      status="$(docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$cid" 2>/dev/null)"
      case "$status" in
        healthy|running)
          return 0 ;;
        unhealthy)
          err "[$svc] 容器报告 unhealthy（等了 ${waited}s）"
          return 1 ;;
        exited|dead)
          err "[$svc] 容器已退出（status=${status}）"
          return 1 ;;
      esac
    fi
    sleep 3
    waited=$((waited + 3))
  done
  err "[$svc] 健康检查超时（${timeout}s，最后状态 '${status:-未知}'）"
  return 1
}

dump_logs() { # 失败时给出第一手线索，省得再去翻 docker logs
  local svc="$1"
  err "[$svc] 最近 30 行日志："
  compose logs --tail 30 "$svc" 2>&1 | sed 's/^/    /' >&2 || true
}

recreate() {
  log "重建服务 $1 …"
  compose up -d --no-deps --no-build --force-recreate "$1"
}

apply_new_image() { # apply_new_image <svc> <ref> <旧镜像ID>
  local svc="$1" ref="$2" old_id="$3"

  [ -n "$old_id" ] && tag_previous "$ref" "$old_id"

  recreate "$svc" || { err "[$svc] 重建命令失败"; dump_logs "$svc"; return 1; }

  if wait_healthy "$svc"; then
    return 0
  fi

  dump_logs "$svc"
  if [ -z "$old_id" ]; then
    err "[$svc] 首次启动即不健康，没有可回滚的旧镜像可退"
    return 1
  fi
  err "[$svc] 新版本不健康，回滚到 $(short_id "$old_id")"
  if docker tag "$(repo_of "$ref"):previous" "$ref" >/dev/null 2>&1 && recreate "$svc"; then
    if wait_healthy "$svc"; then
      warn "[$svc] 已回滚到 $(short_id "$old_id")，服务恢复正常"
      record "$svc 回滚 old=$(short_id "$old_id")"
      return 1
    fi
    err "[$svc] 回滚后仍不健康，需要人工介入"
  else
    err "[$svc] 回滚失败，需要人工介入"
  fi
  return 1
}

# ── pull 模式：镜像来自仓库 ──────────────────────────────────────────────────
update_pull() { # update_pull <svc> <镜像ref>
  local svc="$1" ref="$2" old_id new_id

  old_id="$(running_image_id "$svc")" || old_id=""

  log "[$svc] 拉取 $ref"
  if [ "$DRY_RUN" = 1 ]; then
    log "[$svc] dry-run：跳过实际拉取与重建"
    return 0
  fi
  if ! docker pull -q "$ref" >/dev/null 2>&1; then
    err "[$svc] 拉取失败：${ref}（镜像仓库下架/改名/网络不通）"
    return 1
  fi
  new_id="$(image_id "$ref")"
  [ -n "$new_id" ] || { err "[$svc] 拉取后仍取不到镜像 ID"; return 1; }

  if [ -z "$old_id" ]; then
    log "[$svc] 容器尚未运行，直接以 $(short_id "$new_id") 启动"
    apply_new_image "$svc" "$ref" ""
    return $?
  fi

  if [ "$new_id" = "$old_id" ]; then
    log "[$svc] 已是最新（$(short_id "$new_id")），跳过重建"
    return 0
  fi

  log "[$svc] 发现新镜像 $(short_id "$old_id") → $(short_id "$new_id")"
  if apply_new_image "$svc" "$ref" "$old_id"; then
    log "[$svc] 更新成功"
    record "$svc 更新 $(short_id "$old_id") → $(short_id "$new_id")"
    return 0
  fi
  return 1
}

# ── build 模式：镜像从 git 源码构建 ─────────────────────────────────────────
update_build() { # update_build <svc> <镜像ref> <git仓库> <分支> <源码相对路径>
  local svc="$1" ref="$2" repo="$3" branch="$4" srcrel="$5"
  local src="${PROJECT_DIR}/${srcrel}"
  local sha_file="${STATE_DIR}/${svc}.commit"
  local build_log="${STATE_DIR}/build-${svc}.log"
  local remote_sha old_id new_id

  remote_sha="$(git ls-remote "$repo" "$branch" 2>/dev/null | awk 'NR==1{print $1}')"
  if [ -z "$remote_sha" ]; then
    warn "[$svc] 取不到 $repo 的 ${branch}（网络问题？），本轮跳过"
    return 0
  fi

  old_id="$(running_image_id "$svc")" || old_id=""

  if [ -f "$sha_file" ] && [ "$(cat "$sha_file")" = "$remote_sha" ] && [ -n "$old_id" ]; then
    log "[$svc] 源码未更新（${remote_sha:0:7}），跳过"
    return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    log "[$svc] dry-run：将拉取 ${remote_sha:0:7} 并构建重建（源码目录 ${src}）"
    return 0
  fi

  # 1) 取源码。用分支名 fetch 再 reset 到 FETCH_HEAD —— 比按 sha fetch 稳
  #    （GitHub 不保证允许按任意 sha 取）。
  if [ -d "$src/.git" ]; then
    log "[$svc] 更新源码 ${repo}@${branch} → ${remote_sha:0:7}"
    if ! git -C "$src" fetch --depth 1 --quiet origin "$branch"; then
      warn "[$svc] fetch 失败，本轮跳过"
      return 0
    fi
    git -C "$src" reset --hard --quiet FETCH_HEAD || { err "[$svc] reset 失败"; return 1; }
  else
    log "[$svc] 首次克隆源码 ${repo}@${branch} → $src"
    mkdir -p "$(dirname "$src")"
    rm -rf "$src"
    if ! git clone --depth 1 --quiet --branch "$branch" "$repo" "$src"; then
      err "[$svc] 克隆失败：$repo"
      return 1
    fi
  fi

  [ -f "$src/Dockerfile" ] || { err "[$svc] 源码里没有 Dockerfile：$src/Dockerfile"; return 1; }

  # 2) 构建。输出写文件，失败时只抛尾部，避免把日志刷爆
  log "[$svc] 构建镜像 ${ref}（源码 ${remote_sha:0:7}）"
  if ! docker build --tag "$ref" --file "$src/Dockerfile" "$src" >"$build_log" 2>&1; then
    err "[$svc] 构建失败，$build_log 尾部："
    tail -n 25 "$build_log" 2>/dev/null | sed 's/^/    /' >&2
    return 1
  fi

  new_id="$(image_id "$ref")"
  [ -n "$new_id" ] || { err "[$svc] 构建后取不到镜像 ID"; return 1; }

  # 3) 源码确实是新的、但镜像内容一致 → 不用重建
  if [ -n "$old_id" ] && [ "$new_id" = "$old_id" ]; then
    log "[$svc] 镜像内容未变（$(short_id "$new_id")），只更新版本记录"
    printf '%s' "$remote_sha" > "$sha_file"
    return 0
  fi

  if [ -z "$old_id" ]; then
    log "[$svc] 容器尚未运行，直接以 $(short_id "$new_id") 启动"
    if apply_new_image "$svc" "$ref" ""; then
      printf '%s' "$remote_sha" > "$sha_file"
      return 0
    fi
    return 1
  fi

  log "[$svc] 新镜像 $(short_id "$old_id") → $(short_id "$new_id")"
  if apply_new_image "$svc" "$ref" "$old_id"; then
    log "[$svc] 更新成功"
    printf '%s' "$remote_sha" > "$sha_file"
    record "$svc 更新 $(short_id "$old_id") → $(short_id "$new_id") @${remote_sha:0:7}"
    return 0
  fi
  # 回滚过的就不要记 sha，否则下一轮会以为「已是最新」而不再重试
  err "[$svc] 更新失败（已尝试回滚），不记录版本，下一轮会重试"
  return 1
}

dispatch_service() { # dispatch_service <svc>
  local svc="$1" mode ref
  mode="$(cfg "$svc" MODE pull)"
  ref="$(cfg "$svc" IMAGE "")"
  [ -n "$ref" ] || { err "[$svc] 未配置 ${svc^^}_IMAGE"; return 1; }

  case "$mode" in
    pull)
      update_pull "$svc" "$ref"
      ;;
    build)
      local repo branch srcrel
      repo="$(cfg "$svc" REPO "")"
      branch="$(cfg "$svc" REF master)"
      srcrel="$(cfg "$svc" SRC "src/${svc}")"
      [ -n "$repo" ] || { err "[$svc] build 模式必须配 ${svc^^}_REPO"; return 1; }
      update_build "$svc" "$ref" "$repo" "$branch" "$srcrel"
      ;;
    *)
      err "[$svc] 未知的 MODE：${mode}（只支持 pull / build）"
      return 1
      ;;
  esac
}

# ── 回滚 ────────────────────────────────────────────────────────────────────
do_rollback() {
  local svc="$1" ref prev
  ref="$(cfg "$svc" IMAGE "")"
  [ -n "$ref" ] || die "未配置 ${svc^^}_IMAGE"
  prev="$(repo_of "$ref"):previous"
  docker image inspect "$prev" >/dev/null 2>&1 \
    || die "没有可回滚的镜像 ${prev}（还没发生过一次成功更新）"
  log "[$svc] 回滚：$prev → $ref"
  docker tag "$prev" "$ref" || die "打标签失败"
  recreate "$svc" || die "重建失败"
  wait_healthy "$svc" || die "回滚后仍不健康，请人工检查"
  log "[$svc] 回滚完成"
  record "$svc 手动回滚"
}

# ── 编排文件自更新 ──────────────────────────────────────────────────────────
# 本项目自身的编排（compose / Caddyfile / updater 脚本）也应该跟着 fork 走，
# 否则部署机会永远停在第一次 clone 的版本上。风险在于「新配置是坏的」 ——
# 所以先用 docker compose config 校验，不通过就立刻 git 退回，绝不带着坏配置重建。
update_orchestration() {
  [ "$SELF_UPDATE" = 1 ] || return 0

  if [ ! -d "${PROJECT_DIR}/.git" ]; then
    warn "项目目录不是 git 仓库，跳过编排自更新"
    return 0
  fi

  local before after
  before="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)"
  if [ -z "$before" ]; then
    # 这里最常见的真实原因是容器内 git 拒绝操作宿主机属主的仓库
    # （dubious ownership）—— 那种情况下一句「跳过」会让人查到怀疑人生，
    # 所以把 git 的原话原样打出来。
    warn "取不到当前提交，跳过编排自更新。git 说："
    git -C "$PROJECT_DIR" rev-parse HEAD 2>&1 | sed 's/^/    /' >&2 || true
    return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    log "dry-run：将 git pull 编排文件并校验"
    return 0
  fi

  local pull_err
  if ! pull_err="$(git -C "$PROJECT_DIR" pull --ff-only --quiet 2>&1)"; then
    warn "编排仓库 pull 失败，跳过编排自更新。git 说："
    printf '%s\n' "$pull_err" | sed 's/^/    /' >&2
    warn "（常见原因：本地有未提交改动、历史分叉、或当前 HEAD 不在有跟踪分支上）"
    return 0
  fi

  after="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)"
  if [ "$before" = "$after" ]; then
    log "编排文件无更新"
    return 0
  fi
  log "编排文件有更新：${before:0:7} → ${after:0:7}"

  # 硬门槛：新配置解析不过就回退，不赌
  if ! compose config -q >"${STATE_DIR}/compose-validate.log" 2>&1; then
    err "新编排文件校验失败，已回退到 ${before:0:7}。原因："
    tail -n 15 "${STATE_DIR}/compose-validate.log" 2>/dev/null | sed 's/^/    /' >&2
    git -C "$PROJECT_DIR" reset --hard --quiet "$before"
    return 1
  fi

  # 重建 updater 自身镜像（脚本改了才需要），再派发 detached helper 重建整个栈。
  # helper 是独立容器，不会被它要重建的容器拖死。
  if ! docker build --tag "$SELF_IMAGE" "${PROJECT_DIR}/deploy/updater" \
       >"${STATE_DIR}/build-updater.log" 2>&1; then
    err "updater 镜像构建失败，已回退到 ${before:0:7}："
    tail -n 20 "${STATE_DIR}/build-updater.log" 2>/dev/null | sed 's/^/    /' >&2
    git -C "$PROJECT_DIR" reset --hard --quiet "$before"
    return 1
  fi

  local helper="wb-stack-selfupdate"
  docker rm -f "$helper" >/dev/null 2>&1 || true
  log "派发 detached helper 重建整个栈（本容器随后会被它重建）"
  if ! docker run -d --rm --name "$helper" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "${PROJECT_DIR}:${PROJECT_DIR}" \
        -e "PROJECT_DIR=${PROJECT_DIR}" \
        --entrypoint /bin/sh "$SELF_IMAGE" -c "
          sleep 5
          cd '${PROJECT_DIR}' || exit 1
          docker compose -f '${COMPOSE_FILE}' --project-directory '${PROJECT_DIR}' \
            up -d --remove-orphans --no-build
        " >/dev/null 2>&1; then
    err "派发 helper 失败，本容器未重建；下一轮会重试"
    return 1
  fi
  record "编排更新 ${before:0:7} → ${after:0:7}"
  # 等 helper 把我们干掉；真被干掉就不会走到这里
  sleep "$HELPER_WAIT"
  warn "helper 未在预期时间内重建本容器，继续下一轮"
}

# ── status ──────────────────────────────────────────────────────────────────
show_status() {
  printf '%-10s %-10s %-14s %s\n' 服务 模式 当前镜像 容器状态
  local svc mode ref cid id
  for svc in $SERVICES; do
    mode="$(cfg "$svc" MODE pull)"
    ref="$(cfg "$svc" IMAGE "-")"
    cid="$(container_of "$svc")"
    if [ -n "$cid" ]; then
      id="$(short_id "$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null)")"
      printf '%-10s %-10s %-14s %s\n' "$svc" "$mode" "$id" \
        "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null)"
    else
      printf '%-10s %-10s %-14s %s\n' "$svc" "$mode" "-" "未运行（${ref}）"
    fi
  done
  echo
  echo "更新记录（最近 ${LOG_KEEP} 条）："
  if [ -f "${STATE_DIR}/history.log" ]; then
    sed 's/^/  /' "${STATE_DIR}/history.log"
  else
    echo "  （还没有过一次更新）"
  fi
}

# ── 参数解析 ────────────────────────────────────────────────────────────────
usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,2\} \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --loop)          MODE="loop" ;;
    --once)          MODE="once" ;;
    --dry-run)       DRY_RUN=1 ;;
    --only)          ONLY="${2:?--only 需要一个服务名}"; shift ;;
    --rollback)      MODE="rollback"; ROLLBACK_SVC="${2:?--rollback 需要一个服务名}"; shift ;;
    --status)        MODE="status" ;;
    --initial-delay) INITIAL_DELAY="${2:?}"; shift ;;
    -h|--help)       usage ;;
    *) die "未知参数：${1}（用 --help 看用法）" ;;
  esac
  shift
done

mkdir -p "$STATE_DIR" 2>/dev/null
command -v docker >/dev/null 2>&1 || die "镜像里没有 docker CLI，无法工作"
[ -f "$COMPOSE_FILE" ] || die "找不到编排文件：${COMPOSE_FILE}（PROJECT_DIR 挂载对了吗？）"

case "$MODE" in
  status)
    show_status
    exit 0
    ;;
  rollback)
    do_rollback "$ROLLBACK_SVC"
    exit $?
    ;;
esac

# ── 主流程 ──────────────────────────────────────────────────────────────────
run_round() {
  local svc rc=0
  log "── 开始一轮检查（服务：${ONLY:-$SERVICES}）──"

  # 编排文件优先：它变了，后面的服务定义可能都变了
  if [ -z "$ONLY" ]; then
    update_orchestration || rc=1
  fi

  for svc in ${ONLY:-$SERVICES}; do
    if ! dispatch_service "$svc"; then
      rc=1
    fi
  done

  if [ "$rc" = 0 ]; then
    log "── 本轮完成，全部正常 ──"
  else
    warn "── 本轮完成，有服务未能更新成功（见上面的 ERROR）──"
  fi
  return $rc
}

if [ "$MODE" = "once" ]; then
  run_round
  exit $?
fi

log "容器内自更新已启动：间隔 ${UPDATE_INTERVAL}s，服务 [${SERVICES}]，编排自更新=$([ "$SELF_UPDATE" = 1 ] && echo 开 || echo 关)"
log "首次检查将在 ${INITIAL_DELAY}s 后开始"
sleep "$INITIAL_DELAY"

while :; do
  run_round || true   # 单轮失败不能让循环退出，下一轮继续重试
  log "下一轮检查在 ${UPDATE_INTERVAL}s 后"
  sleep "$UPDATE_INTERVAL"
done
