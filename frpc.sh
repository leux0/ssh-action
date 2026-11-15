#!/usr/bin/env bash
#
# frpc.sh —— 用 frp 把 GitHub Actions runner 的 SSH(22) 端口映射到公网
#
# 与 https://github.com/leux0/ssh-action 的 ngrok 方案等价的 frp 版本：
#   * 在 runner 上启动 sshd（允许密码登录）并设置 runner 用户密码
#   * 用 frpc 把 127.0.0.1:22 映射到 frps 服务器的 FRP_REMOTE_PORT 端口
#   * 打印形如 "ssh -p 6000 runner@frp.example.com" 的连接命令
#
# 必填环境变量：
#   FRP_SERVER_ADDR   frps 服务器地址（IP 或域名）
#   FRP_SERVER_PORT		frps 服务器端口
#   FRP_REMOTE_PORT   frps 服务器映射本地端口
#   FRP_TOKEN         frps 服务器的 auth.token
#   USER_PASSWD       SSH 登录密码
#
# 用法：
#   bash frpc.sh
#   curl -fsSL https://raw.githubusercontent.com/<你>/<仓库>/main/frpc.sh | bash
#   DRY_RUN=1 bash frpc.sh        # 只生成 frpc.toml（token 打码），不做任何修改
#
set -euo pipefail
umask 077

# ------------------------------ 可选参数 ------------------------------------
FRP_SERVER_ADDR="${FRP_SERVER_ADDR:-}"
FRP_SERVER_PORT="${FRP_SERVER_PORT:-7000}"
FRP_TOKEN="${FRP_TOKEN:-}"
FRP_REMOTE_PORT="${FRP_REMOTE_PORT:-6000}"
FRP_PROXY_NAME="${FRP_PROXY_NAME:-ssh}"
FRP_VERSION="${FRP_VERSION:-0.72.0}"
FRP_DOWNLOAD_MIRROR="${FRP_DOWNLOAD_MIRROR:-}"
FRP_TLS_ENABLE="${FRP_TLS_ENABLE:-true}"
FRP_PROTOCOL="${FRP_PROTOCOL:-tcp}"
FRP_WORK_DIR="${FRP_WORK_DIR:-${PWD}/frp}"
SSH_USER="${SSH_USER:-${USER:-runner}}"
USER_PASSWD="${USER_PASSWD:-}"
SSH_PUBKEY="${SSH_PUBKEY:-}"

FRP_VERSION="${FRP_VERSION#v}"
CONFIG_FILE="${FRP_WORK_DIR}/frpc.toml"
LOG_FILE="${FRP_WORK_DIR}/frpc.log"
PID_FILE="${FRP_WORK_DIR}/frpc.pid"
FRPC_BIN="${FRP_WORK_DIR}/frpc"

