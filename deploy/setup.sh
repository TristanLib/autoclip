#!/bin/bash
# AutoClip Ubuntu 服务器一键部署脚本
# 使用方式: sudo bash deploy/setup.sh
set -euo pipefail

APP_DIR="/opt/autoclip"          # 应用部署目录（可修改）
APP_USER="autoclip"              # 运行服务的系统用户
PYTHON_VERSION="3.11"           # Python 版本

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
err_exit(){ echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── 检查 root ──────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || err_exit "请用 sudo 运行此脚本"

# ── 1. 安装系统依赖 ────────────────────────────────────────────────────────────
info "安装系统依赖..."
apt-get update -q
apt-get install -y -q \
  python3 python3-pip python3-venv \
  nodejs npm \
  redis-server \
  ffmpeg \
  nginx \
  git curl wget

# 启用 Redis 自启动
systemctl enable redis-server
systemctl start redis-server
info "Redis 已启动"

# ── 2. 创建系统用户 ────────────────────────────────────────────────────────────
if ! id "$APP_USER" &>/dev/null; then
  useradd --system --shell /bin/bash --home "$APP_DIR" --create-home "$APP_USER"
  info "创建用户: $APP_USER"
fi

# ── 3. 复制代码到部署目录 ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(dirname "$SCRIPT_DIR")"   # autoclip 项目根目录

info "复制代码到 $APP_DIR ..."
rsync -a --exclude='.git' --exclude='venv' --exclude='frontend/node_modules' \
      --exclude='data/projects' --exclude='data/uploads' --exclude='*.log' \
      "$SRC_DIR/" "$APP_DIR/"

# 创建必要目录
mkdir -p "$APP_DIR"/{data,logs,uploads}
mkdir -p "$APP_DIR/data/projects"

# ── 4. 配置 settings.json ──────────────────────────────────────────────────────
if [ ! -f "$APP_DIR/data/settings.json" ]; then
  warn "未找到 data/settings.json，从示例文件创建..."
  cp "$APP_DIR/data/settings.json.example" "$APP_DIR/data/settings.json" 2>/dev/null || \
  cat > "$APP_DIR/data/settings.json" << 'JSON'
{
  "llm_provider": "gemini",
  "gemini_api_key": "请填写你的 Gemini API Key",
  "model_name": "gemini-flash-latest",
  "chunk_size": 5000,
  "min_score_threshold": 0.7,
  "max_clips_per_collection": 5
}
JSON
  warn "请编辑 $APP_DIR/data/settings.json 填写 API Key！"
fi

# ── 5. Python 虚拟环境 ─────────────────────────────────────────────────────────
info "创建 Python 虚拟环境..."
cd "$APP_DIR"
python3 -m venv venv
venv/bin/pip install --quiet --upgrade pip
venv/bin/pip install --quiet -r requirements.txt
venv/bin/pip install --quiet pytz google-generativeai yt-dlp

# 初始化数据库
info "初始化数据库..."
venv/bin/python -c "
from backend.core.database import engine, Base
from backend.models import project, task, clip, collection, bilibili
Base.metadata.create_all(bind=engine)
print('数据库初始化完成')
"

# ── 6. 构建前端 ────────────────────────────────────────────────────────────────
info "构建前端..."
cd "$APP_DIR/frontend"
npm install --silent
npm run build
info "前端构建完成: $APP_DIR/frontend/dist"
cd "$APP_DIR"

# ── 7. 安装 systemd 服务 ───────────────────────────────────────────────────────
info "安装 systemd 服务..."

# 替换服务文件中的路径占位符
sed "s|APP_DIR|$APP_DIR|g; s|APP_USER|$APP_USER|g" \
    "$APP_DIR/deploy/autoclip-backend.service" \
    > /etc/systemd/system/autoclip-backend.service

sed "s|APP_DIR|$APP_DIR|g; s|APP_USER|$APP_USER|g" \
    "$APP_DIR/deploy/autoclip-celery.service" \
    > /etc/systemd/system/autoclip-celery.service

systemctl daemon-reload
systemctl enable autoclip-backend autoclip-celery
systemctl restart autoclip-backend autoclip-celery

# ── 8. 配置 Nginx ─────────────────────────────────────────────────────────────
info "配置 Nginx..."

# 用环境变量 SERVER_NAME 指定域名/IP，未设置则用服务器 IP
SERVER_NAME="${SERVER_NAME:-$(hostname -I | awk '{print $1}')}"
info "Nginx server_name: $SERVER_NAME"

sed "s|APP_DIR|$APP_DIR|g; s|SERVER_NAME_PLACEHOLDER|$SERVER_NAME|g" \
    "$APP_DIR/deploy/nginx.conf" \
    > /etc/nginx/sites-available/autoclip

ln -sf /etc/nginx/sites-available/autoclip /etc/nginx/sites-enabled/autoclip
# ⚠️  不删除 default，避免影响已有站点
# 如果 default 与 autoclip 端口冲突，手动执行：
#   rm /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx
info "Nginx 配置完成（已跳过删除 default，如有冲突请手动处理）"

# ── 9. 权限修正 ────────────────────────────────────────────────────────────────
chown -R "$APP_USER:$APP_USER" "$APP_DIR"

# ── 完成 ──────────────────────────────────────────────────────────────────────
info "════════════════════════════════════════"
info "部署完成！"
info "  前端界面: http://$(hostname -I | awk '{print $1}')"
info "  后端 API: http://$(hostname -I | awk '{print $1}')/api/v1"
info ""
warn "如果还没填 API Key，请运行："
warn "  nano $APP_DIR/data/settings.json"
warn "  systemctl restart autoclip-backend autoclip-celery"
info "════════════════════════════════════════"
