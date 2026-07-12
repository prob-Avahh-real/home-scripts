#!/usr/bin/env bash
# =============================================
# warmup-coach 本地服务启动脚本
# 启动后在同一 WiFi 下的手机扫码即可打开
# =============================================
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8888}"
HTML_FILE="warmup-coach.html"

# --- 检测网络 IP ---
get_ip() {
  ifconfig 2>/dev/null \
    | grep "inet " \
    | grep -v "127.0.0.1" \
    | grep -v "198." \
    | awk '{print $2}' \
    | head -1
}

IP=$(get_ip 2>/dev/null || echo "localhost")
URL="http://${IP}:${PORT}"

# --- 检测可用服务器 ---
if command -v bun &>/dev/null; then
  SERVER="bun"
elif command -v python3 &>/dev/null; then
  SERVER="python"
elif command -v node &>/dev/null; then
  SERVER="node"
else
  echo "❌ 需要 Python3 / Node.js / Bun 其中至少一个"
  exit 1
fi

# --- 检查文件存在 ---
if [[ ! -f "$HTML_FILE" ]]; then
  echo "❌ 找不到 $HTML_FILE"
  echo "   请先确保文件存在于此目录"
  exit 1
fi

# --- 启动 ---
echo "🔥 热身教练服务启动中..."
echo ""
echo "   📱 在同一 WiFi 下用手机浏览器访问:"
echo "      $URL"
echo ""

# 尝试生成 QR 码（可选）
if command -v qrencode &>/dev/null; then
  echo "   📱 二维码 (终端内):"
  qrencode -t ANSIUTF8 -m 1 "$URL"
  echo ""
elif python3 -c "import qrcode" 2>/dev/null; then
  python3 -c "
import qrcode, sys
qr = qrcode.QRCode()
qr.add_data('$URL')
qr.print_ascii(invert=True)
" 2>/dev/null || true
fi

echo "   💡 提示:"
echo "      - iPhone: Safari 打开 → 分享按钮 → 「添加到主屏幕」"
echo "      - Android: Chrome 打开 → 菜单 → 「添加到主屏幕」"
echo "      - 添加到主屏幕后可离线使用（PWA）"
echo ""
echo "   ⏹ 按 Ctrl+C 停止服务器"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 重定向根路径到 HTML 文件
case "$SERVER" in
  bun)
    # Create temp server script for bun
    BUN_SCRIPT=$(mktemp /tmp/warmup-server-XXXX.js)
    cat > "$BUN_SCRIPT" << BUNEOF
const f = Bun.file("$PWD/$HTML_FILE");
const html = await f.text();
Bun.serve({
  port: $PORT,
  fetch(req) {
    return new Response(html, {
      headers: { "Content-Type": "text/html;charset=utf-8", "Cache-Control": "no-cache" }
    });
  }
});
console.log("bun server on :$PORT");
BUNEOF
    exec bun run "$BUN_SCRIPT"
    ;;
  python)
    exec python3 -m http.server "$PORT" --bind 0.0.0.0
    ;;
  node)
    exec node -e "
const http=require('http'),fs=require('fs'),path=require('path');
const html=fs.readFileSync('$HTML_FILE','utf8');
http.createServer((req,res)=>{
  const fp=req.url==='/'?'$HTML_FILE':'.'+req.url;
  if(fp==='$HTML_FILE'){res.writeHead(200,{'Content-Type':'text/html;charset=utf-8'});res.end(html);return;}
  try{const d=fs.readFileSync(fp);const ext=path.extname(fp);const mimes={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.svg':'image/svg+xml','.png':'image/png'};res.writeHead(200,{'Content-Type':mimes[ext]||'application/octet-stream'});res.end(d);}catch(e){res.writeHead(200,{'Content-Type':'text/html;charset=utf-8'});res.end(html);}
}).listen($PORT,'0.0.0.0',()=>console.log('node server on :$PORT'));
"
    ;;
esac
