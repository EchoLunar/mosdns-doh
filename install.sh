#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# One-line installer for the mosdns + Caddy DoH stack used by this host.
#
# The custom mosdns build is intentionally pinned. The current configuration
# uses the ecs_client plugin, which is not present in the stock mosdns binary.

readonly MOSDNS_VERSION="${MOSDNS_VERSION:-v5.3.4-client-ecs}"
readonly CADDY_VERSION="${CADDY_VERSION:-v2.11.4}"
readonly DOH_PORT="${DOH_PORT:-8443}"
readonly ARTIFACT_BASE_URL="${MOSDNS_DOH_ARTIFACT_BASE_URL:-https://github.com/EchoLunar/mosdns-doh/releases/download/${MOSDNS_VERSION}}"
readonly CF_API_BASE="https://api.cloudflare.com/client/v4"

readonly MOSDNS_BIN="/usr/local/bin/mosdns"
readonly CADDY_BIN="/usr/local/bin/caddy"
readonly MOSDNS_CONFIG="/etc/mosdns/config.yaml"
readonly MOSDNS_RULE_DIR="/var/lib/mosdns/rules"
readonly MOSDNS_RULE_SYNC="/usr/local/sbin/mosdns-sync-rules"
readonly CADDY_CONFIG="/etc/caddy/Caddyfile"
readonly CADDY_ENV="/etc/caddy/cloudflare.env"
readonly BACKUP_ROOT="/var/backups/mosdns-doh"

PROMPT_FD=""
DOH_DOMAIN="${DOH_DOMAIN:-}"
CF_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
OPEN_FIREWALL="${MOSDNS_DOH_OPEN_FIREWALL:-}"
OVERWRITE="${MOSDNS_DOH_OVERWRITE:-}"
IP_MODE="${MOSDNS_DOH_IP_MODE:-}"
BACKUP_DIR=""
TARGET_ARCH=""
PUBLIC_IPV4=""
PUBLIC_IPV6=""
CF_ZONE_ID=""
CF_ZONE_NAME=""

log() {
    printf '[mosdns-doh] %s\n' "$*"
}

warn() {
    printf '[mosdns-doh] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[mosdns-doh] ERROR: %s\n' "$*" >&2
    exit 1
}

on_error() {
    local rc=$?
    printf '[mosdns-doh] ERROR: command failed at line %s (exit %s)\n' "${BASH_LINENO[0]:-?}" "$rc" >&2
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        printf '[mosdns-doh] Existing files were backed up under %s\n' "$BACKUP_DIR" >&2
    fi
    exit "$rc"
}

trap on_error ERR

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 sudo 或 root 运行此脚本。"
}

require_supported_system() {
    [ -r /etc/os-release ] || die "找不到 /etc/os-release。"
    # shellcheck disable=SC1091
    . /etc/os-release

    local distro_id="${ID:-}" distro_like="${ID_LIKE:-}"
    case "$distro_id $distro_like" in
        debian*|ubuntu*|*debian*|*ubuntu*) ;;
        *) die "只支持 Debian/Ubuntu 或其 Debian 系衍生版，检测到 ${distro_id:-unknown}。" ;;
    esac

    command -v apt-get >/dev/null 2>&1 || die "找不到 apt-get。"
    command -v systemctl >/dev/null 2>&1 || die "找不到 systemd/systemctl。"
    [ "$(ps -p 1 -o comm= 2>/dev/null || true)" = "systemd" ] || die "当前环境不是以 systemd 作为 PID 1，无法按计划部署。"

    case "$(uname -m)" in
        x86_64|amd64) TARGET_ARCH="amd64" ;;
        aarch64|arm64) TARGET_ARCH="arm64" ;;
        *) die "不支持的 CPU 架构：$(uname -m)。仅支持 amd64 和 arm64。" ;;
    esac

    log "检测到 ${PRETTY_NAME:-$distro_id} / ${TARGET_ARCH} / systemd。"
}

install_dependencies() {
    log "安装基础依赖。"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates curl coreutils iproute2 jq openssl procps tar gzip
}

open_prompt_tty() {
    if [ -t 0 ]; then
        PROMPT_FD=0
    else
        exec {PROMPT_FD}<>/dev/tty || die "无法打开交互终端；非交互运行请设置 DOH_DOMAIN、CLOUDFLARE_API_TOKEN、MOSDNS_DOH_IP_MODE、MOSDNS_DOH_OPEN_FIREWALL 和 MOSDNS_DOH_OVERWRITE。"
    fi
}

ask_text() {
    local prompt=$1 variable=$2 value
    value="${!variable:-}"
    if [ -z "$value" ]; then
        read -r -u "$PROMPT_FD" -p "$prompt" value || die "读取输入失败。"
        printf '\n' >&2
        printf -v "$variable" '%s' "$value"
    fi
}

