#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 栈的宿主机入口：一次性引导 + 日常运维
#
# 持续性更新**不在这里** —— 它在 updater 容器里跑（deploy/updater/stack-update.sh），
# 宿主机上不需要 cron。这个脚本存在的唯一理由是：总得有人先把容器创建出来，
# 以及偶尔需要手动干预（回滚、看状态、进容器）。
#
#   ./scripts/stack.sh init            生成 .env / config.json / 目录，设置本地忽略
#   ./scripts/stack.sh up              引导并启动整个栈 ← 首次部署用这个
#   ./scripts/stack.sh status          容器状态 + 各服务镜像版本 + 更新历史
#   ./scripts/stack.sh logs [服务]     跟踪日志（默认 updater）
#   ./scripts/stack.sh update [参数]   立刻让容器内的更新器跑一轮
#                                      可加 --only wbgui / --dry-run
#   ./scripts/stack.sh rollback <服务> 回滚到上一个可用镜像
#   ./scripts/stack.sh restart [服务]  重启（默认全部）
#   ./scripts/stack.sh down            停止并移除容器（数据卷保留）
#   ./scripts/stack.sh config          打印解析后的编排配置（排错用）
#   ./scripts/stack.sh shell <服务>    进容器
#   ./scripts/stack.sh doctor          体检：路径、权限、镜像、端口
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
STACK_DIR="$(pwd -P)"
COMPOSE_FILE="${STACK_DIR}/docker-compose.fork.yml"

info() { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n\033[36m── %s ──\033[0m\n' "$*"; }

DC=""
detect_docker() {
  command -v docker >/dev/null 2>&1 || die "找不到 docker，请先装 Docker Engine"
  if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
  else
    die "找不到 docker compose（Docker Engine 需要 compose 插件）"
  fi
  docker info >/dev/null 2>&1 \
    || die "连不上 Docker 守护进程（docker info 失败）。权限不足就用 sudo，或把用户加进 docker 组"
}

dc() { $DC -f "$COMPOSE_FILE" "$@"; }

# 在 updater 容器里执行脚本：容器在跑就 exec（复用同一份状态，避免和循环里的
# 定时检查并发操作），没跑就一次性 run
updater_run() {
  if [ -n "$(dc ps -q updater 2>/dev/null)" ]; then
    dc exec -T updater /usr/local/bin/stack-update.sh "$@"
  else
    dc run --rm --no-deps updater "$@"
  fi
}

gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-18
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 18
  fi
}

# 跨平台取文件的 uid（BSD stat 在前，GNU stat 在后）
file_uid() {
  stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1" 2>/dev/null || echo ""
}

# 网关以 uid 10001 运行，相关目录/文件得能让它读写
fix_owner() {
  local p="$1" uid
  [ -e "$p" ] || return 0
  uid="$(file_uid "$p")"
  [ "$uid" = "10001" ] && return 0
  if [ "$(id -u)" = "0" ]; then
    chown -R 10001:10001 "$p" && info "已把 $p 的属主交给 10001（网关进程的 uid）"
    return 0
  fi
  warn "$p 的属主是 uid=${uid:-未知}，而网关以 uid 10001 运行 —— 它可能读写不了这个路径。"
  warn "  修复命令：sudo chown -R 10001:10001 '$p'"
}

env_value() { # 从 .env 里取一个值
  [ -f .env ] || return 0
  sed -n "s/^$1=//p" .env | head -n1
}

# 取字符串值，空则用默认值（shell 的 ${X:-d} 不适用于这里的「读 .env」场景：
# env_value 读不到时也返回 0，所以 `$(env_value X || echo d)` 根本不会触发默认值）
env_or() { # env_or <KEY> <默认值>
  local v; v="$(env_value "$1")"
  printf '%s' "${v:-$2}"
}

# 取数值，非数字一律回退（防止 .env 里写错导致 $(( )) 直接报错中断）
env_num() { # env_num <KEY> <默认值>
  local v; v="$(env_value "$1")"
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  printf '%s' "$v"
}

# 把字符串安全地塞进 sed 的替换段（s|...|X| 里 X 的元字符）
sed_escape() {
  local s="$1"
  s="${s//\\/\\\\}"   # 反斜杠优先
  s="${s//&/\\&}"     # & 在替换段表示「整个匹配」
  s="${s//|/\\|}"     # 本脚本用 | 作分隔符
  printf '%s' "$s"
}

# ── init ────────────────────────────────────────────────────────────────────
cmd_init() {
  step "初始化 $STACK_DIR"

  # 1) .env —— 从模板生成，并把 STACK_DIR 钉成当前绝对路径
  if [ ! -f .env ]; then
    [ -f .env.example ] || die "缺少 .env.example，无法生成 .env"
    local esc; esc="$(sed_escape "$STACK_DIR")"
    sed "s|^STACK_DIR=.*|STACK_DIR=${esc}|" .env.example > .env
    chmod 600 .env
    printf '\n# 由 stack.sh init 生成的面板登录口令\nWBGUI_PASSWORD=%s\n' "$(gen_password)" >> .env
    info "已生成 .env（面板口令随机生成，见文件末尾的 WBGUI_PASSWORD）"
  else
    local cur; cur="$(env_value STACK_DIR)"
    if [ "$cur" != "$STACK_DIR" ]; then
      local esc; esc="$(sed_escape "$STACK_DIR")"
      sed -i.bak "s|^STACK_DIR=.*|STACK_DIR=${esc}|" .env && rm -f .env.bak
      warn ".env 里的 STACK_DIR 原本是 '$cur'，已改成当前目录 '$STACK_DIR'"
    fi
    if [ -z "$(env_value WBGUI_PASSWORD)" ]; then
      printf '\n# 由 stack.sh init 生成的面板登录口令\nWBGUI_PASSWORD=%s\n' "$(gen_password)" >> .env
      info "已补上面板口令 WBGUI_PASSWORD"
    fi
    info ".env 已存在，保留其中其它配置"
  fi

  # 2) config.json —— 网关的真实配置。绝不能让它不存在：
  #    compose 的 bind mount 遇到不存在的路径会创建一个**目录**，网关会直接起不来。
  if [ ! -f config.json ]; then
    if [ -f config.example.json ]; then
      cp config.example.json config.json
      info "已从 config.example.json 生成 config.json —— 请按需修改（API Key 等）"
    else
      die "缺少 config.example.json，且没有 config.json，无法继续"
    fi
  else
    info "config.json 已存在，不动它"
  fi

  # 3) 运行时目录 + 属主。网关以 app(uid 10001) 读写这两处。
  mkdir -p auths data
  fix_owner auths
  fix_owner data
  # config.json 是单文件挂载：网关只读它，面板（root）写它。
  # 属主交给 10001 是为了让网关读得到；root 仍然能写。
  fix_owner config.json

  # 4) 面板源码是运行时由 updater 克隆进来的，不该被当成仓库内容 ——
  #    但上游 .gitignore 里没有 src/，所以写进 .git/info/exclude（本地忽略，
  #    不进版本库、也不会被 git reset --hard 清掉）。
  if [ -d .git ]; then
    local excl=".git/info/exclude"
    touch "$excl"
    if ! grep -qx '/src/' "$excl" 2>/dev/null; then
      printf '\n# 运行时由 updater 拉取的面板源码，不该进版本库\n/src/\n' >> "$excl"
      info "已把 /src/ 写进 .git/info/exclude（本地忽略面板源码）"
    fi
  fi

  # 5) 老版本（第一轮的宿主机 cron 方案）在 crontab 里留下过一条 wb2api-selfupdate。
  #    它按「docker-compose.yml + docker-compose.fork.yml 叠加」的方式重建容器，而现在
  #    docker-compose.fork.yml 已经是自包含完整栈 —— 再叠加会解析出冲突配置，等于每 6
  #    小时把好好的栈重建坏一次。检测到就明确要求摘掉，别让它默默生效。
  if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q 'wb2api-selfupdate'; then
    warn "宿主机 crontab 里还有旧的 wb2api-selfupdate 条目。容器内自更新已经接管，"
    warn "  留着它会把栈按过时的合并方式重建坏，请立刻摘掉："
    warn "    crontab -l | grep -v wb2api-selfupdate | crontab -"
  fi

  info "初始化完成"
}

# ── up ──────────────────────────────────────────────────────────────────────
cmd_up() {
  cmd_init

  step "构建更新器镜像"
  dc build updater || die "updater 镜像构建失败"

  step "准备面板镜像（首次会克隆上游源码并构建，约几分钟）"
  if ! updater_run --once --only wbgui; then
    warn "面板镜像没准备好。可以稍后单独重试：./scripts/stack.sh update --only wbgui"
  fi

  step "启动整个栈"
  dc up -d || die "启动失败，用 ./scripts/stack.sh logs 看日志"

  echo
  local site http_port iv
  site="$(env_value WGUI_SITE)"
  http_port="$(env_num HTTP_PORT 80)"
  iv="$(env_num UPDATE_INTERVAL 21600)"
  if [ -n "$site" ]; then
    info "面板入口：https://${site}/"
  else
    info "面板入口：http://<服务器IP>:${http_port}/"
  fi
  info "面板账号：$(env_or WBGUI_USERNAME admin) / 口令见 .env 里的 WBGUI_PASSWORD"
  info "网关 API：http://<服务器IP>:7863  （OpenAI 兼容，客户端填这个 + config.json 里的 api_key）"
  echo
  info "之后不用再管更新 —— updater 容器每 $(( iv / 3600 )) 小时自动检查一次。"
  info "想立刻检查：./scripts/stack.sh update"
}

# ── 运维 ────────────────────────────────────────────────────────────────────
cmd_status() {
  local cur; cur="$(env_value STACK_DIR)"
  [ "$cur" = "$STACK_DIR" ] || warn ".env 里的 STACK_DIR=$cur 与当前目录不一致，先跑一次 init"
  step "容器"
  dc ps
  step "版本与更新历史"
  updater_run --status
}

cmd_doctor() {
  step "环境"
  printf '  当前目录      : %s\n' "$STACK_DIR"
  printf '  docker        : %s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '连不上')"
  printf '  compose       : %s\n' "$(docker compose version --short 2>/dev/null || docker-compose version --short 2>/dev/null || echo 未知)"
  printf '  .env          : %s\n' "$([ -f .env ] && echo 有 || echo '缺（先跑 init）')"
  printf '  STACK_DIR 一致: %s\n' "$([ "$(env_value STACK_DIR)" = "$STACK_DIR" ] && echo 是 || echo '否 ← 必须修')"

  step "数据与权限（网关以 uid 10001 运行）"
  for p in auths data config.json; do
    if [ -e "$p" ]; then
      printf '  %-12s 属主uid=%-6s %s\n' "$p" "$(file_uid "$p")" \
        "$([ "$(file_uid "$p")" = 10001 ] && echo '✓' || echo '← 需要 chown -R 10001:10001')"
    else
      printf '  %-12s 不存在\n' "$p"
    fi
  done
  printf '  auths 里的凭证数: %s\n' "$(ls -1 auths 2>/dev/null | wc -l | tr -d ' ')"

  step "面板源码"
  if [ -d src/workbuddy2api-gui/.git ]; then
    printf '  已就位，HEAD = %s\n' "$(git -C src/workbuddy2api-gui rev-parse --short HEAD 2>/dev/null)"
  else
    printf '  尚无（首次 ./scripts/stack.sh up 会自动克隆）\n'
  fi

  step "镜像"
  local img id
  for img in "$(env_or WB2API_IMAGE ghcr.io/tarocats/workbuddy2api:latest)" \
             "$(env_or UPDATER_IMAGE workbuddy-stack-updater:local)" \
             "$(env_or WBGUI_IMAGE workbuddy2api-gui:local)"; do
    [ -n "$img" ] || continue
    id="$(docker image inspect --format '{{.Id}}' "$img" 2>/dev/null)"
    printf '  %-45s %s\n' "$img" "$([ -n "$id" ] && echo "${id:7:12}" || echo '本地没有')"
  done

  step "端口占用"
  local port line
  for port in 7863 "$(env_num HTTP_PORT 80)" "$(env_num HTTPS_PORT 443)"; do
    line="$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -E ":${port}->" | head -n1)"
    printf '  %-6s %s\n' "$port" "${line:-看起来空闲}"
  done

  step "最近一次更新"
  if [ -n "$(dc ps -q updater 2>/dev/null)" ]; then
    dc logs --tail 8 updater 2>&1 | sed 's/^/  /'
  else
    printf '  updater 没在跑\n'
  fi
}

cmd_logs()   { dc logs -f --tail=120 "${1:-updater}"; }
cmd_update() { updater_run --once "$@"; }
cmd_config() { dc config; }
cmd_down()   { dc down "$@"; }

cmd_restart() {
  if [ -n "${1:-}" ]; then
    dc restart "$1"
  else
    dc restart
  fi
}

cmd_rollback() {
  [ -n "${1:-}" ] || die "用法：./scripts/stack.sh rollback <服务名>（wb2api 或 wbgui）"
  updater_run --rollback "$1"
}

cmd_shell() {
  [ -n "${1:-}" ] || die "用法：./scripts/stack.sh shell <服务名>"
  case "$1" in
    wb2api) dc exec "$1" bash ;;
    *)      dc exec "$1" sh ;;
  esac
}

usage() { sed -n '2,22p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; }

case "${1:-}" in
  init)     detect_docker; cmd_init ;;
  up)       detect_docker; cmd_up ;;
  status)   detect_docker; cmd_status ;;
  doctor)   detect_docker; cmd_doctor ;;
  logs)     detect_docker; shift; cmd_logs "$@" ;;
  update)   detect_docker; shift; cmd_update "$@" ;;
  rollback) detect_docker; shift; cmd_rollback "$@" ;;
  restart)  detect_docker; shift; cmd_restart "$@" ;;
  down)     detect_docker; shift; cmd_down "$@" ;;
  config)   DC="docker compose"; dc config ;;
  shell)    detect_docker; shift; cmd_shell "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "未知命令：${1}（用 ./scripts/stack.sh --help 看用法）" ;;
esac
