#!/usr/bin/env bash
#
# selfupdate.sh —— 宿主机自更新：拉取 GHCR 上的最新镜像，有更新就重建容器。
#
# 闭环：上游有新提交 → Actions(sync-upstream.yml) 同步并触发构建 → GHCR 上 latest 更新
#       → 本脚本（cron 定时跑）检测到新镜像 → 重建容器并做健康检查。
#
# 之所以放在宿主机而不是容器内：容器要自己重建自己就得挂载 docker.sock，等于把宿主机
# root 权限交给业务容器。宿主机 cron 只需要 docker CLI，权限面小得多。
#
# 用法：
#   ./scripts/selfupdate.sh                 # 有更新就重建（默认行为）
#   ./scripts/selfupdate.sh --check         # 只检查，不重建（有更新退出码 10，无更新 0）
#   ./scripts/selfupdate.sh --force         # 即使镜像没变也强制重建
#   ./scripts/selfupdate.sh --dry-run       # 打印将要执行的命令，不做任何改动
#   ./scripts/selfupdate.sh --print-cron    # 只打印 crontab 条目
#   ./scripts/selfupdate.sh --install-cron  # 安装/刷新 crontab 条目（会先备份原 crontab）
#
# 常用选项：
#   -q, --quiet           静默（只写日志文件，不输出到终端 —— cron 用这个）
#       --no-prune        不清理被替换下来的旧镜像
#       --image REF       指定镜像（默认 ghcr.io/tarocats/workbuddy2api:latest）
#       --log FILE        指定日志文件（默认 <仓库>/data/selfupdate.log）
#   -h, --help            显示帮助
#
# 环境变量（优先级低于同名命令行选项）：
#   WB2API_IMAGE / WB2API_CONTAINER / WB2API_SERVICE / WB2API_HEALTH_URL
#   WB2API_UPDATE_LOG / WB2API_CRON_SCHEDULE
#
# 退出码：0 成功；1 出错；10 --check 模式下发现可用更新

set -euo pipefail

# ---------------------------------------------------------------- 基本路径与默认值

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

IMAGE="${WB2API_IMAGE:-ghcr.io/tarocats/workbuddy2api:latest}"
CONTAINER="${WB2API_CONTAINER:-workbuddy2api}"
SERVICE="${WB2API_SERVICE:-wb2api}"
HEALTH_URL="${WB2API_HEALTH_URL:-http://127.0.0.1:7863/healthz}"
LOG_FILE="${WB2API_UPDATE_LOG:-${REPO_DIR}/data/selfupdate.log}"
CRON_SCHEDULE="${WB2API_CRON_SCHEDULE:-23 */6 * * *}"
CRON_MARK="# wb2api-selfupdate"

BASE_COMPOSE="docker-compose.yml"
FORK_COMPOSE="docker-compose.fork.yml"

MODE="update"          # update | check
DRY_RUN=0
QUIET=0
FORCE=0
PRUNE=1
ASSUME_YES=0
PRINT_CRON=0
INSTALL_CRON=0
HEALTH_TIMEOUT=90      # 秒

# ---------------------------------------------------------------- 日志

log() {
  local level="$1"; shift
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*"
  if [ -n "${LOG_FILE:-}" ]; then
    mkdir -p "$(dirname -- "${LOG_FILE}")" 2>/dev/null || true
    printf '%s\n' "${line}" >> "${LOG_FILE}" || true
  fi
  if [ "${QUIET}" -eq 0 ]; then
    if [ "${level}" = "ERROR" ]; then
      printf '%s\n' "${line}" >&2
    else
      printf '%s\n' "${line}"
    fi
  fi
}

die() { log ERROR "$*"; exit 1; }

rotate_log() {
  [ -f "${LOG_FILE}" ] || return 0
  local size
  size="$(wc -c < "${LOG_FILE}" | tr -d ' ')"
  if [ "${size}" -gt 1048576 ]; then
    mv -f "${LOG_FILE}" "${LOG_FILE}.1" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------- 参数解析

usage() {
  # 打印文件头的注释块（第 2 行起，遇到第一条非注释行即停）
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check)        MODE="check" ;;
    --force)        FORCE=1 ;;
    --dry-run)      DRY_RUN=1 ;;
    -q|--quiet)     QUIET=1 ;;
    --no-prune)     PRUNE=0 ;;
    --yes|-y)       ASSUME_YES=1 ;;
    --print-cron)   PRINT_CRON=1 ;;
    --install-cron) INSTALL_CRON=1 ;;
    --image)        IMAGE="${2:?--image 需要一个值}"; shift ;;
    --log)          LOG_FILE="${2:?--log 需要一个值}"; shift ;;
    --health-url)   HEALTH_URL="${2:?--health-url 需要一个值}"; shift ;;
    -h|--help)      usage ;;
    *) die "未知参数：$1（用 --help 看用法）" ;;
  esac
  shift