ask_secret() {
    local prompt=$1 variable=$2 value
    value="${!variable:-}"
    if [ -z "$value" ]; then
        read -r -s -u "$PROMPT_FD" -p "$prompt" value || die "读取密钥失败。"
        printf '\n' >&2
        printf -v "$variable" '%s' "$value"
    fi
}

ask_yes_no() {
    local prompt=$1 variable=$2 default=$3 answer
    answer="${!variable:-}"
    if [ -n "$answer" ]; then
        case "${answer,,}" in
            y|yes|1|true) printf -v "$variable" '%s' "yes"; return 0 ;;
            n|no|0|false) printf -v "$variable" '%s' "no"; return 0 ;;
            *) die "$variable 必须是 yes 或 no。" ;;
        esac
    fi

    while :; do
        read -r -u "$PROMPT_FD" -p "$prompt [$default] " answer || die "读取输入失败。"
        printf '\n' >&2
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|yes) printf -v "$variable" '%s' "yes"; return 0 ;;
            n|no) printf -v "$variable" '%s' "no"; return 0 ;;
            *) printf '请输入 y 或 n。\n' >&2 ;;
        esac
    done
}

ask_ip_mode() {
    local variable=$1 answer
    answer="${!variable:-}"
    if [ -n "$answer" ]; then
        case "${answer,,}" in
            ipv4|4) printf -v "$variable" '%s' "ipv4"; return 0 ;;
            ipv6|6) printf -v "$variable" '%s' "ipv6"; return 0 ;;
            dual|both|双栈) printf -v "$variable" '%s' "dual"; return 0 ;;
            *) die "$variable 必须是 ipv4、ipv6 或 dual。" ;;
        esac
    fi

    while :; do
        read -r -u "$PROMPT_FD" -p "自动解析本机公网地址到 Cloudflare（ipv4/ipv6/dual）[dual]：" answer || die "读取输入失败。"
        printf '\n' >&2
        answer="${answer:-dual}"
        case "${answer,,}" in
            ipv4|4) printf -v "$variable" '%s' "ipv4"; return 0 ;;
            ipv6|6) printf -v "$variable" '%s' "ipv6"; return 0 ;;
            dual|both|双栈) printf -v "$variable" '%s' "dual"; return 0 ;;
            *) printf '%s\n' '请输入 ipv4、ipv6 或 dual。' >&2 ;;
        esac
    done
}

validate_inputs() {
    DOH_DOMAIN="${DOH_DOMAIN,,}"
    [[ "$DOH_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] \
        || die "DoH 域名格式不正确：$DOH_DOMAIN"
    [[ "$CF_TOKEN" != *[[:space:]]* ]] || die "Cloudflare API Token 不能包含空格或换行。"
    [ -n "$CF_TOKEN" ] || die "Cloudflare API Token 不能为空。"
    case "$IP_MODE" in
        ipv4|ipv6|dual) ;;
        *) die "MOSDNS_DOH_IP_MODE 必须是 ipv4、ipv6 或 dual。" ;;
    esac
    [ "$DOH_PORT" -ge 1 ] 2>/dev/null && [ "$DOH_PORT" -le 65535 ] \
        || die "DOH_PORT 必须是 1-65535 之间的端口。"
}

cf_api_request() {
    local method=$1 url=$2 data=${3:-} response errors

    if [ -n "$data" ]; then
        response="$(curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
            --connect-timeout 15 --max-time 60 --proto '=https' --tlsv1.2 \
            -X "$method" \
            -H "Authorization: Bearer $CF_TOKEN" \
            -H 'Content-Type: application/json' \
            --data-raw "$data" "$url")" || die "Cloudflare API 请求失败。"
    else
        response="$(curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
            --connect-timeout 15 --max-time 60 --proto '=https' --tlsv1.2 \
            -X "$method" \
            -H "Authorization: Bearer $CF_TOKEN" \
            -H 'Content-Type: application/json' \
            "$url")" || die "Cloudflare API 请求失败。"
    fi

    if ! jq -e '.success == true' >/dev/null <<<"$response"; then
        errors="$(jq -r '[.errors[]? | (.message // "未知错误")] | join("; ")' <<<"$response" 2>/dev/null || true)"
        die "Cloudflare API 返回错误：${errors:-未知错误}"
    fi
    printf '%s' "$response"
}

