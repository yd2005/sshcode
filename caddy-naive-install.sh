#!/bin/sh

# ================= 配置区域 =================
# 【关键】请修改下面的链接！
# 填入 GitHub Release 的"目录"链接（不包含具体文件名）
# 例如你的某个文件链接是: https://github.com/abc/repo/releases/download/build-1/caddy-linux-arm64-upx
# 那么请只填入到 "build-1" 为止，如下所示：
BASE_URL="https://github.com/yd2005/Actions-P3TERX/releases/download/build-4/"
# ===========================================

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 错误：请以 root 权限运行此脚本"
    exit 1
fi

echo "=== Caddy NaiveProxy 通用安装脚本 ==="
echo "=== 适配：VPS (AMD/ARM) & OpenWrt (AX6/AX6000) ==="

# 1. 环境检测
ARCH=$(uname -m)
IS_OPENWRT=0
if [ -f /etc/openwrt_release ]; then
    IS_OPENWRT=1
    echo ">>> 检测到系统环境：OpenWrt / ImmortalWrt (路由器)"
else
    echo ">>> 检测到系统环境：常规 Linux (VPS)"
fi

# 2. 确定目标文件名
TARGET_FILE=""

if [ "$ARCH" = "x86_64" ]; then
    echo ">>> 架构检测：AMD64 (x86_64)"
    TARGET_FILE="caddy-linux-amd64"
    if [ "$IS_OPENWRT" -eq 1 ]; then
       echo "❌ 暂不支持 x86 架构的 OpenWrt 自动脚本，建议手动安装。"
       exit 1
    fi
elif [ "$ARCH" = "aarch64" ]; then
    echo ">>> 架构检测：ARM64 (aarch64)"
    if [ "$IS_OPENWRT" -eq 1 ]; then
        # 路由器使用 UPX 压缩版
        TARGET_FILE="caddy-linux-arm64-upx"
        echo ">>> 策略：路由器环境，将下载 UPX 压缩版 (节省空间)"
    else
        # VPS 使用普通版
        TARGET_FILE="caddy-linux-arm64"
        echo ">>> 策略：VPS 环境，将下载标准 ARM64 版"
    fi
else
    echo "❌ 不支持的架构：$ARCH"
    exit 1
fi

DOWNLOAD_URL="${BASE_URL}/${TARGET_FILE}"
echo ">>> 准备下载：$DOWNLOAD_URL"

# 3. 下载文件
# 停止现有服务
if [ "$IS_OPENWRT" -eq 1 ]; then
    /etc/init.d/caddy stop 2>/dev/null
else
    systemctl stop caddy 2>/dev/null
fi

echo ">>> 正在下载..."
# OpenWrt 可能没有 curl，优先使用 wget，且不检查证书(防止老旧系统根证书缺失)
wget --no-check-certificate -O /tmp/caddy_new "$DOWNLOAD_URL"

if [ ! -s "/tmp/caddy_new" ]; then
    echo "❌ 下载失败或文件为空！请检查 BASE_URL 是否正确。"
    echo "尝试访问链接: $DOWNLOAD_URL"
    exit 1
fi

# 4. 安装文件
echo ">>> 安装二进制文件..."
mv /tmp/caddy_new /usr/bin/caddy
chmod +x /usr/bin/caddy

# 验证
if ! /usr/bin/caddy version >/dev/null 2>&1; then
    echo "❌ 错误：下载的文件无法运行！可能架构不匹配或文件损坏。"
    exit 1
fi
echo "✅ 二进制文件安装成功！"

# 5. 配置服务 (分流处理)
if [ "$IS_OPENWRT" -eq 1 ]; then
    # ================= OpenWrt 配置 =================
    echo ">>> 配置 OpenWrt Procd 服务..."
    
    # 创建 Caddyfile (如果不存在)
    if [ ! -f /etc/caddy/Caddyfile ]; then
        mkdir -p /etc/caddy
        echo "# Caddyfile for OpenWrt" > /etc/caddy/Caddyfile
        echo ":80 {" >> /etc/caddy/Caddyfile
        echo "    respond \"Hello OpenWrt\"" >> /etc/caddy/Caddyfile
        echo "}" >> /etc/caddy/Caddyfile
        echo ">>> 已创建默认配置 /etc/caddy/Caddyfile"
    fi

    # 创建启动脚本
    cat > /etc/init.d/caddy <<EOF
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service() {
    procd_open_instance
    # 路由器通常直接使用 root 运行，避免权限问题
    procd_set_param command /usr/bin/caddy run --environ --config /etc/caddy/Caddyfile --adapter caddyfile
    procd_set_param limits core="unlimited"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
    chmod +x /etc/init.d/caddy
    /etc/init.d/caddy enable
    /etc/init.d/caddy restart
    echo "=== OpenWrt 部署完成 ==="
    echo "请编辑 /etc/caddy/Caddyfile 后运行: /etc/init.d/caddy restart"

else
    # ================= VPS (Systemd) 配置 =================
    echo ">>> 配置 Systemd 服务..."
    
    # 基础工具
    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install -y libnss3-tools
    fi

    # 用户配置
    groupadd --system caddy 2>/dev/null
    useradd --system --gid caddy --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy 2>/dev/null
    mkdir -p /etc/caddy
    chown -R caddy:caddy /etc/caddy

    # 创建默认配置
    if [ ! -f /etc/caddy/Caddyfile ]; then
        touch /etc/caddy/Caddyfile
        echo "# Caddyfile for VPS" > /etc/caddy/Caddyfile
    fi

    # Systemd 文件
    cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable caddy
    systemctl restart caddy
    
    echo "=== VPS 部署完成 ==="
    systemctl status caddy --no-pager
fi