done

# ---------------------------------------------------------------- crontab 条目

cron_line() {
  printf '%s cd %s && %s --quiet >/dev/null 2>&1 %s' \
    "${CRON_SCHEDULE}" "${REPO_DIR}" "${SCRIPT_DIR}/selfupdate.sh" "${CRON_MARK}"
}

show_cron() {
  printf '建议的 crontab 条目（每 6 小时检查一次，可自行改 CRON_SCHEDULE）：\n\n'
  printf '  %s\n\n' "$(cron_line)"
  printf '安装：./scripts/selfupdate.sh --install-cron\n'
  printf '提示：cron 环境变量极简，脚本已用绝对路径，无需额外配置。\n'
}

install_cron() {
  command -v crontab >/dev/null 2>&1 || die "本机没有 crontab 命令，请改用其他调度器（systemd timer / launchd）"

  local line existing backup tmp answer
  line="$(cron_line)"

  printf '将写入以下 crontab 条目：\n\n  %s\n\n' "${line}"

  if [ "${ASSUME_YES}" -eq 0 ]; then
    if [ -t 0 ]; then
      printf '确认写入？[y/N] '
      read -r answer || answer=""
      case "${answer}" in
        y|Y|yes|YES) ;;
        *) log INFO "已取消，未修改 crontab"; return 0 ;;
      esac
    else
      log INFO "非交互环境，未修改 crontab。确认后请加 --yes：./scripts/selfupdate.sh --install-cron --yes"
      return 0
    fi
  fi

  mkdir -p "${REPO_DIR}/data"
  backup="${REPO_DIR}/data/crontab.bak"
  crontab -l > "${backup}" 2>/dev/null || true
  printf '原 crontab 已备份到 %s\n' "${backup}"

  tmp="$(mktemp)"
  existing="$(crontab -l 2>/dev/null || true)"
  if [ -n "${existing}" ]; then
    printf '%s\n' "${existing}" | grep -F -v "${CRON_MARK}" > "${tmp}" || true
  fi
  printf '%s\n' "${line}" >> "${tmp}"

  if [ "${DRY_RUN}" -eq 1 ]; then
    printf '\n[dry-run] 将要安装的 crontab 内容：\n'
    cat "${tmp}"
    rm -f "${tmp}"
    return 0
  fi

  crontab "${tmp}" || die "写入 crontab 失败"
  rm -f "${tmp}"
  log INFO "已安装 crontab 条目：${line}"
  log INFO "查看：crontab -l"
}

if [ "${PRINT_CRON}" -eq 1 ]; then show_cron; exit 0; fi
if [ "${INSTALL_CRON}" -eq 1 ]; then rotate_log; install_cron; exit 0; fi

# ---------------------------------------------------------------- 前置检查

rotate_log

command -v docker >/dev/null 2>&1 || die "未找到 docker 命令"

COMPOSE=()
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  die "未找到 docker compose（v2 插件或 v1 均不可用）"
fi

COMPOSE_FILES=(-f "${BASE_COMPOSE}")
if [ -f "${FORK_COMPOSE}" ]; then
  COMPOSE_FILES+=(-f "${FORK_COMPOSE}")
else
  die "缺少 ${FORK_COMPOSE}：基础 compose 只有 build: 没有 image:，compose 会用本地镜像名，无法对接 GHCR。请从仓库拉取该文件。"
fi

run() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    log INFO "[dry-run] $*"
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------- 1. 当前镜像

current_image_id="$(docker inspect --format '{{.Image}}' "${CONTAINER}" 2>/dev/null || true)"
container_running=0
if [ -n "${current_image_id}" ]; then
  if [ "$(docker inspect --format '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || echo false)" = "true" ]; then
    container_running=1
  fi
  log INFO "当前容器 ${CONTAINER} 所用镜像：${current_image_id}"
else
  log INFO "未找到运行中的容器 ${CONTAINER}，本次将直接创建"
fi

# ---------------------------------------------------------------- 2. 拉取最新镜像