find_cloudflare_zone() {
    local candidate="$DOH_DOMAIN" response zone_count

    while [[ "$candidate" == *.* ]]; do
        response="$(cf_api_request GET "${CF_API_BASE}/zones?name=${candidate}&status=active&per_page=50")"
        zone_count="$(jq '.result | length' <<<"$response")"
        if [ "$zone_count" -gt 0 ]; then
            CF_ZONE_ID="$(jq -r '.result[0].id' <<<"$response")"
            CF_ZONE_NAME="$(jq -r '.result[0].name' <<<"$response")"
            break
        fi
        candidate="${candidate#*.}"
    done

    [ -n "$CF_ZONE_ID" ] || die "Cloudflare 中找不到 ${DOH_DOMAIN} 对应的活动 Zone；请确认域名已接入当前账号。"
    log "已找到 Cloudflare Zone：${CF_ZONE_NAME}。"
}

is_valid_ipv4() {
    awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
            }
        }
    ' <<<"$1"
}

is_valid_ipv6() {
    [[ "$1" == *:* && "$1" != *[!0-9A-Fa-f:]* ]]
}

detect_public_addresses() {
    case "$IP_MODE" in
        ipv4|dual)
            PUBLIC_IPV4="$(curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
                --connect-timeout 15 --max-time 60 --proto '=https' --tlsv1.2 --ipv4 \
                https://api.ipify.org)" || die "无法检测本机公网 IPv4 地址。"
            is_valid_ipv4 "$PUBLIC_IPV4" || die "检测到的公网 IPv4 地址无效：$PUBLIC_IPV4"
            log "检测到本机公网 IPv4：${PUBLIC_IPV4}。"
            ;;
    esac

    case "$IP_MODE" in
        ipv6|dual)
            PUBLIC_IPV6="$(curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
                --connect-timeout 15 --max-time 60 --proto '=https' --tlsv1.2 --ipv6 \
                https://api6.ipify.org)" || die "无法检测本机公网 IPv6 地址；如果服务器没有 IPv6，请选择 ipv4。"
            is_valid_ipv6 "$PUBLIC_IPV6" || die "检测到的公网 IPv6 地址无效：$PUBLIC_IPV6"
            log "检测到本机公网 IPv6：${PUBLIC_IPV6}。"
            ;;
    esac
}

sync_cloudflare_record() {
    local record_type=$1 content=$2 response record_count record_id proxied payload
    response="$(cf_api_request GET \
        "${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records?type=${record_type}&name=${DOH_DOMAIN}&per_page=100")"
    record_count="$(jq '.result | length' <<<"$response")"

    if [ "$record_count" -gt 0 ]; then
        [ "$record_count" -eq 1 ] || warn "${DOH_DOMAIN} 存在 ${record_count} 条 ${record_type} 记录，将只更新第一条。"
        record_id="$(jq -r '.result[0].id' <<<"$response")"
        proxied="$(jq -r '.result[0].proxied // false' <<<"$response")"
        payload="$(jq -cn --arg type "$record_type" --arg name "$DOH_DOMAIN" \
            --arg content "$content" --argjson proxied "$proxied" \
            '{type: $type, name: $name, content: $content, ttl: 1, proxied: $proxied}')"
        cf_api_request PUT "${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records/${record_id}" "$payload" >/dev/null
        log "Cloudflare ${record_type} 记录已更新：${DOH_DOMAIN} -> ${content}。"
    else
        payload="$(jq -cn --arg type "$record_type" --arg name "$DOH_DOMAIN" \
            --arg content "$content" \
            '{type: $type, name: $name, content: $content, ttl: 1, proxied: false}')"
        cf_api_request POST "${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records" "$payload" >/dev/null
        log "Cloudflare ${record_type} 记录已创建：${DOH_DOMAIN} -> ${content}（DNS only）。"
    fi
}

configure_cloudflare_dns() {
    command -v jq >/dev/null 2>&1 || die "找不到 jq；请重新运行安装器以安装依赖。"
    detect_public_addresses
    find_cloudflare_zone

    case "$IP_MODE" in
        ipv4|dual) sync_cloudflare_record A "$PUBLIC_IPV4" ;;
    esac
    case "$IP_MODE" in
        ipv6|dual) sync_cloudflare_record AAAA "$PUBLIC_IPV6" ;;
    esac

    if [[ "$IP_MODE" != dual ]]; then
        warn "未选择的另一种地址类型不会被脚本删除；如已有对应记录，请按需手动清理。"
    fi
}

prompt_install_inputs() {
    open_prompt_tty
    ask_text "DoH 域名（例如 dns.example.com）：" DOH_DOMAIN
    ask_secret "Cloudflare API Token（输入不回显）：" CF_TOKEN
    ask_ip_mode IP_MODE
    ask_yes_no "是否自动在本机 UFW 放行 TCP ${DOH_PORT}？" OPEN_FIREWALL "no"
    ask_yes_no "检测到已有配置时是否备份并覆盖？" OVERWRITE "no"
    validate_inputs
}

