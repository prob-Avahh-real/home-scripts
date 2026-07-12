#!/usr/bin/env bash
# ==============================================================================
# 通用一键部署脚本  v3.0
#
# 支持四种运行时模式，同一套脚本覆盖所有项目：
#   static    — 纯静态前端（Vue/React/Astro/Svelte），Nginx 直接 serve
#   node      — Node.js 后端（Express/Nest/Fastify），Docker 化运行
#   python    — Python 后端（FastAPI/Django/Flask），Docker 化运行
#   go        — Go 二进制（编译后直接跑或 Docker 化）
#
# 用法：
#   1) 复制到项目根目录，创建 .env.deploy（或用命令行参数）
#   2) chmod +x deploy.sh && ./deploy.sh --mode node
#   3) 或一键管道：curl -fsSL https://你的地址/deploy.sh | bash -s -- --mode node
#
# 命令行优先于 .env.deploy，.env.deploy 优先于内置默认值。
# ==============================================================================

set -euo pipefail

# ── 颜色 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()  { echo -e "${BLUE}[i]${NC} $1"; }

# ── 默认值 ──
MODE=""
PROJECT_NAME="${PWD##*/}"
APP_PORT="3000"
DOMAIN=""
EMAIL=""
DEPLOY_USER="deploy"
STATIC_DIR="dist"
DOCKER_CONTEXT="."
DOCKERFILE="Dockerfile"
CREATE_SWAP="y"
SWAP_SIZE="2G"
DRY_RUN="false"
NO_INTERACTIVE="false"

# ── 加载 .env.deploy（优先级低于命令行）──
if [ -f ".env.deploy" ]; then
    info "加载 .env.deploy ..."
    set -a; source .env.deploy; set +a
fi

# ── 解析命令行 ──
usage() {
    cat << 'EOF'
用法: ./deploy.sh [选项]

模式（必选其一）:
  --mode static        纯静态前端（Nginx 直接 serve）
  --mode node          Node.js 后端（Docker 化）
  --mode python        Python 后端（Docker 化）
  --mode go            Go 二进制

通用参数:
  --project NAME       项目名（默认取当前目录名）
  --domain DOMAIN      域名（Nginx + SSL 必需）
  --email EMAIL        Let's Encrypt 通知邮箱
  --port PORT          应用端口（默认 3000）
  --deploy-user USER   部署用户（默认 deploy）
  --static-dir DIR     静态文件目录（默认 dist）
  --docker-context DIR Docker 构建上下文（默认 .）
  --dockerfile PATH    Dockerfile 路径（默认 Dockerfile）
  --swap SIZE          创建 swap（如 2G，默认 2G；传 no 跳过）
  --dry-run            仅预览，不执行
  --yes / -y           跳过确认交互

示例:
  ./deploy.sh --mode static --domain example.com --email a@b.com
  ./deploy.sh --mode node --port 3001
  ./deploy.sh --mode python --domain api.example.com --port 8000
  ./deploy.sh --mode go --dry-run
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage ;;
        --mode)          MODE="$2"; shift 2 ;;
        --project)       PROJECT_NAME="$2"; shift 2 ;;
        --domain)        DOMAIN="$2"; shift 2 ;;
        --email)         EMAIL="$2"; shift 2 ;;
        --port)          APP_PORT="$2"; shift 2 ;;
        --deploy-user)   DEPLOY_USER="$2"; shift 2 ;;
        --static-dir)    STATIC_DIR="$2"; shift 2 ;;
        --docker-context)DOCKER_CONTEXT="$2"; shift 2 ;;
        --dockerfile)    DOCKERFILE="$2"; shift 2 ;;
        --swap)          SWAP_SIZE="$2"; CREATE_SWAP="y"; shift 2 ;;
        --dry-run)       DRY_RUN="true"; shift ;;
        --yes|-y)        NO_INTERACTIVE="true"; shift ;;
        *) err "未知参数: $1（用 --help 查看帮助）" ;;
    esac
done

# ── 校验 ──
if [ -z "$MODE" ]; then
    err "必须指定 --mode（static/node/python/go），或用 --help 查看用法"
fi
case "$MODE" in static|node|python|go) ;; *) err "无效模式: $MODE";; esac

