#!/bin/bash

# ==============================================================
# 脚本名称: caddy-final.sh
# 功能: 智能容错证书申请 + 泛域名自动推导 + BBR/内核优化
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

# 1. 智能内核优化
optimize_system() {
    echo -e "${YELLOW}正在检查系统内核状态...${PLAIN}"
    
    # 简单检查 BBR 是否开启
    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo -e "${GREEN}BBR 已开启，跳过优化。${PLAIN}"
        return
    fi

    echo -e "${YELLOW}正在应用内核优化 (参考 v2ray-agent)...${PLAIN}"
    cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%F)
    
    cat >> /etc/sysctl.conf <<EOF
fs.file-max = 1000000
fs.inotify.max_user_instances = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 6000
net.ipv4.route.gc_timeout = 100
net.ipv4.tcp_syn_retries = 1
net.ipv4.tcp_synack_retries = 1
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_max_orphans = 32768
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl -p >/dev/null 2>&1
    
    if ! grep -q "ulimit -SHn 65535" /etc/profile; then
        echo "ulimit -SHn 65535" >> /etc/profile
        ulimit -SHn 65535
    fi
}

# 2. 系统架构检测
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
}

# 3. 安装依赖
install_dependencies() {
    echo -e "${YELLOW}正在安装系统依赖...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y
        apt-get install -y curl wget socat cron openssl tar jq libnss3-tools iptables-persistent netfilter-persistent
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget socat cronie openssl tar jq
    fi
}

# 4. 下载 Caddy
download_caddy() {
    echo -e "${YELLOW}正在下载 Caddy...${PLAIN}"
    systemctl stop caddy 2>/dev/null
    
    DOWNLOAD_URL="${BASE_URL}/${FILE_NAME}"
    echo -e "下载地址: ${DOWNLOAD_URL}"
    
    wget --no-check-certificate -q --show-progress -O /tmp/caddy_download "$DOWNLOAD_URL"
    if [[ ! -s "/tmp/caddy_download" ]]; then
        echo -e "${RED}下载失败！${PLAIN}"
        exit 1
    fi

    mv /tmp/caddy_download /usr/bin/caddy
    chmod +x /usr/bin/caddy

    if /usr/bin/caddy list-modules | grep -q "forward_proxy"; then
        echo -e "${GREEN}Caddy 验证通过。${PLAIN}"
    else
        echo -e "${RED}错误：下载的文件不包含插件！${PLAIN}"
        exit 1
    fi
}

# 5. 证书申请 (容错版)
check_and_issue_cert() {
    mkdir -p "$CERT_DIR"
    
    echo -e "${YELLOW}=================================================${PLAIN}"
    echo -e "${YELLOW}   泛域名证书申请 (Wildcard Certificate)         ${PLAIN}"
    echo -e "${YELLOW}=================================================${PLAIN}"
    echo -e "${YELLOW}请输入具体的节点域名 (例如: vps.google.com)${PLAIN}"
    read -p "具体域名: " INPUT_DOMAIN
    
    if [[ -z "$INPUT_DOMAIN" ]]; then
        echo -e "${RED}域名不能为空！${PLAIN}"
        exit 1
    fi

    # 提取主域名
    ROOT_DOMAIN="${INPUT_DOMAIN#*.}"
    if [[ "$ROOT_DOMAIN" == "$INPUT_DOMAIN" ]]; then
         echo -e "${RED}错误：请输入二级或多级域名 (例如 abc.example.com)${PLAIN}"
         exit 1
    fi

    WILDCARD_DOMAIN="*.${ROOT_DOMAIN}"
    echo -e "${GREEN}目标泛域名: ${WILDCARD_DOMAIN}${PLAIN}"

    CERT_FILE="$CERT_DIR/wildcard.${ROOT_DOMAIN}.crt"
    KEY_FILE="$CERT_DIR/wildcard.${ROOT_DOMAIN}.key"
    
    # 安装 acme.sh
    if [[ ! -f "$ACME_SH_DIR/acme.sh" ]]; then
        curl -s https://get.acme.sh | sh -s email=admin@${ROOT_DOMAIN}
        source ~/.bashrc 2>/dev/null
    fi

    # 预检证书有效性 (目标目录)
    NEED_ISSUE=1
    if [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]]; then
        if openssl x509 -checkend 2592000 -noout -in "$CERT_FILE" >/dev/null 2>&1; then
            echo -e "${GREEN}检测到目标目录已有有效证书，完全跳过申请。${PLAIN}"
            NEED_ISSUE=0
        fi
    fi

    if [[ "$NEED_ISSUE" -eq 1 ]]; then
        echo -e "${YELLOW}请输入 Cloudflare API Token:${PLAIN}"
        read -p "CF_Token: " CF_TOKEN
        [[ -z "$CF_TOKEN" ]] && echo -e "${RED}Token为空${
