#!/bin/sh
# ==========================================================
#  cf-vless 一键安装脚本
#  协议: VLESS + WebSocket + TLS(Cloudflare Origin 证书) + Cloudflare CDN
#
#  会生成两条链接:
#    链路A 直连    vless://...@域名:443  出口 = 本机 IP（最快）
#    链路B 套 CF 出口 vless://...@域名:8443 出口 = Cloudflare WARP 的 IP
#  链路B 用一个机房内 WireGuard 出口实现，没有额外守护进程，
#  随 sing-box 一起自启；它挂掉不会影响链路A。
#
#  支持: Debian / Ubuntu / Alpine / CentOS / Rocky / SUSE 的 LXC 与 VPS
#  依赖: curl 或 wget、tar、openssl（其它一律不装，无第三方脚本）
#  二进制: 固定版本，从本仓库 bin/ 目录取，不在安装时访问第三方源。
#          官方无后缀包是 glibc 动态链接版，Alpine(musl) 需要 -musl 后缀的包；
#          脚本发现跑不起来会自动改用 -musl，仓库里没有就用 gcompat 兜底。
#
#  一键执行:
#    wget -q -O - https://raw.githubusercontent.com/spverk/huangkingking/main/install.sh | sh -s -- --pass 口令
#
#  参数:
#    --pass <口令>         必填，解密仓库里加密的 config.conf 与 CF 证书
#    --domain <域名>       覆盖 config.conf 中的 DOMAIN
#    --port <端口>         覆盖 config.conf 中的 LISTEN_PORT
#    --public-port <端口>  覆盖 config.conf 中的 PUBLIC_PORT
#    --warp-port <端口>    覆盖 config.conf 中的 WARP_PUBLIC_PORT（链路B 对外端口）
#    --uuid <uuid>         覆盖 config.conf 中的 UUID
#    --path </路径>        覆盖 config.conf 中的 WS_PATH
#    --core-version <版本> 指定 sing-box 版本（须已放在仓库 bin/ 里），默认 1.14.3
#    --repo <raw 地址>     指定仓库 raw 地址
#    --no-firewall         不修改防火墙
#    --no-warp             不装链路B（只保留直连）
#    --url                 只打印已保存的链接并退出
#    --uninstall           卸载
#    -h, --help            显示帮助
# ==========================================================

VERSION="1.1"
set -u

# ----------------------------------------------------------
# 默认值（会被仓库里的 config.conf 覆盖，再被命令行参数覆盖）
# ----------------------------------------------------------
DOMAIN=""
LISTEN_PORT="443"
PUBLIC_PORT="443"
UUID=""
WS_PATH=""
CORE_VERSION=""
FALLBACK_CORE_VERSION="1.14.3"
FIREWALL="1"
FIREWALL_PORTS="80 8080 8880 2052 2082 2086 2095 443 2053 2083 2087 2096 8443"
# 出网域名解析策略：prefer_ipv6 = 优先 IPv6，没有再回落 IPv4
DNS_STRATEGY="prefer_ipv6"
REPO_RAW="https://raw.githubusercontent.com/spverk/huangkingking/main"

# 链路B（套 Cloudflare 出口 = WARP）
ENABLE_WARP="1"
WARP_PORT="8443"
WARP_PUBLIC_PORT="8443"
WARP_MTU="1280"
WARP_ENDPOINT="engage.cloudflareclient.com:2408"

# 目录
SB_DIR="/etc/sing-box"
SB_BIN="$SB_DIR/bin/sing-box"
SB_CONF_DIR="$SB_DIR/conf"
SB_CONF="$SB_CONF_DIR/vless-ws-tls.json"
SB_CER="$SB_DIR/bin/tls.cer"
SB_KEY="$SB_DIR/bin/tls.key"
SB_URL_DIR="$SB_DIR/url"
SB_FW="$SB_DIR/firewall.sh"
SB_CTL="/usr/local/bin/sbctl"
SB_LOG_DIR="/var/log/sing-box"
LOG_FILE="$SB_LOG_DIR/install.log"

# 运行时状态
TMP_DIR=""
PKG=""
INIT=""
ARCH=""
HTTP=""
IPV6="0"
LISTEN=""
WARP_ON="0"

# 命令行传入的覆盖值（在读取 config.conf 之后再合并，保证命令行优先）
A_PASS=""
A_DOMAIN=""
A_PORT=""
A_PUBLIC_PORT=""
A_WARP_PORT=""
A_UUID=""
A_PATH=""
A_CORE_VERSION=""

# ----------------------------------------------------------
# 基础输出
# ----------------------------------------------------------
_red() { printf '\033[31m%s\033[0m\n' "$*"; }
_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
_ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
_cyn() { printf '\033[36m%s\033[0m\n' "$*"; }
say() { printf '%s\n' "$*"; }
ok() { _grn "[OK] $*"; }
warn() { _ylw "[!] $*"; }
die() {
    _red "[错误] $*"
    exit 1
}