# ── 确认面板 ──
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  通用一键部署  v3.0                      ║"
echo "╠══════════════════════════════════════════╣"
printf "║  模式:        %-27s ║\n" "$MODE"
printf "║  项目名:      %-27s ║\n" "$PROJECT_NAME"
printf "║  域名:        %-27s ║\n" "$DOMAIN"
printf "║  端口:        %-27s ║\n" "$APP_PORT"
printf "║  部署用户:    %-27s ║\n" "$DEPLOY_USER"
printf "║  静态目录:    %-27s ║\n" "$STATIC_DIR"
printf "║  Dockerfile:  %-27s ║\n" "$DOCKERFILE"
printf "║  Swap:        %-27s ║\n" "$SWAP_SIZE"
printf "║  干跑模式:    %-27s ║\n" "$DRY_RUN"
echo "╚══════════════════════════════════════════╝"
echo ""

if [ "$DRY_RUN" = "true" ]; then
    info "干跑模式 — 不会执行任何操作。"
    exit 0
fi

if [ "$NO_INTERACTIVE" != "true" ]; then
    read -p "确认开始部署？(y/n) " CONFIRM
    [ "$CONFIRM" != "y" ] && exit 0
fi

# =============================================================================
# 工具函数
# =============================================================================
require_root() {
    if [ "$EUID" -ne 0 ]; then
        err "需要 root 权限：sudo ./deploy.sh ..."
    fi
}

ensure_cmd() {
    command -v "$1" &>/dev/null || apt install -y -qq "$2"
}

# =============================================================================
# 阶段 1: 系统初始化（所有模式共用）
# =============================================================================
init_system() {
    require_root
    log "更新系统..."
    apt update && apt upgrade -y -qq

    log "安装基础工具..."
    apt install -y -qq curl wget git vim htop ufw nginx certbot python3-certbot-nginx fail2ban

    timedatectl set-timezone UTC 2>/dev/null || true
    log "时区已设为 UTC"
}

init_swap() {
    if [ "$CREATE_SWAP" != "y" ] || [ "$SWAP_SIZE" = "no" ]; then
        info "跳过 swap"
        return
    fi
    if swapon --show | grep -q .; then
        warn "Swap 已存在，跳过"
        return
    fi
    log "创建 ${SWAP_SIZE} swap 文件..."
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swap 创建完成"
}

init_ssh() {
    log "加固 SSH..."
    cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    systemctl restart sshd
    log "SSH 已加固"
}

init_firewall() {
    log "配置防火墙..."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow OpenSSH
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    log "防火墙已启用"
}

init_fail2ban() {
    log "配置 fail2ban..."
    cat > /etc/fail2ban/jail.local << 'JAILLOCAL'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled  = true

[nginx-http-auth]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/error.log
JAILLOCAL
    systemctl restart fail2ban
    log "fail2ban 已配置"
}

init_docker() {
    log "安装 Docker..."
    if command -v docker &>/dev/null; then
        warn "Docker 已安装，跳过"
    else
        curl -fsSL https://get.docker.com | bash
    fi
    if ! docker compose version &>/dev/null 2>&1; then
        log "安装 docker compose 插件..."
        apt install -y -qq docker-compose-plugin
    fi
    if id "$DEPLOY_USER" &>/dev/null; then
        usermod -aG docker "$DEPLOY_USER" 2>/dev/null || true
    fi
    log "Docker 就绪"
}

init_user() {
    if id "$DEPLOY_USER" &>/dev/null; then
        warn "用户 $DEPLOY_USER 已存在"
    else
        log "创建部署用户 $DEPLOY_USER..."
        adduser --disabled-password --gecos "" "$DEPLOY_USER"
        usermod -aG sudo "$DEPLOY_USER"
    fi
    mkdir -p "/home/$DEPLOY_USER/.ssh"
    chmod 700 "/home/$DEPLOY_USER/.ssh"
    touch "/home/$DEPLOY_USER/.ssh/authorized_keys"
    chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
    chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
    mkdir -p "/home/$DEPLOY_USER/app" "/home/$DEPLOY_USER/backups"
    chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/app" "/home/$DEPLOY_USER/backups"
    log "用户 $DEPLOY_USER 就绪"
}

