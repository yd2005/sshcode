#!/bin/bash

# ==============================================================
# 脚本名称: caddy-naive-download.sh (v2ray-agent内核复刻版)
# 功能: Caddy+NaiveProxy 下载部署 & 参考级证书申请逻辑
# 架构: AMD64 / ARM64
# ==============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 下载源配置
BASE_URL="https://github.com/yd2005/Actions-P3TERX/releases/download/build-4"

# 路径配置
CADDY_DIR="/etc/caddy"
CERT_DIR="/etc/naiveproxy/certs"
ACME_SH_DIR="$HOME/.acme.sh"
PORT_MAIN=8443
PORT_RANGE_START=3600
PORT_RANGE_END=3610

# 检查 Root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本。${PLAIN}" && exit 1

# 1. 系统架构检测
check_system() {
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        FILE_NAME="caddy-linux-amd64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        FILE_NAME="caddy-linux-arm64"
    else
        echo -e "${RED}不支持的系统架构: $ARCH${PLAIN}"
        exit 1
    fi
    echo -e "${GREEN}系统架构检测通过: $ARCH${PLAIN}"
}

# 2. 安装系统依赖 (参考 install.sh 的 installTools 函数)
install_dependencies() {
    echo -e "${YELLOW}正在安装系统依赖 (curl, wget, socat, cron, openssl)...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y
        apt-get install -y curl wget socat cron openssl tar jq libnss3-tools iptables-persistent netfilter-persistent
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget socat cronie openssl tar jq
    fi
}

# 3. 下载 Caddy
download_caddy() {
    echo -e "${YELLOW}正在下载 Caddy...${PLAIN}"
    systemctl stop caddy 2>/dev/null

    DOWNLOAD_URL="${BASE_URL}/${FILE_NAME}"
    echo -e "下载地址: ${DOWNLOAD_URL}"

    wget --no-check-certificate -O /tmp/caddy_download "$DOWNLOAD_URL"

    if [[ ! -s "/tmp/caddy_download" ]]; then
        echo -e "${RED}下载失败或文件为空！${PLAIN}"
        exit 1
    fi

    mv /tmp/caddy_download /usr/bin/caddy
    chmod +x /usr/bin/caddy

    if /usr/bin/caddy list-modules | grep -q "forward_proxy"; then
        echo -e "${GREEN}Caddy 安装成功 (含 NaiveProxy 插件)。${PLAIN}"
    else
        echo -e "${RED}错误：下载的文件不包含插件！${PLAIN}"
        exit 1
    fi
}

# 4. 证书申请 (完全复刻 install.sh 的 acmeInstallSSL 逻辑)
check_and_issue_cert() {
    mkdir -p "$CERT_DIR"
    
    echo -e "${YELLOW}请输入您的域名:${PLAIN}"
    read -p "域名: " DOMAIN
    
    CERT_FILE="$CERT_DIR/${DOMAIN}.crt"
    KEY_FILE="$CERT_DIR/${DOMAIN}.key"
    
    # 安装 acme.sh (参考 install.sh 的 installTools)
    if [[ ! -f "$ACME_SH_DIR/acme.sh" ]]; then
        echo -e "${YELLOW}正在安装 acme.sh...${PLAIN}"
        curl -s https://get.acme.sh | sh -s email=admin@${DOMAIN}
        source ~/.bashrc 2>/dev/null
    fi
    
    # 检查 acme.sh 是否安装成功
    if [[ ! -f "$ACME_SH_DIR/acme.sh" ]]; then
        echo -e "${RED}acme.sh 安装失败，请检查网络连接。${PLAIN}"
        exit 1
    fi

    # 获取 Cloudflare Token
    echo -e "${YELLOW}请输入 Cloudflare API Token (参考 v2ray-agent 仅需 DNS 编辑权限):${PLAIN}"
    read -p "CF_Token: " CF_TOKEN
    
    if [[ -z "$CF_TOKEN" ]]; then
        echo -e "${RED}错误: Token 不能为空。${PLAIN}"
        exit 1
    fi

    echo -e "${YELLOW}开始申请证书 (ECC-256)...${PLAIN}"
    
    # =========================================================
    # 核心复刻点：不进行API预检，直接通过环境变量传参给 acme.sh
    # 对应 install.sh 中 acmeInstallSSL 函数的逻辑
    # 强制使用 --server letsencrypt 和 -k ec-256 (ECC证书)
    # =========================================================
    
    export CF_Token="$CF_TOKEN"
    
    # 申请证书
    "$ACME_SH_DIR/acme.sh" --issue --server letsencrypt --dns dns_cf -d "$DOMAIN" -k ec-256
    
    local RET=$?
    if [[ $RET -ne 0 ]]; then
        echo -e "${RED}证书申请失败！错误代码: $RET${PLAIN}"
        echo -e "${YELLOW}建议检查：${PLAIN}"
        echo -e "1. Token 是否有 'Zone:DNS:Edit' 权限"
        echo -e "2. 域名是否已托管在 Cloudflare"
        exit 1
    fi

    # 安装证书 (对应 install.sh 的 installTLS 函数)
    # 注意：install.sh 使用了 --ecc 参数，我们也必须加上
    "$ACME_SH_DIR/acme.sh" --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "$CERT_FILE" \
        --key-file       "$KEY_FILE" \
        --reloadcmd      "systemctl reload caddy"
        
    if [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]]; then
        echo -e "${GREEN}证书安装成功！${PLAIN}"
        echo -e "Cert: $CERT_FILE"
        echo -e "Key:  $KEY_FILE"
    else
        echo -e "${RED}证书文件未生成，请检查日志。${PLAIN}"
        exit 1
    fi
}

