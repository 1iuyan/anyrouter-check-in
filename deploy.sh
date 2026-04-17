#!/usr/bin/env bash
# AnyRouter 签到脚本一键部署（Linux + systemd）
# 使用方法：
#   1. SSH 到服务器
#   2. sudo bash deploy.sh
# 幂等：重复执行只更新代码 + 重载 systemd

set -euo pipefail

# ============ 配置 ============
REPO_URL="https://github.com/1iuyan/anyrouter-check-in.git"
INSTALL_DIR="/opt/anyrouter-checkin"
SERVICE_NAME="anyrouter-checkin"
LOG_FILE="/var/log/${SERVICE_NAME}.log"
RUN_USER="${SUDO_USER:-root}"
RUN_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)

# ============ 工具函数 ============
log()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m  $*"; }
err()  { echo -e "\033[31m[FAIL]\033[0m  $*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "请用 sudo 执行：sudo bash $0"
    exit 1
  fi
}

# ============ 步骤 ============
step_install_deps() {
  log "安装系统依赖（xvfb、git、curl）..."
  apt-get update -qq
  apt-get install -y -qq xvfb git curl ca-certificates
}

step_install_uv() {
  # uv 装到运行用户 HOME 下（非 root 账户签到更安全）
  local uv_bin="$RUN_HOME/.local/bin/uv"
  if [[ -x "$uv_bin" ]]; then
    log "uv 已存在：$uv_bin"
  else
    log "为用户 $RUN_USER 安装 uv..."
    sudo -u "$RUN_USER" bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
  fi
  UV_BIN="$uv_bin"
}

step_clone_or_update() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    log "仓库已存在，执行 git pull..."
    sudo -u "$RUN_USER" git -C "$INSTALL_DIR" pull --ff-only
  else
    log "克隆仓库到 $INSTALL_DIR ..."
    mkdir -p "$INSTALL_DIR"
    chown "$RUN_USER:$RUN_USER" "$INSTALL_DIR"
    sudo -u "$RUN_USER" git clone "$REPO_URL" "$INSTALL_DIR"
  fi
}

step_uv_sync() {
  log "同步 Python 依赖..."
  sudo -u "$RUN_USER" bash -c "cd '$INSTALL_DIR' && '$UV_BIN' sync"

  log "安装 Playwright Chromium（含系统依赖，约需 1-2 分钟）..."
  # playwright install --with-deps 需要 root 权限安装 apt 包
  sudo -u "$RUN_USER" bash -c "cd '$INSTALL_DIR' && '$UV_BIN' run playwright install chromium"
  # 系统依赖单独装，避免 uv 在非 root 下 sudo 提权问题
  sudo -u "$RUN_USER" bash -c "cd '$INSTALL_DIR' && '$UV_BIN' run playwright install-deps chromium" || \
    warn "playwright install-deps 失败，可能需要手动补 apt 包"
}

step_prepare_env() {
  local env_file="$INSTALL_DIR/.env"
  # 支持从两个位置自动导入 accounts.json：脚本同目录 或 /root/accounts.json
  local accounts_json=""
  for candidate in "$(dirname "$(readlink -f "$0")")/accounts.json" "/root/accounts.json" "$RUN_HOME/accounts.json"; do
    if [[ -f "$candidate" ]]; then
      accounts_json="$candidate"
      break
    fi
  done

  if [[ -f "$env_file" ]]; then
    log ".env 已存在，跳过创建。如需修改请编辑 $env_file"
    return
  fi

  log "创建 .env（从 .env.example 复制）"
  cp "$INSTALL_DIR/.env.example" "$env_file"
  chown "$RUN_USER:$RUN_USER" "$env_file"
  chmod 600 "$env_file"

  if [[ -n "$accounts_json" ]]; then
    log "检测到账号文件：$accounts_json，自动注入 ANYROUTER_ACCOUNTS"
    # 校验 JSON 合法性
    if ! python3 -c "import json,sys; json.load(open('$accounts_json'))" 2>/dev/null; then
      err "$accounts_json 不是合法 JSON，请检查"
      exit 1
    fi
    # 压成单行 JSON 写入 .env（原文件里示例那一行删掉，重新写）
    local oneline
    oneline=$(python3 -c "import json; print(json.dumps(json.load(open('$accounts_json')),ensure_ascii=False,separators=(',',':')))")
    # 删除 .env 里原有的 ANYROUTER_ACCOUNTS 行（含注释样例）
    sed -i '/^ANYROUTER_ACCOUNTS=/d' "$env_file"
    # 用 printf 避免特殊字符被 echo 转义
    printf 'ANYROUTER_ACCOUNTS=%s\n' "$oneline" >> "$env_file"
    log "✅ ANYROUTER_ACCOUNTS 已写入"
    warn "通知渠道（钉钉/邮件/飞书等）如需启用，请手动编辑 $env_file"
    read -rp "按回车继续，输入 q 先退出去编辑通知配置：" ans
    [[ "$ans" == "q" ]] && { log "退出，改完 .env 后重跑本脚本即可"; exit 0; }
  else
    warn "未检测到 accounts.json"
    warn "方案 A：退出，把 JSON 放到服务器 /root/accounts.json 或脚本同目录后重跑"
    warn "方案 B：现在手动 vim 编辑 $env_file 填 ANYROUTER_ACCOUNTS"
    read -rp "编辑完成按回车继续，输入 q 退出：" ans
    [[ "$ans" == "q" ]] && { log "退出，配置完 .env 后再跑一次即可"; exit 0; }
  fi
}