has_existing_state() {
    local path
    for path in \
        "$MOSDNS_BIN" "$CADDY_BIN" "$MOSDNS_CONFIG" "$CADDY_CONFIG" "$CADDY_ENV" \
        /etc/systemd/system/mosdns.service \
        /etc/systemd/system/mosdns-rules.service \
        /etc/systemd/system/mosdns-rules.timer; do
        [ -e "$path" ] && return 0
    done
    return 1
}

backup_path() {
    local source=$1 relative target
    [ -e "$source" ] || return 0
    relative="${source#/}"
    target="$BACKUP_DIR/$relative"
    mkdir -p "$(dirname "$target")"
    cp -a "$source" "$target"
}

prepare_backup() {
    if ! has_existing_state; then
        return 0
    fi

    [ "$OVERWRITE" = "yes" ] || die "检测到已有 mosdns/Caddy 配置。请确认覆盖，或设置 MOSDNS_DOH_OVERWRITE=yes。"

    BACKUP_DIR="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
    install -d -m 0700 "$BACKUP_DIR"
    backup_path "$MOSDNS_BIN"
    backup_path "$CADDY_BIN"
    backup_path "$MOSDNS_CONFIG"
    backup_path "$CADDY_CONFIG"
    backup_path "$CADDY_ENV"
    backup_path /etc/systemd/system/mosdns.service
    backup_path /etc/systemd/system/mosdns-rules.service
    backup_path /etc/systemd/system/mosdns-rules.timer
    backup_path /var/lib/mosdns/rules/geosite-cn.txt
    backup_path /var/lib/mosdns/rules/domestic-extra.txt
    backup_path /var/lib/mosdns/rules/foreign-overrides.txt
    log "已有文件已备份到 $BACKUP_DIR。"
}

ensure_service_user() {
    if ! getent group mosdns >/dev/null; then
        groupadd --system mosdns
    fi
    if ! id mosdns >/dev/null 2>&1; then
        useradd --system --gid mosdns --home-dir /var/lib/mosdns \
            --no-create-home --shell /usr/sbin/nologin mosdns
    fi

    if ! getent group caddy >/dev/null; then
        groupadd --system caddy
    fi
    if ! id caddy >/dev/null 2>&1; then
        useradd --system --gid caddy --home-dir /var/lib/caddy \
            --no-create-home --shell /usr/sbin/nologin caddy
    fi

    install -d -o root -g mosdns -m 0750 /etc/mosdns
    install -d -o mosdns -g mosdns -m 0750 /var/lib/mosdns "$MOSDNS_RULE_DIR"
    install -d -o root -g root -m 0755 /etc/caddy
    install -d -o caddy -g caddy -m 0750 /var/lib/caddy /var/log/caddy
}

artifact_url() {
    local asset=$1
    printf '%s/%s\n' "${ARTIFACT_BASE_URL%/}" "$asset"
}

download_verified() {
    local asset=$1 destination=$2 workdir expected actual
    case "$ARTIFACT_BASE_URL" in
        *"/OWNER/"*) die "尚未配置二进制 Release 地址。请设置 MOSDNS_DOH_ARTIFACT_BASE_URL，或修改脚本中的发布地址。" ;;
    esac

    workdir="$(mktemp -d)"
    if ! curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
        --connect-timeout 15 --max-time 180 --proto '=https' --tlsv1.2 \
        "$(artifact_url "$asset")" -o "$workdir/$asset"; then
        rm -rf "$workdir"
        die "下载 $asset 失败。"
    fi
    if ! curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
        --connect-timeout 15 --max-time 60 --proto '=https' --tlsv1.2 \
        "$(artifact_url SHA256SUMS)" -o "$workdir/SHA256SUMS"; then
        rm -rf "$workdir"
        die "下载 SHA256SUMS 失败。"
    fi

    expected="$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1; exit }' "$workdir/SHA256SUMS")"
    [ -n "$expected" ] || { rm -rf "$workdir"; die "SHA256SUMS 中没有 $asset。"; }
    actual="$(sha256sum "$workdir/$asset" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || { rm -rf "$workdir"; die "$asset SHA256 校验失败。"; }

    install -o root -g root -m 0755 "$workdir/$asset" "$destination"
    rm -rf "$workdir"
    log "$asset 已下载并通过 SHA256 校验。"
}

mosdns_version_matches() {
    [ -x "$1" ] || return 1
    "$1" version 2>/dev/null | grep -Fxq "$MOSDNS_VERSION"
}

caddy_version_matches() {
    [ -x "$1" ] || return 1
    "$1" version 2>/dev/null | grep -Fq "$CADDY_VERSION"
}