# 5. 配置 Caddy
config_caddy() {
    echo -e "${YELLOW}正在生成配置文件...${PLAIN}"
    read -p "设置 NaiveProxy 用户名 [默认: admin]: " NAIVE_USER
    [[ -z "$NAIVE_USER" ]] && NAIVE_USER="admin"
    read -p "设置 NaiveProxy 密码 [默认: admin]: " NAIVE_PASS
    [[ -z "$NAIVE_PASS" ]] && NAIVE_PASS="admin"

    mkdir -p $CADDY_DIR
    mkdir -p /var/www/html
    
    if [[ ! -f /var/www/html/index.html ]]; then
        echo "<h1>It works!</h1>" > /var/www/html/index.html
    fi
    
    # 注意：这里引用了上面生成的 .crt 和 .key 文件路径
    cat > $CADDY_DIR/Caddyfile <<EOF
{
    admin off
    auto_https off
    order forward_proxy before file_server
}

:$PORT_MAIN, $DOMAIN:$PORT_MAIN {
    tls $CERT_DIR/${DOMAIN}.crt $CERT_DIR/${DOMAIN}.key
    
    forward_proxy {
        basic_auth $NAIVE_USER $NAIVE_PASS
        hide_ip
        hide_via
        probe_resistance
    }
    
    file_server {
        root /var/www/html
    }
}
EOF
}

# 6. 配置防火墙与服务
setup_service_and_firewall() {
    echo -e "${YELLOW}配置端口转发与系统服务...${PLAIN}"
    
    if command -v iptables >/dev/null 2>&1; then
        iptables -t nat -D PREROUTING -p tcp --dport $PORT_RANGE_START:$PORT_RANGE_END -j REDIRECT --to-port $PORT_MAIN 2>/dev/null
        iptables -t nat -A PREROUTING -p tcp --dport $PORT_RANGE_START:$PORT_RANGE_END -j REDIRECT --to-port $PORT_MAIN
        
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save
        fi
    fi

    cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config $CADDY_DIR/Caddyfile
ExecReload=/usr/bin/caddy reload --config $CADDY_DIR/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable caddy
    systemctl restart caddy
    
    sleep 3
    if systemctl is-active --quiet caddy; then
        echo -e "${GREEN}Caddy 服务启动成功。${PLAIN}"
    else
        echo -e "${RED}Caddy 服务启动失败，请检查日志: journalctl -u caddy -f${PLAIN}"
        exit 1
    fi
}

# 7. 输出节点信息
show_node_info() {
    echo ""
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}            NaiveProxy 安装完成               ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "核心监听端口: ${YELLOW}$PORT_MAIN${PLAIN}"
    echo -e "额外转发端口: ${YELLOW}$PORT_RANGE_START - $PORT_RANGE_END${PLAIN}"
    echo -e "域名: ${YELLOW}$DOMAIN${PLAIN}"
    echo -e "用户名: ${YELLOW}$NAIVE_USER${PLAIN}"
    echo -e "密码: ${YELLOW}$NAIVE_PASS${PLAIN}"
    echo ""
    echo -e "${GREEN}客户端配置 (config.json):${PLAIN}"
    echo -e "\033[36m{"
    echo -e "  \"listen\": \"socks://127.0.0.1:1080\","
    echo -e "  \"proxy\": \"https://$NAIVE_USER:$NAIVE_PASS@$DOMAIN:$PORT_MAIN\""
    echo -e "}\033[0m"
    echo ""
    echo -e "请确保防火墙已放行 TCP 端口: $PORT_MAIN 以及 $PORT_RANGE_START-$PORT_RANGE_END"
}

# 主执行流程
main() {
    check_system
    install_dependencies
    download_caddy
    check_and_issue_cert
    config_caddy
    setup_service_and_firewall
    show_node_info
}

main
