# mosdns DoH 一行部署器

这个安装器复刻当前服务器上的 mosdns + Caddy 结构，支持 Debian/Ubuntu 的 systemd 环境，目标架构为 amd64 和 arm64。

## 一行安装

发布到 GitHub 后：

```bash
curl -fsSL https://raw.githubusercontent.com/EchoLunar/mosdns-doh/main/install.sh | sudo bash
```

安装器会交互询问 DoH 域名、Cloudflare API Token、是否放行 TCP 8443，以及是否覆盖已有配置。

Cloudflare Token 只需要目标 Zone 的 DNS 编辑权限。DoH 域名的 A/AAAA 记录需要提前指向服务器。

## 当前配置

安装后的服务结构为：

```text
Caddy:  <domain>:8443
  └── HTTPS / Cloudflare DNS-01
      └── reverse_proxy 127.0.0.1:8053
          └── mosdns /dns-query
```

分流、ECS 和规则来源与当前配置保持一致：

- 国内上游：AliDNS DoH、DoH.pub
- 国外上游：Cloudflare 两个地址、Google 两个地址
- `foreign-overrides.txt` 优先
- `geosite-cn.txt` 和 `domestic-extra.txt` 走国内上游
- 其他域名走国外上游
- ECS IPv4/IPv6 掩码为 24/48
- 不监听 53，不修改 3x-ui、Xray 或 443

## 必须发布的 Release 资产

当前配置依赖自定义 `v5.3.4-client-ecs` 构建，不能替换成普通 mosdns。每个 Release 需要提供：

```text
mosdns-linux-amd64
mosdns-linux-arm64
caddy-linux-amd64
caddy-linux-arm64
SHA256SUMS
```

Caddy 二进制必须包含：

```text
dns.providers.cloudflare
```

脚本会验证版本、Cloudflare 模块和 SHA256；校验失败会停止，不会安装不兼容版本。

在未发布自己的 Release 前，可以通过环境变量临时指定资产地址：

```bash
MOSDNS_DOH_ARTIFACT_BASE_URL=https://github.com/EchoLunar/mosdns-doh/releases/download/v5.3.4-client-ecs \
  sudo -E bash install.sh install
```

如果当前服务器上已经安装了匹配版本，可以用发布工具生成当前架构资产：

```bash
sudo ./make-release-assets.sh --arch arm64 --output ./release-assets
```

把两个架构的二进制放到同一个 `release-assets/` 目录后运行打包工具，确保同一份 `SHA256SUMS` 同时包含 amd64 和 arm64，再上传到 GitHub Release。

## 管理命令

```bash
sudo /path/to/install.sh check
sudo /path/to/install.sh update-rules
sudo /path/to/install.sh renew
```

配置位置：

```text
/etc/mosdns/config.yaml
/etc/caddy/Caddyfile
/etc/caddy/cloudflare.env
/var/lib/mosdns/rules/
```

首次覆盖已有配置时会先备份到 `/var/backups/mosdns-doh/`。