install_binaries() {
    local mosdns_asset="mosdns-linux-${TARGET_ARCH}" caddy_asset="caddy-linux-${TARGET_ARCH}"
    local temp_mosdns temp_caddy

    if mosdns_version_matches "$MOSDNS_BIN"; then
        log "复用已有 $MOSDNS_BIN ($MOSDNS_VERSION)。"
    else
        temp_mosdns="$(mktemp)"
        download_verified "$mosdns_asset" "$temp_mosdns"
        install -o root -g root -m 0755 "$temp_mosdns" "$MOSDNS_BIN"
        rm -f "$temp_mosdns"
    fi

    if caddy_version_matches "$CADDY_BIN"; then
        log "复用已有 $CADDY_BIN ($CADDY_VERSION)。"
    else
        temp_caddy="$(mktemp)"
        download_verified "$caddy_asset" "$temp_caddy"
        install -o root -g root -m 0755 "$temp_caddy" "$CADDY_BIN"
        rm -f "$temp_caddy"
    fi

    "$CADDY_BIN" list-modules 2>/dev/null | grep -Fxq 'dns.providers.cloudflare' \
        || die "Caddy 缺少 dns.providers.cloudflare 模块；请发布带 Cloudflare DNS 模块的构建。"
    mosdns_version_matches "$MOSDNS_BIN" \
        || die "安装后的 mosdns 不是 $MOSDNS_VERSION，拒绝继续。"
}

atomic_install_stdin() {
    local destination=$1 owner=$2 group=$3 mode=$4 temporary
    temporary="$(mktemp "$(dirname "$destination")/.mosdns-doh.XXXXXX")"
    if ! cat >"$temporary"; then
        rm -f "$temporary"
        die "写入 $destination 失败。"
    fi
    chown "$owner:$group" "$temporary"
    chmod "$mode" "$temporary"
    mv -f "$temporary" "$destination"
}

write_mosdns_config() {
    atomic_install_stdin "$MOSDNS_CONFIG" root mosdns 0640 <<'EOF'
log:
  level: info

plugins:
  - tag: ecs_client
    type: ecs_client
    args:
      send: true
      forward: false
      ipv4_mask: 24
      ipv6_mask: 48

  - tag: forward_domestic
    type: forward
    args:
      concurrent: 2
      upstreams:
        - tag: alidns
          addr: https://dns.alidns.com/dns-query
          dial_addr: 223.5.5.5:443
          bootstrap: 223.5.5.5
          insecure_skip_verify: false
        - tag: dohpub
          addr: https://doh.pub/dns-query
          dial_addr: 1.12.12.12:443
          bootstrap: 1.12.12.12
          insecure_skip_verify: false

  - tag: forward_foreign
    type: forward
    args:
      concurrent: 4
      upstreams:
        - tag: cloudflare_1
          addr: https://cloudflare-dns.com/dns-query
          dial_addr: 1.1.1.1:443
          bootstrap: 1.1.1.1
          insecure_skip_verify: false
        - tag: cloudflare_2
          addr: https://cloudflare-dns.com/dns-query
          dial_addr: 1.0.0.1:443
          bootstrap: 1.0.0.1
          insecure_skip_verify: false
        - tag: google_1
          addr: https://dns.google/dns-query
          dial_addr: 8.8.8.8:443
          bootstrap: 8.8.8.8
          insecure_skip_verify: false
        - tag: google_2
          addr: https://dns.google/dns-query
          dial_addr: 8.8.4.4:443
          bootstrap: 8.8.4.4
          insecure_skip_verify: false

  - tag: route
    type: sequence
    args:
      - exec: $ecs_client
      - matches:
          - qname &/var/lib/mosdns/rules/foreign-overrides.txt
        exec: $forward_foreign
      - matches:
          - qname &/var/lib/mosdns/rules/foreign-overrides.txt
        exec: return
      - matches:
          - qname &/var/lib/mosdns/rules/geosite-cn.txt
        exec: $forward_domestic
      - matches:
          - qname &/var/lib/mosdns/rules/geosite-cn.txt
        exec: return
      - matches:
          - qname &/var/lib/mosdns/rules/domestic-extra.txt
        exec: $forward_domestic
      - matches:
          - qname &/var/lib/mosdns/rules/domestic-extra.txt
        exec: return
      - exec: $forward_foreign

  - tag: doh_server
    type: http_server
    args:
      listen: 127.0.0.1:8053
      src_ip_header: X-Forwarded-For
      idle_timeout: 30
      entries:
        - exec: route
          path: /dns-query
EOF
}

write_cloudflare_env() {
    local temporary
    temporary="$(mktemp /etc/caddy/.cloudflare.env.XXXXXX)"
    printf 'CLOUDFLARE_API_TOKEN=%s\n' "$CF_TOKEN" >"$temporary"
    chown root:root "$temporary"
    chmod 0600 "$temporary"
    mv -f "$temporary" "$CADDY_ENV"
}