step_prepare_log() {
  touch "$LOG_FILE"
  chown "$RUN_USER:$RUN_USER" "$LOG_FILE"
}

step_write_wrapper_scripts() {
  log "写入 wrapper 脚本（run.sh / watchdog.sh）..."

  # run.sh：包装 checkin.py，检测到余额变化则记录日期
  cat >"$INSTALL_DIR/run.sh" <<EOF
#!/usr/bin/env bash
# 由 systemd 调用。执行签到并记录"今日是否有余额变化"
set -o pipefail
cd "$INSTALL_DIR"

OUT=\$(/usr/bin/xvfb-run -a "$UV_BIN" run checkin.py 2>&1)
EXIT=\$?
echo "\$OUT"

# checkin.py 在余额变化或首次运行时会输出这两个标记
if echo "\$OUT" | grep -qE 'Balance changes detected|First run detected'; then
  TZ=Asia/Shanghai date +%Y-%m-%d > "$INSTALL_DIR/last_balance_change.txt"
fi

exit \$EXIT
EOF

  # watchdog.sh：18:30 检查今日是否有余额变化，没有就推 Bark
  cat >"$INSTALL_DIR/watchdog.sh" <<EOF
#!/usr/bin/env bash
# 由 systemd 每天北京时间 18:30 调用
set -a; source "$INSTALL_DIR/.env"; set +a

TODAY=\$(TZ=Asia/Shanghai date +%Y-%m-%d)
LAST=\$(cat "$INSTALL_DIR/last_balance_change.txt" 2>/dev/null || echo "")

if [[ "\$LAST" == "\$TODAY" ]]; then
  echo "[\$(date)] 今日已有余额变化，跳过告警"
  exit 0
fi

if [[ -z "\$BARK_KEY" ]]; then
  echo "[\$(date)] 未配置 BARK_KEY，无法告警"
  exit 0
fi

TITLE="⚠️ AnyRouter 今日未签到成功"
BODY="北京时间 18:00 仍未检测到余额变化，请手动签到或检查 cookie"

curl -s -X POST "\${BARK_SERVER:-https://api.day.app}/\${BARK_KEY}" \\
  -H "Content-Type: application/json; charset=utf-8" \\
  --data-raw "{\"title\":\"\$TITLE\",\"body\":\"\$BODY\",\"group\":\"AnyRouter\",\"level\":\"timeSensitive\"}"

echo "[\$(date)] 已推送未签到告警"
EOF

  chmod +x "$INSTALL_DIR/run.sh" "$INSTALL_DIR/watchdog.sh"
  chown "$RUN_USER:$RUN_USER" "$INSTALL_DIR/run.sh" "$INSTALL_DIR/watchdog.sh"
}

step_write_systemd() {
  log "写入 systemd service/timer..."

  # 签到 service
  cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=AnyRouter Check-in
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$RUN_USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/run.sh
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
TimeoutStartSec=600
EOF

  # 签到 timer（北京时间每 6h）
  cat >/etc/systemd/system/${SERVICE_NAME}.timer <<EOF
[Unit]
Description=AnyRouter Check-in Timer (every 6h, Beijing time)

[Timer]
OnCalendar=*-*-* 00,06,12,18:00:00 Asia/Shanghai
RandomizedDelaySec=300
Persistent=true
Unit=${SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF

  # Watchdog service
  cat >/etc/systemd/system/${SERVICE_NAME}-watchdog.service <<EOF
[Unit]
Description=AnyRouter Watchdog (alert if not checked in by 18:00 Beijing time)

[Service]
Type=oneshot
User=$RUN_USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/watchdog.sh
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
EOF

  # Watchdog timer（北京时间每天 18:30，给 18:00 签到留出完成时间）
  cat >/etc/systemd/system/${SERVICE_NAME}-watchdog.timer <<EOF
[Unit]
Description=AnyRouter Watchdog Timer (daily 18:30 Beijing time)

[Timer]
OnCalendar=*-*-* 18:30:00 Asia/Shanghai
Persistent=true
Unit=${SERVICE_NAME}-watchdog.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.timer"
  systemctl enable --now "${SERVICE_NAME}-watchdog.timer"
}

step_summary() {
  echo
  log "✅ 部署完成"
  echo "  代码目录：$INSTALL_DIR"
  echo "  环境变量：$INSTALL_DIR/.env"
  echo "  日志文件：$LOG_FILE"
  echo
  echo "常用命令："
  echo "  查看所有定时器： systemctl list-timers | grep $SERVICE_NAME"
  echo "  手动跑签到：     sudo systemctl start ${SERVICE_NAME}.service"
  echo "  手动跑 watchdog：sudo systemctl start ${SERVICE_NAME}-watchdog.service"
  echo "  查看日志：       tail -f $LOG_FILE"
  echo "  停止签到：       sudo systemctl disable --now ${SERVICE_NAME}.timer"
  echo "  停止 watchdog：  sudo systemctl disable --now ${SERVICE_NAME}-watchdog.timer"
  echo "  更新代码：       sudo bash $INSTALL_DIR/deploy.sh"
  echo
  warn "Bark 配置：.env 里需要 BARK_KEY=xxx 和 BARK_SERVER=https://api.day.app"
  warn "别忘了去 GitHub 关掉原仓库的 Actions workflow，避免重复签到"
}

# ============ 主流程 ============
main() {
  require_root
  step_install_deps
  step_install_uv
  step_clone_or_update
  step_uv_sync
  step_prepare_env
  step_prepare_log
  step_write_wrapper_scripts
  step_write_systemd
  step_summary
}

main "$@"