cleanup() {
    [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    return 0
}
trap 'cleanup' EXIT
trap 'cleanup; exit 1' INT TERM

usage() {
    cat <<'USAGE_EOF'
cf-vless 一键安装 (VLESS + WebSocket + TLS + Cloudflare CDN)

用法:
  wget -q -O - <仓库 raw 地址>/install.sh | sh -s -- --pass 口令

参数:
  --pass <口令>         必填，解密仓库里加密的 config.conf 与 CF 证书
  --domain <域名>       覆盖 config.conf 中的 DOMAIN
  --port <端口>         覆盖 config.conf 中的 LISTEN_PORT
  --public-port <端口>  覆盖 config.conf 中的 PUBLIC_PORT
  --warp-port <端口>    覆盖 config.conf 中的 WARP_PUBLIC_PORT（链路B 对外端口）
  --uuid <uuid>         覆盖 config.conf 中的 UUID
  --path </路径>        覆盖 config.conf 中的 WS_PATH
  --core-version <版本> 指定 sing-box 版本（须已放在仓库 bin/ 里），默认 1.14.3
  --repo <raw 地址>     指定仓库 raw 地址
  --no-firewall         不修改防火墙
  --no-warp             不装链路B（只保留直连那条）
  --url                 只打印已保存的链接并退出
  --uninstall           卸载
  -h, --help            显示本帮助
USAGE_EOF
}

# ----------------------------------------------------------
# 参数解析
# ----------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
    --pass)
        [ $# -ge 2 ] || die "--pass 缺少值"
        A_PASS="$2"
        shift 2
        ;;
    --domain)
        [ $# -ge 2 ] || die "--domain 缺少值"
        A_DOMAIN="$2"
        shift 2
        ;;
    --port)
        [ $# -ge 2 ] || die "--port 缺少值"
        A_PORT="$2"
        shift 2
        ;;
    --public-port)
        [ $# -ge 2 ] || die "--public-port 缺少值"
        A_PUBLIC_PORT="$2"
        shift 2
        ;;
    --warp-port)
        [ $# -ge 2 ] || die "--warp-port 缺少值"
        A_WARP_PORT="$2"
        shift 2
        ;;
    --uuid)
        [ $# -ge 2 ] || die "--uuid 缺少值"
        A_UUID="$2"
        shift 2
        ;;
    --path)
        [ $# -ge 2 ] || die "--path 缺少值"
        A_PATH="$2"
        shift 2
        ;;
    --core-version)
        [ $# -ge 2 ] || die "--core-version 缺少值"
        A_CORE_VERSION="$2"
        shift 2
        ;;
    --repo)
        [ $# -ge 2 ] || die "--repo 缺少值"
        REPO_RAW="$2"
        shift 2
        ;;
    --no-firewall)
        FIREWALL="0"
        shift
        ;;
    --no-warp)
        ENABLE_WARP="0"
        shift
        ;;
    --url)
        DO_SHOW_URL="1"
        shift
        ;;
    --uninstall)
        DO_UNINSTALL="1"
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        die "未知参数: $1 （用 --help 查看用法）"
        ;;
    esac
done

[ "$(id -u)" = "0" ] || die "请用 root 身份运行本脚本"

