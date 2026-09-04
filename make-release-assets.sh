#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly MOSDNS_VERSION="${MOSDNS_VERSION:-v5.3.4-client-ecs}"
readonly CADDY_VERSION="${CADDY_VERSION:-v2.11.4}"

SOURCE_MOSDNS="${SOURCE_MOSDNS:-/usr/local/bin/mosdns}"
SOURCE_CADDY="${SOURCE_CADDY:-/usr/local/bin/caddy}"
OUTPUT_DIR="${OUTPUT_DIR:-./release-assets}"
TARGET_ARCH=""

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
用法：
  make-release-assets.sh [选项]

选项：
  --arch ARCH       amd64 或 arm64，默认按当前系统检测
  --mosdns PATH     自定义 mosdns 二进制，默认 /usr/local/bin/mosdns
  --caddy PATH      带 Cloudflare 模块的 Caddy，默认 /usr/local/bin/caddy
  --output DIR      输出目录，默认 ./release-assets
  -h, --help        显示帮助

输出资产：
  mosdns-linux-ARCH
  caddy-linux-ARCH
  SHA256SUMS
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --arch)
            [ "$#" -ge 2 ] || die "--arch 缺少参数。"
            TARGET_ARCH=$2
            shift 2
            ;;
        --mosdns)
            [ "$#" -ge 2 ] || die "--mosdns 缺少参数。"
            SOURCE_MOSDNS=$2
            shift 2
            ;;
        --caddy)
            [ "$#" -ge 2 ] || die "--caddy 缺少参数。"
            SOURCE_CADDY=$2
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || die "--output 缺少参数。"
            OUTPUT_DIR=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "未知参数：$1"
            ;;
    esac
done

if [ -z "$TARGET_ARCH" ]; then
    case "$(uname -m)" in
        x86_64|amd64) TARGET_ARCH=amd64 ;;
        aarch64|arm64) TARGET_ARCH=arm64 ;;
        *) die "不支持的当前架构：$(uname -m)。" ;;
    esac
fi

case "$TARGET_ARCH" in
    amd64|arm64) ;;
    *) die "架构必须是 amd64 或 arm64。" ;;
esac

[ -x "$SOURCE_MOSDNS" ] || die "mosdns 不存在或不可执行：$SOURCE_MOSDNS"
[ -x "$SOURCE_CADDY" ] || die "Caddy 不存在或不可执行：$SOURCE_CADDY"

"$SOURCE_MOSDNS" version 2>/dev/null | grep -Fxq "$MOSDNS_VERSION" \
    || die "mosdns 版本不是 $MOSDNS_VERSION。"
"$SOURCE_CADDY" version 2>/dev/null | grep -Fq "$CADDY_VERSION" \
    || die "Caddy 版本不是 $CADDY_VERSION。"
"$SOURCE_CADDY" list-modules 2>/dev/null | grep -Fxq 'dns.providers.cloudflare' \
    || die "Caddy 缺少 dns.providers.cloudflare 模块。"

mkdir -p "$OUTPUT_DIR"
install -o root -g root -m 0755 "$SOURCE_MOSDNS" "$OUTPUT_DIR/mosdns-linux-$TARGET_ARCH"
install -o root -g root -m 0755 "$SOURCE_CADDY" "$OUTPUT_DIR/caddy-linux-$TARGET_ARCH"

asset_paths=()
for asset_path in "$OUTPUT_DIR"/mosdns-linux-* "$OUTPUT_DIR"/caddy-linux-*; do
    [ -f "$asset_path" ] || continue
    asset_paths+=("$(basename "$asset_path")")
done

(
    cd "$OUTPUT_DIR"
    sha256sum "${asset_paths[@]}" | sort -k2 > SHA256SUMS
)

printf '已生成 %s 架构 Release 资产：%s\n' "$TARGET_ARCH" "$OUTPUT_DIR"
