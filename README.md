## 🚀 快速开始 (Getting Started)

```bash
wget -P /root -N --no-check-certificate "https://raw.githubusercontent.com/yd2005/sshcode/refs/heads/main/caddy-naive-install.sh" && chmod 700 /root/caddy-naive-install.sh && /root/caddy-naive-install.sh
```

# [项目名称] (例如: AutoCaddy-SSL-Manager)

> 一句话简介：这里写项目的简短描述，例如：全自动申请 Let's Encrypt 泛域名证书并自动配置 Caddy 反向代理的 Shell 脚本。

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/language-Bash-green.svg)]()
[![Version](https://img.shields.io/badge/version-v1.0.0-orange.svg)]()

## 📖 目录 (Table of Contents)

- [背景](#-背景-background)
- [功能特性](#-功能特性-features)
- [环境要求](#-环境要求-prerequisites)
- [快速开始](#-快速开始-getting-started)
- [使用说明](#-使用说明-usage)
- [配置说明](#-配置说明-configuration)
- [常见问题](#-常见问题-faq)
- [贡献指南](#-贡献指南-contributing)
- [许可证](#-许可证-license)

---

## 🧐 背景 (Background)

在此处简要说明编写此脚本的原因。
*例如：在部署微服务时，手动为每个子域名申请 SSL 证书并修改 Caddyfile 极其繁琐。本项目旨在通过一行命令，实现“输入主域名 -> 自动申请通配符证书 -> 自动重载服务”的全自动化流程。*

## ✨ 功能特性 (Features)

- ✅ **自动化证书申请**：集成 acme.sh/certbot，支持 DNS API 验证。
- ✅ **智能泛域名支持**：输入 `example.com` 自动申请 `*.example.com`。
- ✅ **Caddy 热重载**：配置修改后自动 reload，无须重启服务。
- ✅ **日志审计**：详细的操作日志记录，便于排查问题。

## 🛠 环境要求 (Prerequisites)

在运行此脚本之前，请确保您的服务器满足以下条件：

- Linux (Ubuntu/Debian/CentOS)
- [Caddy Server](https://caddyserver.com/) v2.x 已安装
- `curl` 和 `jq` (用于 API 交互)
- 域名服务商的 API Key (如 Cloudflare, AliYun 等)