# ------------------------------ 辅助函数 ------------------------------------
info() { printf '>>> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }
die() { printf '### 错误: %s\n' "$*" >&2; exit 1; }

check_env() {
  [[ -n "$FRP_SERVER_ADDR" ]] || die "请设置 FRP_SERVER_ADDR（frps 服务器地址）"
  [[ -n "$FRP_TOKEN" ]] || die "请设置 FRP_TOKEN（需与 frps 的 auth.token 一致）"
  [[ -n "$USER_PASSWD" || -n "$SSH_PUBKEY" ]] ||
    die "请设置 USER_PASSWD，或用 SSH_PUBKEY 只走公钥登录"

  [[ "$FRP_SERVER_ADDR" =~ ^[A-Za-z0-9._:-]+$ ]] || die "FRP_SERVER_ADDR 含非法字符: $FRP_SERVER_ADDR"
  [[ "$FRP_TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || die "FRP_TOKEN 只能包含字母数字和 ._~+/=-"
  [[ "$FRP_PROXY_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "FRP_PROXY_NAME 只能包含字母数字和 _-"
  [[ "$FRP_SERVER_PORT" =~ ^[0-9]+$ ]] || die "FRP_SERVER_PORT 必须是数字"
  [[ "$FRP_REMOTE_PORT" =~ ^[0-9]+$ ]] || die "FRP_REMOTE_PORT 必须是数字"
  [[ "$FRP_TLS_ENABLE" =~ ^(true|false)$ ]] || die "FRP_TLS_ENABLE 只能是 true 或 false"
  [[ "$FRP_PROTOCOL" =~ ^(tcp|kcp|quic|websocket|wss)$ ]] || die "FRP_PROTOCOL 只能是 tcp/kcp/quic/websocket/wss"

  [[ "$USER_PASSWD" != *:* ]] || die "USER_PASSWD 不能包含冒号（chpasswd 的格式限制）"
  [[ ! "$USER_PASSWD" =~ [[:space:]] ]] || die "USER_PASSWD 不能包含空白字符"
}

detect_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64 | amd64) printf 'amd64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    armv7l | armv6l) printf 'arm' ;;
    *) die "不支持的 CPU 架构: $machine" ;;
  esac
}

install_frpc() {
  if [[ -x "$FRPC_BIN" ]]; then
    info "复用已存在的 frpc: $FRPC_BIN"
    return 0
  fi

  local arch pkg base url
  arch="$(detect_arch)"
  pkg="frp_${FRP_VERSION}_linux_${arch}.tar.gz"
  base="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}"

  if [[ -n "$FRP_DOWNLOAD_MIRROR" ]]; then
    url="${FRP_DOWNLOAD_MIRROR%/}/${base}/${pkg}"
  else
    url="${base}/${pkg}"
  fi

  info "下载 frpc v${FRP_VERSION} (linux/${arch})"
  info "  $url"

  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 \
    -o "${FRP_WORK_DIR}/${pkg}" "$url" ||
    die "frpc 下载失败，可设置 FRP_DOWNLOAD_MIRROR（例如 https://ghfast.top）后重试"

  tar -xzf "${FRP_WORK_DIR}/${pkg}" -C "$FRP_WORK_DIR" || die "解压 ${pkg} 失败"

  local dir="${FRP_WORK_DIR}/frp_${FRP_VERSION}_linux_${arch}"
  [[ -f "${dir}/frpc" ]] || die "压缩包内未找到 frpc 可执行文件"

  install -m 755 "${dir}/frpc" "$FRPC_BIN" || die "安装 frpc 失败"
  rm -rf "$dir" "${FRP_WORK_DIR:?}/${pkg}"
  info "frpc 安装完成: $FRPC_BIN"
}

is_port_listening() {
  local port="$1" out
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -ltn 2>/dev/null || true)"
  elif command -v netstat >/dev/null 2>&1; then
    out="$(netstat -ltn 2>/dev/null || true)"
  else
    return 0
  fi
  printf '%s\n' "$out" | awk -v p="$port" '{ n = split($4, a, ":"); if (a[n] == p) found = 1 } END { exit found ? 0 : 1 }'
}

setup_sshd() {
  info "配置并启动 sshd（允许密码登录）"

  local sshd_bin=""
  if command -v sshd >/dev/null 2>&1; then
    sshd_bin="$(command -v sshd)"
  elif [[ -x /usr/sbin/sshd ]]; then
    sshd_bin=/usr/sbin/sshd
  fi

  if [[ -z "$sshd_bin" ]]; then
    warn "未找到 sshd，尝试安装 openssh-server"
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -qq >/dev/null 2>&1 || true
      sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null 2>&1 || true
    fi
    if [[ -x /usr/sbin/sshd ]]; then
      sshd_bin=/usr/sbin/sshd
    else
      die "找不到 sshd，无法对外提供 SSH"
    fi
  fi

  # Ubuntu/Debian 的 sshd_config 在文件顶部 Include drop-in，且"先匹配先生效"，
  # 所以用 00- 前缀，确保能盖掉 cloud-init 等文件里的 PasswordAuthentication no。
  local -a sshd_opts=(
    'PasswordAuthentication yes'
    'KbdInteractiveAuthentication yes'
    'UsePAM yes'
    'ClientAliveInterval 30'
    'ClientAliveCountMax 6'
  )
  if [[ "$SSH_USER" == "root" ]]; then
    sshd_opts+=('PermitRootLogin yes')
  fi

  if [[ -d /etc/ssh/sshd_config.d ]]; then
    printf '%s\n' "${sshd_opts[@]}" |
      sudo tee /etc/ssh/sshd_config.d/00-ssh-action.conf >/dev/null
  fi

  # 没有 Include 的老系统：直接改主配置（后面出现的指令在 sshd 里不生效，所以就地替换）
  sudo sed -i -E \
    -e 's/^#?[[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication yes/' \
    -e 's/^#?[[:space:]]*KbdInteractiveAuthentication[[:space:]].*/KbdInteractiveAuthentication yes/' \
    -e 's/^#?[[:space:]]*UsePAM[[:space:]].*/UsePAM yes/' \
    /etc/ssh/sshd_config || warn "修改 /etc/ssh/sshd_config 失败，继续尝试启动 sshd"

  sudo mkdir -p /run/sshd
  # 缺主机密钥时 sshd 起不来，-A 只在缺失时生成，可重复执行
  sudo ssh-keygen -A >/dev/null 2>&1 || warn "生成 SSH 主机密钥失败"

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true
  elif command -v service >/dev/null 2>&1; then
    sudo service ssh restart 2>/dev/null || sudo service sshd restart 2>/dev/null || true
  fi

  if ! is_port_listening 22; then
    info "服务管理器未拉起 sshd，直接启动"
    sudo "$sshd_bin" -E "${FRP_WORK_DIR}/sshd.log" || warn "直接启动 sshd 失败，见 ${FRP_WORK_DIR}/sshd.log"
  fi

  if is_port_listening 22; then
    info "sshd 已在 22 端口监听"
  else
    warn "sshd 未监听 22 端口，SSH 大概率连不上"
  fi
}

set_password() {
  info "设置用户 ${SSH_USER} 的登录密码"
  getent passwd "$SSH_USER" >/dev/null 2>&1 || die "用户 ${SSH_USER} 不存在，可通过 SSH_USER 指定"
  printf '%s:%s\n' "$SSH_USER" "$USER_PASSWD" | sudo chpasswd || die "设置密码失败"
}

install_pubkey() {
  [[ -n "$SSH_PUBKEY" ]] || return 0

  info "写入 SSH 公钥"
  local home_dir
  home_dir="$(getent passwd "$SSH_USER" | cut -d: -f6)"
  [[ -n "$home_dir" ]] || die "无法确定用户 ${SSH_USER} 的家目录"

  sudo install -d -m 700 -o "$SSH_USER" -g "$(id -gn "$SSH_USER")" "${home_dir}/.ssh"

  printf '%s\n' "$SSH_PUBKEY" | tr -d '\r' | while IFS= read -r key; do
    if [[ -n "$key" ]]; then
      printf '%s\n' "$key"
    fi
  done | sudo tee -a "${home_dir}/.ssh/authorized_keys" >/dev/null

  sudo chown "$SSH_USER:$(id -gn "$SSH_USER")" "${home_dir}/.ssh/authorized_keys"
  sudo chmod 600 "${home_dir}/.ssh/authorized_keys"
}

write_config() {
  info "生成 frpc 配置: ${CONFIG_FILE}"
  cat >"$CONFIG_FILE" <<EOF
serverAddr = "${FRP_SERVER_ADDR}"
serverPort = ${FRP_SERVER_PORT}
loginFailExit = true

auth.method = "token"
auth.token = "${FRP_TOKEN}"

transport.protocol = "${FRP_PROTOCOL}"
transport.tls.enable = ${FRP_TLS_ENABLE}

log.level = "info"

[[proxies]]
name = "${FRP_PROXY_NAME}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = ${FRP_REMOTE_PORT}
EOF
}

start_frpc() {
  info "启动 frpc: ${FRPC_BIN} -c ${CONFIG_FILE}"
  : >"$LOG_FILE"

  nohup "$FRPC_BIN" -c "$CONFIG_FILE" >>"$LOG_FILE" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" >"$PID_FILE"

  # 最多等 30 秒，让 frpc 完成登录并建立代理
  for _ in $(seq 1 30); do
    if grep -q 'start proxy success' "$LOG_FILE" 2>/dev/null; then
      info "frpc 隧道建立成功 (pid ${pid})"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      warn "frpc 已退出，日志如下:"
      sed 's/^/    /' "$LOG_FILE" >&2
      return 1
    fi
    sleep 1
  done

  warn "等待 30 秒仍未建立隧道，日志如下:"
  sed 's/^/    /' "$LOG_FILE" >&2
  return 1
}

print_connection() {
  local login_hint
  if [[ -n "$USER_PASSWD" ]]; then
    login_hint="密码就是 USER_PASSWD 中配置的值。"
  else
    login_hint="未设置密码，请用 SSH_PUBKEY 对应的私钥登录。"
  fi

  cat <<EOF

============================================================
 SSH 已就绪，在你的电脑上执行：

   ssh -p ${FRP_REMOTE_PORT} ${SSH_USER}@${FRP_SERVER_ADDR}

 ${login_hint}
 用公钥登录时：
   ssh -i <你的私钥> -p ${FRP_REMOTE_PORT} ${SSH_USER}@${FRP_SERVER_ADDR}

 frpc 日志：${LOG_FILE}
============================================================

EOF
}

main() {
  check_env
  mkdir -p "$FRP_WORK_DIR"
  write_config

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    info "DRY_RUN=1：仅生成配置，token 已打码"
    sed -E 's/(auth\.token = ").*(")/\1***\2/' "$CONFIG_FILE"
    exit 0
  fi

  install_frpc
  setup_sshd
  if [[ -n "$USER_PASSWD" ]]; then
    set_password
  fi
  install_pubkey
  start_frpc || die "frpc 隧道启动失败，请查看日志: ${LOG_FILE}"
  print_connection
}

main "$@"