log INFO "拉取 ${IMAGE} …"
if ! run docker pull "${IMAGE}"; then
  log ERROR "拉取失败。常见原因："
  log ERROR "  · GHCR 包还是 private —— 到 GitHub → 你的 Packages → workbuddy2api → Package settings 改成 Public；"
  log ERROR "  · 或先登录：docker login ghcr.io -u <用户名> -p <带 read:packages 的 PAT>"
  log ERROR "  · 该 tag 还没被 CI 构建过 —— 到 Actions 页手动跑一次 Build & Publish"
  exit 1
fi

if [ "${DRY_RUN}" -eq 1 ]; then
  new_image_id="unknown(dry-run)"
else
  new_image_id="$(docker image inspect --format '{{.Id}}' "${IMAGE}")"
  log INFO "远端最新镜像：${new_image_id}"
fi

# ---------------------------------------------------------------- 3. 判断是否需要重建

need_update=0
reason=""
if [ -z "${current_image_id}" ]; then
  need_update=1; reason="容器不存在"
elif [ "${current_image_id}" != "${new_image_id}" ]; then
  need_update=1; reason="镜像有更新"
elif [ "${container_running}" -eq 0 ]; then
  need_update=1; reason="容器未在运行"
elif [ "${FORCE}" -eq 1 ]; then
  need_update=1; reason="--force 强制重建"
fi

if [ "${MODE}" = "check" ]; then
  if [ "${need_update}" -eq 1 ]; then
    log INFO "可用更新：${reason}"
    exit 10
  fi
  log INFO "已是最新镜像，无需更新"
  exit 0
fi

if [ "${need_update}" -eq 0 ]; then
  log INFO "已是最新镜像，无需重建"
  exit 0
fi

log INFO "开始更新容器（${reason}）"

# ---------------------------------------------------------------- 4. 重建容器

# --no-build：只用刚拉下来的镜像，绝不触发本地源码构建（构建是另一条路，见 FORK.md）。
run "${COMPOSE[@]}" "${COMPOSE_FILES[@]}" up -d --no-build --force-recreate || {
  log ERROR "重建容器失败。可手动执行复现："
  log ERROR "  cd ${REPO_DIR} && ${COMPOSE[*]} ${COMPOSE_FILES[*]} up -d --no-build --force-recreate"
  exit 1
}

# ---------------------------------------------------------------- 5. 健康检查

if [ "${DRY_RUN}" -eq 1 ]; then
  log INFO "[dry-run] 跳过健康检查"
  exit 0
fi

log INFO "等待服务就绪（最多 ${HEALTH_TIMEOUT}s）：${HEALTH_URL}"
waited=0
code=""
if command -v curl >/dev/null 2>&1; then
  while [ "${waited}" -lt "${HEALTH_TIMEOUT}" ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${HEALTH_URL}" 2>/dev/null || true)"
    # 200 = 正常；503 = 池里暂时没有健康账号（healthz 的既定语义），网关本身已经起来了。
    if [ "${code}" = "200" ] || [ "${code}" = "503" ]; then break; fi
    sleep 3
    waited=$((waited + 3))
  done

  if [ "${code}" = "200" ] || [ "${code}" = "503" ]; then
    log INFO "健康检查通过（HTTP ${code}），容器已更新到 ${new_image_id}"
  else
    log ERROR "健康检查未通过（最后返回码 '${code:-无响应}'）。排查："
    log ERROR "  docker logs --tail 100 ${CONTAINER}"
    exit 1
  fi
else
  # 宿主机没有 curl 时退化为「进程还活着就算通过」，并明确告警 —— 不假装做了 HTTP 探测。
  running="$(docker inspect --format '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || echo false)"
  if [ "${running}" = "true" ]; then
    log WARN "宿主机没有 curl，已跳过 HTTP 健康检查；容器进程在运行，镜像已更新到 ${new_image_id}"
  else
    log ERROR "容器未在运行，且宿主机没有 curl 无法进一步探测。排查：docker logs --tail 100 ${CONTAINER}"
    exit 1
  fi
fi

# ---------------------------------------------------------------- 6. 清理旧镜像

if [ "${PRUNE}" -eq 1 ]; then
  # 旧镜像在 tag 被覆盖后变成 dangling，prune 只清 dangling，不会动其他项目的有效镜像。
  log INFO "清理被替换下来的旧镜像"
  run docker image prune -f --filter "dangling=true" >/dev/null 2>&1 || true
fi

log INFO "自更新完成"
