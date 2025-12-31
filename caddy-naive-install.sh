#!/bin/bash

# ==============================================================
# 脚本名称: caddy-naive-download.sh
# 功能: Caddy+NaiveProxy 下载部署 (免编译) & 证书管理
# 架构: AMD64 / ARM64
# 源地址: https://github.com/yd2005/Actions-P3TERX/releases/download/build-4/
# ==============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 下载源配置
BASE_URL="https://github.com/yd2005/Actions-P3TERX/releases/download/build-4"

# 路径与端口配置
CADDY_DIR="/etc/caddy"
CERT_DIR="/etc/naiveproxy/certs"
ACME_SH_DIR="/root/.acme.sh"
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
        # 注意：这里使用未压缩版本以保证 VPS 性能，如果需要极致空间可改为 caddy-linux-arm64-upx
        FILE_NAME="caddy-linux-arm64"
    else
        echo -e "${RED}不支持的系统架构: $ARCH${PLAIN}"
        exit 1
    fi
    echo -e "${GREEN}系统架构检测通过: $ARCH${PLAIN}"
    echo -e "${GREEN}即将下载文件: $FILE_NAME${PLAIN}"
}

# 2. 安装系统依赖
install_dependencies() {
    echo -e "${YELLOW}正在安装系统依赖...${PLAIN}"
    # 更新软件源并安装基础工具
    if [ -f /etc/debian_version ]; then
        apt-get update -y
        apt-get install -y curl wget tar socat jq openssl cron iptables-persistent netfilter-persistent libnss3-tools
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget tar socat jq openssl cronie
    else
        echo -e "${RED}未知的操作系统，脚本仅支持 Debian/Ubuntu/CentOS${PLAIN}"
        exit 1
    fi
}

# 3. 下载 Caddy (替代原有的编译步骤)
download_caddy() {
    echo -e "${YELLOW}正在从 GitHub 下载定制版 Caddy...${PLAIN}"
    
    # 停止现有服务
    systemctl stop caddy 2>/dev/null

    DOWNLOAD_URL="${BASE_URL}/${FILE_NAME}"
    echo -e "下载地址: ${DOWNLOAD_URL}"

    # 下载到临时目录
    wget --no-check-certificate -q --show-progress -O /tmp/caddy_download "$DOWNLOAD_URL"

    # 验证下载
    if [[ ! -s "/tmp/caddy_download" ]]; then
        echo -e "${RED}下载失败或文件为空！请检查网络或 URL。${PLAIN}"
        exit 1
    fi

    # 安装
    mv /tmp/caddy_download /usr/bin/caddy
    chmod +x /usr/bin/caddy

    # 验证版本与插件
    if /usr/bin/caddy list-modules | grep -q "forward_proxy"; then
        echo -e "${GREEN}Caddy 安装成功且 NaiveProxy 插件验证通过。${PLAIN}"
    else
        echo -e "${RED}错误：下载的 Caddy 文件不包含 forward_proxy 插件！${PLAIN}"
        exit 1
    fi
}

# 4. 证书申请 (Acme.sh + Cloudflare DNS)
check_and_issue_cert() {
    mkdir -p "$CERT_DIR"
    
    echo -e "${YELLOW}==============================================${PLAIN}"
    echo -e "${YELLOW}           证书配置 (Cloudflare API)          ${PLAIN}"
    echo -e "${YELLOW}==============================================${PLAIN}"
    echo -e "${YELLOW}请输入您的域名:${PLAIN}"
    read -p "域名: " DOMAIN
    
    CERT_FILE="$CERT_DIR/fullchain.pem"
    KEY_FILE="$CERT_DIR/privkey.pem"
    
    NEED_ISSUE=1
    
    # 检查现有证书是否有效 (剩余有效期 > 30天)
    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        if openssl x509 -checkend 2592000 -noout -in "$CERT_FILE" >/dev/null 2>&1; then
            echo -e "${GREEN}检测到现有证书有效期充足，跳过申请步骤。${PLAIN}"
            NEED_ISSUE=0
        else
            echo -e "${YELLOW}证书不存在或即将过期，准备申请...${PLAIN}"
        fi
    fi

    if [[ "$NEED_ISSUE" -eq 1 ]]; then
        # 安装 acme.sh
        if [[ ! -f "$ACME_SH_DIR/acme.sh" ]]; then
            curl https://get.acme.sh | sh -s email=admin@${DOMAIN}
        fi
        
        echo -e "${YELLOW}请输入 Cloudflare API Token (仅需 DNS 编辑权限):${PLAIN}"
        read -p "CF_Token: " CF_TOKEN
        
        if [[ -z "$CF_TOKEN" ]]; then
            echo -e "${RED}错误: Token 不能为空。${PLAIN}"
            exit 1
        fi
        
        # 设置环境变量
        export CF_Token="$CF_TOKEN"
        
        # 尝试验证 Token
        echo -e "${YELLOW}正在验证 Token...${PLAIN}"
        CF_ACCOUNT_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
             -H "Authorization: Bearer $CF_TOKEN" \
             -H "Content-Type:application