write_caddy_config() {
    atomic_install_stdin "$CADDY_CONFIG" root root 0644 <<EOF
{
    auto_https disable_redirects
}

${DOH_DOMAIN}:${DOH_PORT} {
    bind ::

    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }

    @doh path /dns-query
    handle @doh {
        reverse_proxy 127.0.0.1:8053 {
            header_up X-Forwarded-For {http.request.remote.host}
        }
    }

    handle {
        respond 404
    }
}
EOF
}

write_rule_sync_script() {
    atomic_install_stdin "$MOSDNS_RULE_SYNC" root root 0755 <<'SCRIPT'
#!/bin/sh
set -eu

RULE_DIR=/var/lib/mosdns/rules
WORK_DIR="$RULE_DIR/.sync.$$"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$WORK_DIR"

fetch() {
    url=$1
    output=$2
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
        --connect-timeout 15 --max-time 120 --proto '=https' --tlsv1.2 \
        "$url" -o "$output"
    test -s "$output"
}

parse_rules() {
    input=$1
    output=$2
    awk '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function unquote(s) {
            if (length(s) >= 2) {
                first = substr(s, 1, 1)
                last = substr(s, length(s), 1)
                if ((first == "\047" && last == "\047") || (first == "\042" && last == "\042"))
                    s = substr(s, 2, length(s) - 2)
            }
            return trim(s)
        }
        function wildcard_regexp(s, out, i, c) {
            out = "^"
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "*") out = out ".*"
                else if (c == "?") out = out "."
                else if (index("\\.^$|()+{}[]", c) > 0) out = out "\\" c
                else out = out c
            }
            return out "$"
        }
        function emit(kind, value) {
            value = unquote(value)
            if (value == "" || value == ".") return
            sub(/^[+][.]/, "", value)
            if (kind == "domain" || kind == "full" || kind == "keyword") {
                sub(/^[.]/, "", value)
                value = tolower(value)
                if (value != "") print kind ":" value
            } else if (kind == "regexp") {
                value = tolower(value)
                if (value != "") print "regexp:" value
            }
        }
        {
            line = $0
            sub(/\r$/, "", line)
            sub(/[[:space:]]+#.*/, "", line)
            line = trim(line)
            if (line == "" || line ~ /^#/) next

            if (line ~ /^-[[:space:]]+/) sub(/^-[[:space:]]+/, "", line)
            line = unquote(line)

            upper = toupper(line)
            if (upper ~ /^DOMAIN-SUFFIX,/) {
                emit("domain", substr(line, index(line, ",") + 1))
                next
            }
            if (upper ~ /^DOMAIN-WILDCARD,/) {
                value = substr(line, index(line, ",") + 1)
                value = unquote(value)
                sub(/^[+.]+/, "", value)
                print "regexp:" wildcard_regexp(tolower(value))
                next
            }
            if (upper ~ /^DOMAIN-KEYWORD,/) {
                emit("keyword", substr(line, index(line, ",") + 1))
                next
            }
            if (upper ~ /^DOMAIN,/) {
                emit("full", substr(line, index(line, ",") + 1))
                next
            }

            colon = index(line, ":")
            if (colon > 1) {
                kind = tolower(substr(line, 1, colon - 1))
                if (kind == "domain" || kind == "full" || kind == "keyword" || kind == "regexp") {
                    emit(kind, substr(line, colon + 1))
                    next
                }
            }

            if (line !~ /[[:space:]]/ && line !~ /:/ && line ~ /^[A-Za-z0-9*?._+\-]+$/) {
                if (line ~ /[*?]/) {
                    sub(/^[+.]+/, "", line)
                    print "regexp:" wildcard_regexp(tolower(line))
                } else {
                    emit("domain", line)
                }
            }
        }
    ' "$input" | LC_ALL=C sort -u > "$output"
    test -s "$output"
}

fetch 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.list' "$WORK_DIR/geosite-cn.source"
parse_rules "$WORK_DIR/geosite-cn.source" "$WORK_DIR/geosite-cn.txt"

fetch 'https://cdn.jsdelivr.net/gh/Accademia/Additional_Rule_For_Clash@latest/GeositeCN/GeositeCN_Domain.yaml' "$WORK_DIR/domestic-extra-1.source"
fetch 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Cloudflarecn/Cloudflarecn.yaml' "$WORK_DIR/domestic-extra-2.source"
fetch 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/AmazonCN/AmazonCN.yaml' "$WORK_DIR/domestic-extra-3.source"

for source in "$WORK_DIR"/domestic-extra-*.source; do
    parse_rules "$source" "$source.parsed"
done
cat "$WORK_DIR"/domestic-extra-*.parsed | LC_ALL=C sort -u > "$WORK_DIR/domestic-extra.txt"
test -s "$WORK_DIR/domestic-extra.txt"

for name in geosite-cn domestic-extra; do
    install -o mosdns -g mosdns -m 0644 "$WORK_DIR/$name.txt" "$RULE_DIR/$name.txt.new"
    mv -f "$RULE_DIR/$name.txt.new" "$RULE_DIR/$name.txt"
done
SCRIPT
}