# =============================================================================
# 阶段 2: Nginx + SSL（需要域名的模式使用）
# =============================================================================
setup_nginx() {
    if [ -z "$DOMAIN" ]; then
        warn "未指定域名，跳过 Nginx + SSL"
        return
    fi

    log "配置 Nginx → $DOMAIN ..."
    local upstream="http://127.0.0.1:${APP_PORT}"

    case "$MODE" in
        static)
            cat > "/etc/nginx/sites-available/${DOMAIN}" << NGINXCONF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root /var/www/${PROJECT_NAME};
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript;
    gzip_min_length 1000;
}
NGINXCONF
            ;;
        *)
            cat > "/etc/nginx/sites-available/${DOMAIN}" << NGINXCONF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};

    location / {
        proxy_pass ${upstream};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /ws/ {
        proxy_pass ${upstream};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /health {
        proxy_pass ${upstream};
        access_log off;
    }
}
NGINXCONF
            ;;
    esac

    ln -sf "/etc/nginx/sites-available/${DOMAIN}" /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx
    log "Nginx 配置完成"

    # SSL
    log "申请 SSL 证书..."
    if certbot --nginx -d "$DOMAIN" -d "www.${DOMAIN}" --non-interactive --agree-tos -m "$EMAIL" --redirect 2>/dev/null; then
        log "SSL 证书已安装"
    else
        warn "SSL 申请失败，HTTP 仍然可用（检查 DNS 和端口 80）"
    fi
}

# =============================================================================
# 阶段 3: 运行时部署
# =============================================================================
deploy_static() {
    log "部署静态前端..."
    if [ ! -d "$STATIC_DIR" ]; then
        err "静态目录 $STATIC_DIR 不存在。请先构建项目（npm run build / pnpm build）。"
    fi
    local target="/var/www/${PROJECT_NAME}"
    mkdir -p "$target"
    cp -r "${STATIC_DIR}/"* "$target/"
    chown -R www-data:www-data "$target"
    log "静态文件已部署到 $target"
}