# ----------------------------------------------------------
# 只查看链接 / 卸载
# ----------------------------------------------------------
if [ "${DO_SHOW_URL:-}" ]; then
    _n=0
    for f in "$SB_URL_DIR"/*.txt; do
        [ -f "$f" ] || continue
        say "-- $(basename "$f") --"
        cat "$f"
        _n=$((_n + 1))
    done
    [ "$_n" = "0" ] && die "没找到已保存的链接，可能还没安装过"
    exit 0
fi

if [ "${DO_UNINSTALL:-}" ]; then
    say "开始卸载 sing-box ..."
    if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/sing-box.service ]; then
        systemctl stop sing-box >/dev/null 2>&1
        systemctl disable sing-box >/dev/null 2>&1
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload >/dev/null 2>&1
    fi
    if [ -f /etc/init.d/sing-box ]; then
        rc-service sing-box stop >/dev/null 2>&1
        rc-update del sing-box default >/dev/null 2>&1
        rm -f /etc/init.d/sing-box
    fi
    pkill -f "$SB_BIN" >/dev/null 2>&1
    rm -rf "$SB_DIR" "$SB_CTL"
    rm -f /root/vless-url.txt /root/vless-url-warp.txt
    say "已删除 $SB_DIR 与服务，链接和配置（含 WARP）一起清掉了。"
    say "注: 如果之前在 /etc/rc.local 里写过启动项，需要你自己删掉那一行。"
    exit 0
fi

# ----------------------------------------------------------
# 1. 环境探测
# ----------------------------------------------------------
say ""
_cyn "== cf-vless v$VERSION =="
say ""

for p in apt-get dnf yum zypper apk; do
    if command -v "$p" >/dev/null 2>&1; then
        PKG="$p"
        break
    fi
done
[ "$PKG" ] || die "没找到包管理器 (apt-get/dnf/yum/zypper/apk)，无法继续"

if command -v systemctl >/dev/null 2>&1; then
    INIT="systemd"
elif command -v rc-service >/dev/null 2>&1; then
    INIT="openrc"
else
    INIT="none"
fi

case "$(uname -m)" in
x86_64 | amd64) ARCH="amd64" ;;
aarch64 | armv8* | arm64) ARCH="arm64" ;;
*) die "只支持 64 位系统 (amd64 / arm64)，当前是 $(uname -m)" ;;
esac

if [ -f /proc/net/if_inet6 ]; then
    IPV6="1"
    LISTEN="::"
else
    LISTEN="0.0.0.0"
fi

if grep -qi 'container=lxc' /proc/1/environ 2>/dev/null; then
    ENV_TYPE="LXC 容器"
else
    ENV_TYPE="普通主机"
fi

say "系统     : $(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '\"')"
say "包管理器 : $PKG"
say "init     : $INIT"
say "架构     : $ARCH"
say "IPv6     : $([ "$IPV6" = "1" ] && echo 有 || echo 无)"
say "环境     : $ENV_TYPE"
say ""

# ----------------------------------------------------------
# 2. 依赖
# ----------------------------------------------------------
pkg_add() {
    say "安装依赖: $*"
    case "$PKG" in
    apk)
        apk update >/dev/null 2>&1
        apk add "$@" >/dev/null 2>&1
        ;;
    apt-get)
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1 ||
            {
                apt-get update >/dev/null 2>&1
                DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1
            }
        ;;
    dnf) dnf install -y "$@" >/dev/null 2>&1 ;;
    yum) yum install -y "$@" >/dev/null 2>&1 ;;
    zypper) zypper --non-interactive install "$@" >/dev/null 2>&1 ;;
    esac
}

for c in curl wget; do
    if command -v "$c" >/dev/null 2>&1; then
        HTTP="$c"
        break
    fi
done
if [ "$HTTP" = "" ]; then
    pkg_add curl
    command -v curl >/dev/null 2>&1 && HTTP="curl"
fi
[ "$HTTP" = "" ] && die "缺少 curl/wget，请手动安装: $PKG install curl"

if ! command -v openssl >/dev/null 2>&1; then
    pkg_add openssl
fi
command -v openssl >/dev/null 2>&1 || die "缺少 openssl，请手动安装: $PKG install openssl"

MISSING=""
for c in tar; do
    command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
done
if [ "$MISSING" ]; then
    pkg_add $MISSING
fi
command -v tar >/dev/null 2>&1 || die "缺少 tar，请手动安装: $PKG install tar"

# 下载: dl <url> <输出文件>
dl() {
    case "$HTTP" in
    curl) curl -fsSL --connect-timeout 20 --retry 2 -o "$2" "$1" ;;
    wget) wget -q -T 20 -t 2 -O "$2" "$1" ;;
    esac
}
# 仓库里的敏感文件（config.conf、证书、私钥）都是加密存放的，统一用这个口令解
decrypt() {
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -base64 -in "$1" -out "$2" -pass "pass:$PASS" >/dev/null 2>&1
}
encrypt() {
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -base64 -in "$1" -out "$2" -pass "pass:$PASS" >/dev/null 2>&1
}

TMP_DIR="$(mktemp -d)" || die "无法创建临时目录"
mkdir -p "$SB_DIR/bin" "$SB_CONF_DIR" "$SB_URL_DIR" "$SB_LOG_DIR"
umask 077

# ----------------------------------------------------------
# 3. 拉取并解密 config.conf
#    仓库里放的是加密后的 config.conf.enc，这样公开仓库里
#    看不到域名 / UUID / WS 路径，别人也就拼不出能用的链接。
# ----------------------------------------------------------
say "读取仓库配置 ..."
[ -n "${A_PASS:-}" ] && PASS="$A_PASS"
[ -n "${PASS:-}" ] || die "缺少口令参数，正确用法: sh install.sh --pass 你的口令"

CONF_URL="$REPO_RAW/config.conf.enc"
dl "$CONF_URL" "$TMP_DIR/config.conf.enc" || die "拉取配置失败: $CONF_URL
（仓库里要有一个 config.conf.enc，是用同口令从 config.conf 加密出来的）"
decrypt "$TMP_DIR/config.conf.enc" "$TMP_DIR/config.conf" ||
    die "配置解密失败：口令不对，或系统 openssl 低于 1.1.1"
rm -f "$TMP_DIR/config.conf.enc"
# 去掉可能的 Windows 换行符，否则被 . 引号源进来时会把 \r 带进每个变量值
tr -d '\r' <"$TMP_DIR/config.conf" >"$TMP_DIR/config.lf" || die "处理 config.conf 失败"
mv "$TMP_DIR/config.lf" "$TMP_DIR/config.conf"
grep -q '^DOMAIN=' "$TMP_DIR/config.conf" || die "解密出来的内容不是本项目的 config.conf（口令错？或仓库里放错了文件）"
. "$TMP_DIR/config.conf"

# 命令行优先
[ "$A_PASS" ] && PASS="$A_PASS"
[ "$A_DOMAIN" ] && DOMAIN="$A_DOMAIN"
[ "$A_PORT" ] && LISTEN_PORT="$A_PORT"
[ "$A_PUBLIC_PORT" ] && PUBLIC_PORT="$A_PUBLIC_PORT"
[ "$A_WARP_PORT" ] && WARP_PUBLIC_PORT="$A_WARP_PORT"
[ "$A_UUID" ] && UUID="$A_UUID"
[ "$A_PATH" ] && WS_PATH="$A_PATH"
[ "$A_CORE_VERSION" ] && CORE_VERSION="$A_CORE_VERSION"

[ -n "${DOMAIN:-}" ] || die "config.conf 里没有填 DOMAIN"

if [ -z "${UUID:-}" ]; then
    UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
    [ "$UUID" ] || UUID="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')"
fi
if [ -z "${WS_PATH:-}" ]; then
    WS_PATH="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)"
fi
case "$WS_PATH" in /*) ;; *) WS_PATH="/$WS_PATH" ;; esac

[ -n "${WARP_PORT:-}" ] || WARP_PORT="8443"
[ -n "${WARP_PUBLIC_PORT:-}" ] || WARP_PUBLIC_PORT="$WARP_PORT"
[ -n "${WARP_MTU:-}" ] || WARP_MTU="1280"
[ -n "${WARP_ENDPOINT:-}" ] || WARP_ENDPOINT="engage.cloudflareclient.com:2408"
[ -n "${ENABLE_WARP:-}" ] || ENABLE_WARP="0"

say "域名     : $DOMAIN"
say "链路A    : 本机 $LISTEN_PORT  <- NAT 对外 $PUBLIC_PORT   (直连)"
if [ "$ENABLE_WARP" = "1" ]; then
    say "链路B    : 本机 $WARP_PORT  <- NAT 对外 $WARP_PUBLIC_PORT   (出口走 Cloudflare WARP)"
else
    say "链路B    : 未启用"
fi
say "WS 路径  : $WS_PATH"
say ""

# ----------------------------------------------------------
# 4. 证书解密
# ----------------------------------------------------------
say "解密 Cloudflare 证书 ..."
dl "$REPO_RAW/secret/tls.cer.enc" "$TMP_DIR/tls.cer.enc" || die "拉取 secret/tls.cer.enc 失败"
dl "$REPO_RAW/secret/tls.key.enc" "$TMP_DIR/tls.key.enc" || die "拉取 secret/tls.key.enc 失败"

decrypt "$TMP_DIR/tls.cer.enc" "$TMP_DIR/tls.cer" ||
    die "证书解密失败：口令不对，或系统 openssl 版本低于 1.1.1"
decrypt "$TMP_DIR/tls.key.enc" "$TMP_DIR/tls.key" || die "私钥解密失败：口令不对"

grep -q 'BEGIN CERTIFICATE' "$TMP_DIR/tls.cer" || die "解密出来的证书不是 PEM 格式"
grep -q 'BEGIN.*PRIVATE KEY' "$TMP_DIR/tls.key" || die "解密出来的私钥不是 PEM 格式"

M1="$(openssl x509 -noout -modulus -in "$TMP_DIR/tls.cer" 2>/dev/null | openssl md5 2>/dev/null)"
M2="$(openssl rsa -noout -modulus -in "$TMP_DIR/tls.key" 2>/dev/null | openssl md5 2>/dev/null)"
if [ -n "$M1" ] && [ -n "$M2" ] && [ "$M1" != "$M2" ]; then
    die "证书与私钥不匹配，请检查仓库里的两个 .enc 文件"
fi

cp "$TMP_DIR/tls.cer" "$SB_CER"
cp "$TMP_DIR/tls.key" "$SB_KEY"
chmod 600 "$SB_CER" "$SB_KEY"
rm -f "$TMP_DIR"/tls.cer "$TMP_DIR"/tls.key "$TMP_DIR"/tls.cer.enc "$TMP_DIR"/tls.key.enc
ok "证书已写入 $SB_CER / $SB_KEY (权限 600)"

WILD="*.${DOMAIN#*.}"
SAN="$(openssl x509 -noout -text -in "$SB_CER" 2>/dev/null | tr ',' '\n' | tr -d ' ')"
case "$SAN" in
*"$DOMAIN"*) ;;
*"$WILD"*) ;;
*) warn "证书的 SAN 里没有 $DOMAIN（也没有 $WILD），请确认这张 CF 证书是否覆盖该域名" ;;
esac

# ----------------------------------------------------------
# 5. 下载 sing-box core（固定版本，只从本仓库取，不碰第三方）
# ----------------------------------------------------------
[ -n "${CORE_VERSION:-}" ] || CORE_VERSION="$FALLBACK_CORE_VERSION"
case "$CORE_VERSION" in v*) ;; *) CORE_VERSION="v$CORE_VERSION" ;; esac
VER_NUM="${CORE_VERSION#v}"
SB_VER="$CORE_VERSION"

install_core() {   # $1 版本号   $2 文件名后缀（空 或 -musl 之类）
    _num="$1"
    _sfx="${2:-}"
    _url="$REPO_RAW/bin/sing-box-$_num-linux-$ARCH$_sfx.tar.gz"
    say "下载 sing-box $_num ($ARCH$_sfx) > $_url"
    dl "$_url" "$TMP_DIR/core.tar.gz" || return 1
    rm -rf "$TMP_DIR/core"
    mkdir -p "$TMP_DIR/core"
    tar -xzf "$TMP_DIR/core.tar.gz" -C "$TMP_DIR/core" 2>/dev/null || return 1
    _file="$(find "$TMP_DIR/core" -type f -name sing-box | head -n1)"
    [ -n "$_file" ] || return 1
    cp "$_file" "$SB_BIN"
    chmod 755 "$SB_BIN"
    # 官方包里 libcronet.so 是和二进制放在一起的（naive 出站运行时加载它），
    # 一起拷过去，免得以后加 naive 出站时找不到库。
    _so="$(find "$TMP_DIR/core" -type f -name 'libcronet.so' | head -n1)"
    if [ -n "$_so" ]; then
        cp "$_so" "$SB_DIR/bin/libcronet.so"
        chmod 644 "$SB_DIR/bin/libcronet.so"
    fi
    return 0
}

_core_ok() { "$SB_BIN" version >/dev/null 2>&1; }

install_core "$VER_NUM" "" || die "从本仓库取 sing-box 失败: $REPO_RAW/bin/sing-box-$VER_NUM-linux-$ARCH.tar.gz
请确认仓库 bin/ 目录里已经放好对应架构的 tar.gz（amd64 / arm64），
或者用 --core-version 指定别的已上传版本。"

# 官方的无后缀包是 glibc 动态链接版本，Alpine(musl) 上跑不起来 -> 先自动换 -musl 包
if ! _core_ok && [ "$PKG" = "apk" ]; then
    warn "这个二进制是 glibc 版本，Alpine(musl) 上跑不起来，改试 musl 版本"
    if install_core "$VER_NUM" "-musl" && _core_ok; then
        ok "已改用 musl 版本"
    fi
fi
# 仓库里没有 musl 包时的兜底：用 gcompat 让 glibc 二进制跑起来
if ! _core_ok && [ "$PKG" = "apk" ]; then
    warn "尝试安装 gcompat（兼容 glibc 二进制）"
    pkg_add gcompat
fi
if ! _core_ok; then
    _err="$("$SB_BIN" version 2>&1 | head -n2)"
    die "sing-box 无法运行: $_err
可能是系统 glibc 版本过低（例如 CentOS 7），
或者当前是 Alpine(musl)，需要把 bin/ 里换成 -musl 后缀的包：
  sing-box-$VER_NUM-linux-$ARCH-musl.tar.gz"
fi
ok "core 已就绪: $("$SB_BIN" version | head -n1)"

# ----------------------------------------------------------
# 5b. WARP 出口（链路B：把出口 IP 换成 Cloudflare 的）
# ----------------------------------------------------------
TMP_FRAG_IN="$TMP_DIR/frag_in.json"
TMP_FRAG_EP="$TMP_DIR/frag_ep.json"
TMP_FRAG_RULE="$TMP_DIR/frag_rule.json"
: >"$TMP_FRAG_IN"
: >"$TMP_FRAG_EP"
: >"$TMP_FRAG_RULE"

if [ "$ENABLE_WARP" = "1" ]; then
    _v="${SB_VER#v}"
    _maj="${_v%%.*}"
    _min="${_v#*.}"
    _min="${_min%%.*}"
    if [ "$_maj" -gt 1 ] || { [ "$_maj" -eq 1 ] && [ "$_min" -ge 11 ]; }; then
        WARP_ON="1"
    else
        warn "sing-box $SB_VER 不支持 endpoints（WARP 需要 >= 1.11），本次只装链路A"
    fi
fi

# 注册 WARP 要用 POST，wget 做不了，必须有 curl
if [ "$WARP_ON" = "1" ] && ! command -v curl >/dev/null 2>&1; then
    pkg_add curl
fi
if [ "$WARP_ON" = "1" ] && ! command -v curl >/dev/null 2>&1; then
    warn "没有 curl，无法注册 WARP，本次只装链路A"
    WARP_ON="0"
fi

if [ "$WARP_ON" = "1" ]; then
    say "准备 WARP 出口（链路B）..."
    mkdir -p "$SB_DIR/secret"
    WARP_ENC="$SB_DIR/secret/warp.env.enc"
    WARP_ENVF="$TMP_DIR/warp.env"
    : >"$WARP_ENVF"

    # 装过就复用，不重复注册
    if [ -f "$WARP_ENC" ]; then
        decrypt "$WARP_ENC" "$WARP_ENVF" >/dev/null 2>&1
        grep -q '^WARP_PRIVATE_KEY=' "$WARP_ENVF" 2>/dev/null || : >"$WARP_ENVF"
        # 早期版本存在这里的 reserved 是算错的，会让握手被对端丢弃，统一纠正
        if grep -q '^WARP_RESERVED=' "$WARP_ENVF" 2>/dev/null; then
            sed 's|^WARP_RESERVED=.*|WARP_RESERVED="0, 0, 0"|' "$WARP_ENVF" >"$WARP_ENVF.fix"
            mv "$WARP_ENVF.fix" "$WARP_ENVF"
        fi
        [ -s "$WARP_ENVF" ] && ok "复用上次注册的 WARP 配置"
    fi

    if [ ! -s "$WARP_ENVF" ]; then
        _kp="$("$SB_BIN" generate wg-keypair 2>/dev/null)"
        WARP_PRIVATE_KEY="$(printf '%s\n' "$_kp" | grep -o '[A-Za-z0-9+/]\{43\}=' | head -n1)"
        WARP_PUBLIC_KEY="$(printf '%s\n' "$_kp" | grep -o '[A-Za-z0-9+/]\{43\}=' | sed -n '2p')"
        if [ -z "$WARP_PRIVATE_KEY" ] || [ -z "$WARP_PUBLIC_KEY" ]; then
            die "生成 WireGuard 密钥失败（$SB_BIN generate wg-keypair）"
        fi

        _tos="$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')"
        _resp=""
        for _api in v0i1909051800 v0a2158; do
            _resp="$(curl -fsSL -X POST "https://api.cloudflareclient.com/$_api/reg" \
                -H "Content-Type: application/json; charset=UTF-8" \
                -H "CF-Client-Version: a-6.10-2158" \
                -H "User-Agent: okhttp/3.12.1" \
                -d "{\"key\":\"$WARP_PUBLIC_KEY\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$_tos\",\"model\":\"PC\",\"serial_number\":\"\"}" 2>/dev/null)"
            printf '%s' "$_resp" | grep -q '"public_key"' && break
            _resp=""
        done
        if ! printf '%s' "$_resp" | grep -q '"public_key"'; then
            die "WARP 注册失败（Cloudflare 注册接口没返回预期内容）。
可先把 config.conf 里的 ENABLE_WARP 改成 0 只装直连链路，回头再折腾链路B。"
        fi

        _addrs="$(printf '%s' "$_resp" | sed -n 's/.*"addresses":{\([^}]*\)}.*/\1/p')"
        WARP_IF4="$(printf '%s' "$_addrs" | sed -n 's/.*"v4":"\([^"]*\)".*/\1/p')"
        WARP_IF6="$(printf '%s' "$_addrs" | sed -n 's/.*"v6":"\([^"]*\)".*/\1/p')"
        WARP_PEER_PUB="$(printf '%s' "$_resp" | grep -o '"public_key":"[^"]*"' | head -n1 | sed 's/.*:"\(.*\)"/\1/')"
        # reserved 固定 0,0,0：Cloudflare 免费 WARP 接受全零。
        # 早先试过从注册返回的 id 字段推算前 3 字节，那个值是错的，
        # 后果是握手包被 Cloudflare 直接丢弃（现象：一直发 handshake initiation、零回应）。
        WARP_RESERVED="0, 0, 0"

        if [ -z "$WARP_IF4" ] || [ -z "$WARP_PEER_PUB" ]; then
            die "WARP 注册返回内容解析失败（Cloudflare 接口格式可能变了）"
        fi

        {
            printf 'WARP_PRIVATE_KEY="%s"\n' "$WARP_PRIVATE_KEY"
            printf 'WARP_IF4="%s"\n' "$WARP_IF4"
            printf 'WARP_IF6="%s"\n' "$WARP_IF6"
            printf 'WARP_PEER_PUB="%s"\n' "$WARP_PEER_PUB"
            printf 'WARP_RESERVED="%s"\n' "$WARP_RESERVED"
        } >"$WARP_ENVF"
        encrypt "$WARP_ENVF" "$WARP_ENC" || die "保存 WARP 配置失败"
        chmod 600 "$WARP_ENC"
        ok "WARP 注册完成（结果存 $WARP_ENC，重装会复用）"
    fi

    . "$WARP_ENVF"

    # 链路B 的入站（注入到 inbounds 里）
    cat >"$TMP_FRAG_IN" <<EOF
,{
      "type": "vless",
      "tag": "vless-warp",
      "listen": "$LISTEN",
      "listen_port": $WARP_PORT,
      "users": [
        {
          "uuid": "$UUID"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$SB_CER",
        "key_path": "$SB_KEY"
      },
      "transport": {
        "type": "ws",
        "path": "$WS_PATH",
        "headers": {
          "host": "$DOMAIN"
        }
      }
    }
EOF

    # 链路B 的出站（WireGuard endpoint，注入到 endpoints 里）
    _ep_host="${WARP_ENDPOINT%:*}"
    _ep_port="${WARP_ENDPOINT##*:}"
    _addr="\"$WARP_IF4/32\""
    if [ -n "$WARP_IF6" ]; then
        _addr="$_addr,
        \"$WARP_IF6/128\""
    fi
    cat >"$TMP_FRAG_EP" <<EOF
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp",
      "mtu": $WARP_MTU,
      "address": [
        $_addr
      ],
      "private_key": "$WARP_PRIVATE_KEY",
      "peers": [
        {
          "address": "$_ep_host",
          "port": $_ep_port,
          "public_key": "$WARP_PEER_PUB",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "persistent_keepalive_interval": 30,
          "reserved": [$WARP_RESERVED]
        }
      ]
    }
  ],
EOF

    # 链路B 的流量交给 warp 出站
    printf '%s\n' '"rules": [{"inbound": ["vless-warp"], "action": "route", "outbound": "warp"}],' >"$TMP_FRAG_RULE"
fi

# ----------------------------------------------------------
# 6. 渲染配置
# ----------------------------------------------------------
dl "$REPO_RAW/conf/vless-ws-tls.json" "$TMP_DIR/vless-ws-tls.json" || die "拉取配置模板失败"

# 把上面准备的片段插到模板占位符的位置。
# 用 awk 而不是 sed，避免多行内容和特殊字符被转义。
inject() {
    awk -v ph="$2" -v src="$3" '
    {
        if (index($0, ph) > 0) {
            while ((getline l < src) > 0) print l
            close(src)
            next
        }
        print
    }' "$1"
}

TMP_CFG="$TMP_DIR/cfg"
inject "$TMP_DIR/vless-ws-tls.json" __INBOUNDS_EXTRA__ "$TMP_FRAG_IN" >"$TMP_CFG.1"
inject "$TMP_CFG.1" __ENDPOINTS_BLOCK__ "$TMP_FRAG_EP" >"$TMP_CFG.2"
inject "$TMP_CFG.2" __RULES_EXTRA__ "$TMP_FRAG_RULE" >"$TMP_CFG.3"

sed -e "s|__LISTEN__|$LISTEN|g" \
    -e "s|__LISTEN_PORT__|$LISTEN_PORT|g" \
    -e "s|__UUID__|$UUID|g" \
    -e "s|__DOMAIN__|$DOMAIN|g" \
    -e "s|__WS_PATH__|$WS_PATH|g" \
    -e "s|__DNS_STRATEGY__|$DNS_STRATEGY|g" \
    "$TMP_CFG.3" >"$SB_CONF"

if ! "$SB_BIN" check -c "$SB_CONF" >/dev/null 2>&1; then
    _red "配置校验失败，详细信息如下:"
    "$SB_BIN" check -c "$SB_CONF"
    die "请检查 conf/vless-ws-tls.json 与 config.conf"
fi
ok "配置已生成: $SB_CONF"

# ----------------------------------------------------------
# 7. 防火墙（重启后由服务启动时自动恢复）
# ----------------------------------------------------------
if [ "$WARP_ON" = "1" ]; then
    FIREWALL_PORTS="$FIREWALL_PORTS $WARP_PORT"
fi

cat >"$SB_FW" <<'FW_EOF'
#!/bin/sh
# 本脚本由 cf-vless 安装时生成；服务每次启动都会执行一次。
PORTS="__PORTS__"
IPV6="__IPV6__"

[ -z "$PORTS" ] && exit 0

if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in $PORTS; do firewall-cmd --permanent --add-port=$p/tcp >/dev/null 2>&1; done
    firewall-cmd --reload >/dev/null 2>&1
    exit 0
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    for p in $PORTS; do ufw allow $p/tcp >/dev/null 2>&1; done
    exit 0
fi

_open_iptables() {
    _cmd="$1"
    command -v "$_cmd" >/dev/null 2>&1 || return 0
    for p in $PORTS; do
        "$_cmd" -C INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 ||
            "$_cmd" -I INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1
    done
}

_open_iptables iptables
[ "$IPV6" = "1" ] && _open_iptables ip6tables
exit 0
FW_EOF

sed -i -e "s|__PORTS__|$FIREWALL_PORTS|" -e "s|__IPV6__|$IPV6|" "$SB_FW"
chmod 755 "$SB_FW"

if [ "$FIREWALL" = "1" ]; then
    if ! command -v iptables >/dev/null 2>&1 &&
        ! command -v firewall-cmd >/dev/null 2>&1 &&
        ! command -v ufw >/dev/null 2>&1; then
        pkg_add iptables
    fi
    "$SB_FW" && ok "防火墙已放行端口: $FIREWALL_PORTS (TCP, IPv4$([ "$IPV6" = "1" ] && echo ' + IPv6'))"
    if ! command -v iptables >/dev/null 2>&1 && ! command -v firewall-cmd >/dev/null 2>&1 && ! command -v ufw >/dev/null 2>&1; then
        warn "没有可用的防火墙工具，已跳过。若访问不通请手动放行端口。"
    fi
else
    say "按参数要求跳过防火墙。"
fi

# ----------------------------------------------------------
# 8. 服务与开机自启
# ----------------------------------------------------------
say ""
say "安装服务 ($INIT) ..."

case "$INIT" in
systemd)
    cat >/etc/systemd/system/sing-box.service <<'UNIT_EOF'
[Unit]
Description=sing-box service (VLESS-WS-TLS)
Documentation=https://sing-box.sagernet.org/
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStartPre=/etc/sing-box/firewall.sh
ExecStart=/etc/sing-box/bin/sing-box run -c /etc/sing-box/conf/vless-ws-tls.json
Restart=always
RestartSec=3
LimitNOFILE=1048576
LimitNPROC=10000
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT_EOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box >/dev/null 2>&1
    ;;
openrc)
    cat >/etc/init.d/sing-box <<'RC_EOF'
#!/sbin/openrc-run

name="sing-box"
description="sing-box service (VLESS-WS-TLS)"
command="/etc/sing-box/bin/sing-box"
command_args="run -c /etc/sing-box/conf/vless-ws-tls.json"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box/run.log"
error_log="/var/log/sing-box/run.log"
supervisor=supervise-daemon
respawn_delay=3

start_pre() {
    /etc/sing-box/firewall.sh >/dev/null 2>&1
}

depend() {
    need net
    after firewall
}
RC_EOF
    chmod 755 /etc/init.d/sing-box
    rc-update add sing-box default >/dev/null 2>&1
    rc-service sing-box restart >/dev/null 2>&1 ||
        rc-service sing-box start >/dev/null 2>&1
    ;;
*)
    warn "系统里既没有 systemd 也没有 OpenRC，改用 rc.local 兜底自启"
    if [ ! -f /etc/rc.local ]; then
        printf '#!/bin/sh\nexit 0\n' >/etc/rc.local
    fi
    grep -q 'cf-vless' /etc/rc.local 2>/dev/null ||
        printf '%s\n' "# cf-vless start" "/etc/sing-box/firewall.sh >/dev/null 2>&1" "nohup /etc/sing-box/bin/sing-box run -c /etc/sing-box/conf/vless-ws-tls.json >/var/log/sing-box/run.log 2>&1 &" \
            >>/etc/rc.local
    chmod 755 /etc/rc.local
    pkill -f "$SB_BIN" >/dev/null 2>&1
    sleep 1
    nohup "$SB_BIN" run -c "$SB_CONF" >/var/log/sing-box/run.log 2>&1 &
    ;;
esac

sleep 2
if pgrep -f "$SB_BIN" >/dev/null 2>&1; then
    ok "sing-box 正在运行（容器重启后会自动拉起）"
else
    warn "sing-box 似乎没有启动成功，请查看日志"
    if [ "$INIT" = "systemd" ]; then
        systemctl status sing-box --no-pager -l 2>/dev/null | tail -n 15
    else
        tail -n 15 /var/log/sing-box/run.log 2>/dev/null
    fi
fi

# ----------------------------------------------------------
# 9. 结果输出与落盘
# ----------------------------------------------------------
VLESS_URL="vless://$UUID@$DOMAIN:$PUBLIC_PORT?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$WS_PATH&sni=$DOMAIN#cf-direct-$DOMAIN"
URL_FILE="$SB_URL_DIR/vless-direct-$DOMAIN.txt"
printf '%s\n' "$VLESS_URL" >"$URL_FILE"
chmod 600 "$URL_FILE"
ln -sf "$URL_FILE" /root/vless-url.txt

WARP_URL=""
URL_FILE_WARP=""
if [ "$WARP_ON" = "1" ]; then
    WARP_URL="vless://$UUID@$DOMAIN:$WARP_PUBLIC_PORT?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$WS_PATH&sni=$DOMAIN#cf-warp-$DOMAIN"
    URL_FILE_WARP="$SB_URL_DIR/vless-warp-$DOMAIN.txt"
    printf '%s\n' "$WARP_URL" >"$URL_FILE_WARP"
    chmod 600 "$URL_FILE_WARP"
    ln -sf "$URL_FILE_WARP" /root/vless-url-warp.txt
fi

printf '%s  %s:%s  %s\n' "$(date '+%F %T')" "$DOMAIN" "$PUBLIC_PORT" "$WS_PATH" >>"$LOG_FILE"
if [ "$WARP_ON" = "1" ]; then
    printf '%s  %s:%s  %s (warp)\n' "$(date '+%F %T')" "$DOMAIN" "$WARP_PUBLIC_PORT" "$WS_PATH" >>"$LOG_FILE"
fi

cat >"$SB_CTL" <<'CTL_EOF'
#!/bin/sh
# cf-vless 管理小工具
case "${1:-}" in
url)
    _n=0
    for f in /etc/sing-box/url/*.txt; do
        [ -f "$f" ] || continue
        echo "-- $(basename "$f") --"
        cat "$f"
        _n=$((_n + 1))
    done
    [ "$_n" = "0" ] && echo "没找到链接文件"
    ;;
qr)
    if ! command -v qrencode >/dev/null 2>&1; then
        echo "未安装 qrencode，先看链接: sbctl url"
    else
        for f in /etc/sing-box/url/*.txt; do
            [ -f "$f" ] || continue
            echo "-- $(basename "$f") --"
            qrencode -t ANSIUTF8 "$(cat "$f")"
        done
    fi
    ;;
status)
    pgrep -f /etc/sing-box/bin/sing-box >/dev/null 2>&1 && echo "sing-box: running" || echo "sing-box: stopped"
    ;;
restart)
    if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/sing-box.service ]; then
        systemctl restart sing-box && echo "已重启"
    elif [ -f /etc/init.d/sing-box ]; then
        rc-service sing-box restart && echo "已重启"
    else
        echo "没有找到服务，请手动启动"
    fi
    ;;
log)
    if command -v journalctl >/dev/null 2>&1 && [ -f /etc/systemd/system/sing-box.service ]; then
        journalctl -u sing-box -n 100 --no-pager
    else
        tail -n 100 /var/log/sing-box/run.log 2>/dev/null
    fi
    ;;
warp)
    _cfg=/etc/sing-box/conf/vless-ws-tls.json
    if [ ! -f "$_cfg" ] || ! grep -q '"vless-warp"' "$_cfg"; then
        echo "本次安装没有装链路B（WARP 出口）"
        exit 0
    fi
    case "${2:-}" in
    on)
        sed -i 's|"inbound": \["vless-warp"\], "action": "route", "outbound": "direct"|"inbound": ["vless-warp"], "action": "route", "outbound": "warp"|' "$_cfg"
        _msg="链路B 已切回 WARP 出口（Cloudflare IP）"
        ;;
    off)
        sed -i 's|"inbound": \["vless-warp"\], "action": "route", "outbound": "warp"|"inbound": ["vless-warp"], "action": "route", "outbound": "direct"|' "$_cfg"
        _msg="链路B 已切成直连出口（不再走 WARP）"
        ;;
    *)
        if grep -q '"outbound": "warp"' "$_cfg"; then
            echo "链路B 当前: 走 WARP 出口（Cloudflare IP）"
        else
            echo "链路B 当前: 走直连出口"
        fi
        echo "用法: sbctl warp on|off"
        exit 0
        ;;
    esac
    if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/sing-box.service ]; then
        systemctl restart sing-box >/dev/null 2>&1
    elif [ -f /etc/init.d/sing-box ]; then
        rc-service sing-box restart >/dev/null 2>&1
    else
        pkill -f /etc/sing-box/bin/sing-box >/dev/null 2>&1
        sleep 1
        nohup /etc/sing-box/bin/sing-box run -c "$_cfg" >/var/log/sing-box/run.log 2>&1 &
    fi
    echo "$_msg"
    ;;
*)
    echo "用法: sbctl {url|qr|status|restart|log|warp}"
    ;;
esac
CTL_EOF
chmod 755 "$SB_CTL"

cat <<EOF

===========================================================
$(printf '\033[32m')安装完成$(printf '\033[0m')
===========================================================
 协议    : VLESS + WebSocket + TLS
 域名    : $DOMAIN
 WS 路径 : $WS_PATH

$(printf '\033[36m')链路A（直连，最快，出口就是本机 IP）:$(printf '\033[0m')
 $VLESS_URL

EOF

if [ "$WARP_ON" = "1" ]; then
    cat <<EOF
$(printf '\033[36m')链路B（出口是 Cloudflare WARP 的 IP，慢一点但 IP 干净）:$(printf '\033[0m')
 $WARP_URL

EOF
fi

cat <<EOF
 链接已保存到:
   $URL_FILE
   /root/vless-url.txt  （软链）
EOF

if [ "$WARP_ON" = "1" ]; then
    cat <<EOF
   $URL_FILE_WARP
   /root/vless-url-warp.txt  （软链）
EOF
fi

cat <<EOF
 随时查看: sbctl url     二维码: sbctl qr
 查看日志: sbctl log     重启服务: sbctl restart
EOF

if [ "$WARP_ON" = "1" ]; then
    cat <<EOF
 开关链路B: sbctl warp on|off   （WARP 不好用时可以直接切回直连）
EOF
fi

cat <<EOF
 完整日志: $LOG_FILE

$(printf '\033[33m')Cloudflare 后台需要确认的:$(printf '\033[0m')
 1. DNS: $DOMAIN 必须开启橙云(Proxied)，并指向本机公网 IP
 2. SSL/TLS 加密模式: Full (strict)
 3. 回源端口（CF 默认按"访客连的端口"回源）:
    链路A: 客户端连 $PUBLIC_PORT -> 本机监听 $LISTEN_PORT
EOF

if [ "$WARP_ON" = "1" ]; then
    cat <<EOF
    链路B: 客户端连 $WARP_PUBLIC_PORT -> 本机监听 $WARP_PORT
    所以 NAT 面板上要有两条映射:
      $PUBLIC_PORT -> $LISTEN_PORT
      $WARP_PUBLIC_PORT -> $WARP_PORT
EOF
fi

cat <<EOF
    只要"客户端连的端口"和"回源端口"是同一个数字，就不用配 Origin Rules；
    对不上（例如公网 12345 -> 容器 $LISTEN_PORT）时，去 Rules -> Origin Rules
    加一条: Hostname = $DOMAIN，Rewrite Destination Port = 你的公网端口。

EOF

if [ "$WARP_ON" = "1" ]; then
    say "链路B 的 WARP 出口跑在 sing-box 进程内，不会多起服务，内存大约多 5-15MB。"
fi
if [ "$PUBLIC_PORT" != "$LISTEN_PORT" ]; then
    warn "注意: PUBLIC_PORT($PUBLIC_PORT) 与 LISTEN_PORT($LISTEN_PORT) 不一致，记得按上面第 3 条配 Origin Rules。"
fi
if [ "$PKG" = "apt-get" ] && ! command -v qrencode >/dev/null 2>&1; then
    say "提示: 想要二维码可以装一下 qrencode（apt-get install -y qrencode），然后执行 sbctl qr"
fi

cleanup
exit 0