write_units() {
    atomic_install_stdin /etc/systemd/system/mosdns.service root root 0644 <<'EOF'
[Unit]
Description=Generic mosdns IPv6 DoH backend
Wants=network-online.target
After=network-online.target
ConditionPathExists=/usr/local/bin/mosdns
ConditionPathExists=/etc/mosdns/config.yaml
ConditionPathExists=/var/lib/mosdns/rules/geosite-cn.txt
ConditionPathExists=/var/lib/mosdns/rules/domestic-extra.txt
ConditionPathExists=/var/lib/mosdns/rules/foreign-overrides.txt

[Service]
Type=simple
User=mosdns
Group=mosdns
ExecStart=/usr/local/bin/mosdns start -c /etc/mosdns/config.yaml
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ReadWritePaths=/var/lib/mosdns
MemoryDenyWriteExecute=true
LockPersonality=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
LimitNOFILE=65536
UMask=0022

[Install]
WantedBy=multi-user.target
EOF

    atomic_install_stdin /etc/systemd/system/caddy.service root root 0644 <<'EOF'
[Unit]
Description=Caddy IPv6-only DoH frontend
Documentation=https://caddyserver.com/docs/
Wants=network-online.target
After=network-online.target mosdns.service
Requires=mosdns.service
ConditionPathExists=/usr/local/bin/caddy
ConditionPathExists=/etc/caddy/Caddyfile
ConditionPathExists=/etc/caddy/cloudflare.env

[Service]
Type=notify
User=caddy
Group=caddy
EnvironmentFile=/etc/caddy/cloudflare.env
ExecStartPre=/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
ExecStop=/bin/kill -SIGTERM $MAINPID
Restart=on-failure
RestartSec=5s
TimeoutStopSec=5s
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ReadWritePaths=/var/lib/caddy /var/log/caddy
StateDirectory=caddy
LogsDirectory=caddy
MemoryDenyWriteExecute=true
LockPersonality=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
LimitNOFILE=65536
UMask=0022

[Install]
WantedBy=multi-user.target
EOF

    atomic_install_stdin /etc/systemd/system/mosdns-rules.service root root 0644 <<'EOF'
[Unit]
Description=Download and normalize mosdns domain rules
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mosdns-sync-rules
ExecStartPost=/bin/systemctl try-restart mosdns.service
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ReadWritePaths=/var/lib/mosdns
MemoryDenyWriteExecute=true
LockPersonality=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
CapabilityBoundingSet=CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER
AmbientCapabilities=
UMask=0022
EOF

    atomic_install_stdin /etc/systemd/system/mosdns-rules.timer root root 0644 <<'EOF'
[Unit]
Description=Periodic mosdns domain rule refresh

[Timer]
OnBootSec=15min
OnUnitActiveSec=24h
RandomizedDelaySec=15min
Persistent=true
Unit=mosdns-rules.service

[Install]
WantedBy=timers.target
EOF
}

write_local_override_file() {
    if [ ! -e "$MOSDNS_RULE_DIR/foreign-overrides.txt" ]; then
        atomic_install_stdin "$MOSDNS_RULE_DIR/foreign-overrides.txt" root mosdns 0644 <<'EOF'
# Local overrides. One domain rule per line.
# Use domain:example.com for a domain and its subdomains.
# Use full:example.com for an exact match.
EOF
    else
        chown root:mosdns "$MOSDNS_RULE_DIR/foreign-overrides.txt"
        chmod 0644 "$MOSDNS_RULE_DIR/foreign-overrides.txt"
    fi
}

refresh_rules_initially() {
    log "下载并生成当前规则。"
    "$MOSDNS_RULE_SYNC"
}

validate_caddy_config() {
    log "校验 Caddy 配置。"
    CLOUDFLARE_API_TOKEN="$CF_TOKEN" "$CADDY_BIN" validate \
        --config "$CADDY_CONFIG" --adapter caddyfile
}

start_services() {
    log "重新加载 systemd 单元并启动服务。"
    systemctl daemon-reload
    systemctl enable mosdns.service caddy.service mosdns-rules.timer
    systemctl restart mosdns.service
    systemctl restart caddy.service
    systemctl start mosdns-rules.timer

    systemctl is-active --quiet mosdns.service || {
        systemctl --no-pager --full status mosdns.service || true
        die "mosdns.service 启动失败。"
    }
    systemctl is-active --quiet caddy.service || {
        systemctl --no-pager --full status caddy.service || true
        die "caddy.service 启动失败。"
    }
}