deploy_docker() {
    local runtime="$1"
    log "使用 Docker 部署 $runtime 项目..."

    if [ ! -f "$DOCKERFILE" ]; then
        log "未找到 $DOCKERFILE，自动生成..."
        generate_dockerfile "$runtime"
    fi

    local target="/home/${DEPLOY_USER}/app"
    mkdir -p "$target"
    cp "$DOCKERFILE" "$target/Dockerfile"
    [ -f "docker-compose.yml" ] && cp docker-compose.yml "$target/docker-compose.yml"
    [ -f ".env" ]              && cp .env "$target/.env"
    [ -f ".env.production" ]   && cp .env.production "$target/.env"
    cp -r "$DOCKER_CONTEXT"/* "$target/" 2>/dev/null || true
    chown -R "$DEPLOY_USER:$DEPLOY_USER" "$target"

    cd "$target"
    docker compose up -d --build
    log "Docker 服务已启动"
}

generate_dockerfile() {
    local runtime="$1"
    case "$runtime" in
        node)
            cat > "$DOCKERFILE" << DOCKERNODE
FROM node:22-alpine AS base
WORKDIR /app
COPY package.json package-lock.json* pnpm-lock.yaml* yarn.lock* ./
RUN if [ -f pnpm-lock.yaml ]; then npm install -g pnpm && pnpm install --production; \\
    elif [ -f yarn.lock ]; then yarn install --production; \\
    else npm install --production; fi

FROM node:22-alpine
WORKDIR /app
COPY --from=base /app/node_modules ./node_modules
COPY . .
RUN addgroup -g 1001 -S appgroup && adduser -S appuser -u 1001 -G appgroup
USER appuser
EXPOSE ${APP_PORT}
CMD ["node", "index.js"]
DOCKERNODE
            ;;
        python)
            cat > "$DOCKERFILE" << DOCKERPYTHON
FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN addgroup --gid 1001 appgroup && useradd --uid 1001 -g appgroup --create-home appuser
USER appuser
EXPOSE ${APP_PORT}
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "${APP_PORT}"]
DOCKERPYTHON
            ;;
    esac
    log "已生成 $DOCKERFILE"
}

deploy_go() {
    log "部署 Go 项目..."

    if [ ! -f "go.mod" ]; then
        err "未找到 go.mod，请在项目根目录运行。"
    fi

    local binary_name="${PROJECT_NAME}"
    log "编译 Go 二进制（linux/amd64）..."
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o "$binary_name" .

    local target="/home/${DEPLOY_USER}/app"
    mkdir -p "$target"
    cp "$binary_name" "$target/"
    [ -f ".env" ]            && cp .env "$target/"
    [ -f ".env.production" ] && cp .env.production "$target/.env"
    chmod +x "$target/$binary_name"
    chown -R "$DEPLOY_USER:$DEPLOY_USER" "$target"

    cat > "/etc/systemd/system/${PROJECT_NAME}.service" << SYSTEMD
[Unit]
Description=${PROJECT_NAME} Go Service
After=network.target
[Service]
Type=simple
User=${DEPLOY_USER}
WorkingDirectory=/home/${DEPLOY_USER}/app
EnvironmentFile=/home/${DEPLOY_USER}/app/.env
ExecStart=/home/${DEPLOY_USER}/app/${binary_name}
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
SYSTEMD

    systemctl daemon-reload
    systemctl enable "${PROJECT_NAME}"
    systemctl restart "${PROJECT_NAME}"
    log "Go 服务已启动（systemd）"
}

# =============================================================================
# 阶段 4: 通用收尾
# =============================================================================
setup_backup() {
    log "生成备份脚本..."
    cat > "/home/${DEPLOY_USER}/backups/backup.sh" << 'BACKUPSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="/home/deploy/backups"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=30
if command -v docker &>/dev/null && docker compose -f /home/deploy/app/docker-compose.yml ps db &>/dev/null 2>&1; then
    docker compose -f /home/deploy/app/docker-compose.yml exec -T db pg_dump -U app app_production | gzip > "$BACKUP_DIR/db_$DATE.sql.gz"
    echo "[✓] DB backup: db_$DATE.sql.gz"
fi
find "$BACKUP_DIR" -name "*.sql.gz" -mtime "+$RETENTION_DAYS" -delete 2>/dev/null || true
BACKUPSCRIPT
    chmod +x "/home/${DEPLOY_USER}/backups/backup.sh"
    chown "$DEPLOY_USER:$DEPLOY_USER" "/home/${DEPLOY_USER}/backups/backup.sh"

    (crontab -u "$DEPLOY_USER" -l 2>/dev/null || true; echo "0 3 * * * /home/${DEPLOY_USER}/backups/backup.sh >> /home/${DEPLOY_USER}/backups/cron.log 2>&1") | crontab -u "$DEPLOY_USER" -
    log "备份脚本 + cron 已设置（每日 03:00）"
}

setup_healthcheck() {
    log "生成健康检查脚本..."
    cat > "/home/${DEPLOY_USER}/app/healthcheck.sh" << 'HCSCRIPT'
#!/usr/bin/env bash
endpoint="${1:-http://127.0.0.1:3000/health}"
timeout 10 curl -fsS "$endpoint" && echo "[OK]" || echo "[FAIL]"
HCSCRIPT
    chmod +x "/home/${DEPLOY_USER}/app/healthcheck.sh"
    chown "$DEPLOY_USER:$DEPLOY_USER" "/home/${DEPLOY_USER}/app/healthcheck.sh"
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    echo ""
    log "=== 阶段 1/4: 系统初始化 ==="
    init_system
    init_swap
    init_user
    init_ssh
    init_firewall
    init_fail2ban

    log "=== 阶段 2/4: Docker（按需）==="
    case "$MODE" in node|python) init_docker ;; *) info "当前模式不需要 Docker，跳过";; esac

    log "=== 阶段 3/4: 部署 $MODE ==="
    case "$MODE" in
        static)  deploy_static ;;
        node)    deploy_docker node ;;
        python)  deploy_docker python ;;
        go)      deploy_go ;;
    esac

    setup_nginx

    log "=== 阶段 4/4: 收尾 ==="
    setup_backup
    setup_healthcheck

    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║  部署完成！                              ║"
    echo "╠══════════════════════════════════════════╣"
    printf "║  项目:    %-31s ║\n" "$PROJECT_NAME"
    printf "║  模式:    %-31s ║\n" "$MODE"
    [ -n "$DOMAIN" ] && printf "║  地址:    https://%-22s ║\n" "$DOMAIN"
    printf "║  端口:    %-31s ║\n" "$APP_PORT"
    echo "╠══════════════════════════════════════════╣"
    echo "║  常用命令:                                ║"
    echo "║    make status  — 查看状态                ║"
    echo "║    make logs    — 查看日志                ║"
    echo "║    make restart — 重启服务                ║"
    echo "║    make backup  — 手动备份                ║"
    echo "║    make ssh     — SSH 登录                ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
}

main