open_firewall_if_requested() {
    [ "$OPEN_FIREWALL" = "yes" ] || return 0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "${DOH_PORT}/tcp" comment 'mosdns DoH'
        log "已通过 UFW 放行 TCP ${DOH_PORT}。"
    else
        warn "未自动修改防火墙。请在云安全组/iptables/nftables 中放行 TCP ${DOH_PORT}。"
    fi
}

print_success() {
    printf '\n部署完成。\n'
    printf 'DoH 地址： https://%s:%s/dns-query\n' "$DOH_DOMAIN" "$DOH_PORT"
    printf '检查命令： %s check\n' "$0"
    printf '规则更新： %s update-rules\n' "$0"
    printf '证书/Caddy：%s renew\n' "$0"
    if [ -n "$BACKUP_DIR" ]; then
        printf '旧配置备份：%s\n' "$BACKUP_DIR"
    fi
}

install_flow() {
    require_root
    require_supported_system
    prompt_install_inputs
    prepare_backup
    install_dependencies
    configure_cloudflare_dns
    ensure_service_user
    install_binaries
    write_local_override_file
    write_rule_sync_script
    refresh_rules_initially
    write_mosdns_config
    write_cloudflare_env
    write_caddy_config
    write_units
    validate_caddy_config
    start_services
    open_firewall_if_requested
    print_success
}

check_flow() {
    require_root
    [ -x "$MOSDNS_BIN" ] || die "未安装 mosdns。"
    [ -x "$CADDY_BIN" ] || die "未安装 Caddy。"
    [ -f "$MOSDNS_CONFIG" ] || die "缺少 $MOSDNS_CONFIG。"
    [ -f "$CADDY_CONFIG" ] || die "缺少 $CADDY_CONFIG。"
    mosdns_version_matches "$MOSDNS_BIN" || die "mosdns 版本不是 $MOSDNS_VERSION。"
    "$CADDY_BIN" list-modules 2>/dev/null | grep -Fxq 'dns.providers.cloudflare' \
        || die "Caddy 缺少 dns.providers.cloudflare 模块。"
    systemctl is-active --quiet mosdns.service || die "mosdns.service 未运行。"
    systemctl is-active --quiet caddy.service || die "caddy.service 未运行。"
    [ -s "$MOSDNS_RULE_DIR/geosite-cn.txt" ] || die "国内规则不存在或为空。"
    [ -s "$MOSDNS_RULE_DIR/domestic-extra.txt" ] || die "国内扩展规则不存在或为空。"
    [ -e "$MOSDNS_RULE_DIR/foreign-overrides.txt" ] || die "foreign-overrides.txt 不存在。"
    ss -lnt 2>/dev/null | grep -Eq "(^|[[:space:]])127\.0\.0\.1:8053[[:space:]]|\*:8053[[:space:]]" \
        || die "mosdns 没有监听 8053。"
    log "mosdns/Caddy/规则状态正常。"
}

update_rules_flow() {
    require_root
    [ -x "$MOSDNS_RULE_SYNC" ] || die "未安装规则同步器。"
    systemctl start mosdns-rules.service
    systemctl is-active --quiet mosdns.service || die "规则更新后 mosdns 未运行。"
    log "规则更新完成。"
}

renew_flow() {
    require_root
    systemctl reload caddy.service
    log "Caddy 已重新加载；证书由 Caddy 自动管理。"
}

usage() {
    cat <<'EOF'
用法：
  install.sh                 交互式安装/更新 mosdns + Caddy DoH
  install.sh check           检查服务、规则、监听端口和 Caddy 模块
  install.sh update-rules    立即更新规则并重启 mosdns
  install.sh renew           重新加载 Caddy 以应用证书/配置

非交互安装变量：
  DOH_DOMAIN=... CLOUDFLARE_API_TOKEN=... MOSDNS_DOH_IP_MODE=dual \
  MOSDNS_DOH_OPEN_FIREWALL=yes MOSDNS_DOH_OVERWRITE=yes \
  install.sh install

发布者变量：
  MOSDNS_DOH_ARTIFACT_BASE_URL=https://github.com/EchoLunar/mosdns-doh/releases/download/v5.3.4-client-ecs
EOF
}

main() {
    local command="${1:-install}"
    case "$command" in
        install) install_flow ;;
        check) check_flow ;;
        update-rules) update_rules_flow ;;
        renew) renew_flow ;;
        -h|--help|help) usage ;;
        *) usage; die "未知命令：$command" ;;
    esac
}

main "$@"
