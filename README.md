# huangkingking

骑在 Cloudflare 上的自托管 VLESS 节点，一条命令装到廉价 NAT LXC / VPS 上。

- 协议：VLESS + WebSocket + TLS（Cloudflare Origin 证书）+ Cloudflare CDN
- 两条互不影响的链接：**直连**（最快）/ **走 Cloudflare WARP 出口**（IP 干净些，慢一点）
- 配置、证书和私钥在仓库里都是**加密存放**的，安装时用口令解密；公开仓库里看不到域名 / UUID / WS 路径
- 二进制固定版本、内置在 `bin/`，安装过程**不访问任何第三方源**

## 一键安装

```sh
wget -q -O - https://raw.githubusercontent.com/spverk/huangkingking/main/install.sh | sh -s -- --pass 你的口令
```

口令用于解密仓库里的 `config.conf.enc` 和 `secret/` 下的证书、私钥，由你自己定，不放在仓库里。

### 参数

| 参数 | 说明 |
| --- | --- |
| `--pass <口令>` | **必填**，解密仓库里加密的配置文件与 CF 证书 |
| `--domain <域名>` | 覆盖 `config.conf` 的 `DOMAIN` |
| `--port <端口>` | 覆盖 `LISTEN_PORT` |
| `--public-port <端口>` | 覆盖 `PUBLIC_PORT`（NAT 对外端口） |
| `--warp-port <端口>` | 覆盖 `WARP_PUBLIC_PORT`（链路B 对外端口） |
| `--uuid <uuid>` | 覆盖 `UUID` |
| `--path </路径>` | 覆盖 `WS_PATH` |
| `--core-version <版本>` | 指定 sing-box 版本（须已放进 `bin/`），默认 1.14.3 |
| `--repo <raw 地址>` | 换仓库/分支时指定 raw 地址 |
| `--no-firewall` | 不动防火墙 |
| `--no-warp` | 只装直连那条链路 |
| `--url` | 只打印已保存的链接并退出 |
| `--uninstall` | 卸载 |

## 目录结构

```
./
├── install.sh              一键安装 / 卸载脚本
├── config.conf             预置参数（本地明文版，供你编辑；**不上传仓库**）
├── config.conf.enc         上面那份配置加密后的版本（上传仓库的是它）
├── conf/vless-ws-tls.json  配置模板（带 __XXX__ 占位符，安装时由脚本渲染成真配置）
├── bin/                    固定版本的 sing-box 二进制包（amd64 / arm64）
└── secret/                 加密后的 Cloudflare Origin 证书与私钥
```

## Cloudflare 后台要配的

1. **DNS**：`4xui.mashen.de5.net` 开橙云（Proxied），指向小机的公网 IP
2. **SSL/TLS 模式**：`Full (strict)`
3. **回源端口**：CF 默认按「访客连的端口」回源
   - 链路A：客户端连 `443` → 容器 `443`
   - 链路B：客户端连 `8443` → 容器 `8443`
4. **NAT 小机**要在面板上加两条映射 `443 → 443`、`8443 → 8443`；
   如果对外端口和容器端口数字对不上，去 Rules → Origin Rules 加一条
   `Hostname = 域名`、`Rewrite Destination Port = 对外端口`

## 两条链接

| 链接 | 端口 | 出口 IP | 特点 |
| --- | --- | --- | --- |
| 链路A 直连 | 443 | 本机 IP | 最快 |
| 链路B WARP | 8443 | Cloudflare 的 IP | 慢一点，IP 干净些 |

安装完会直接打印两条 `vless://`，同时落盘：

- `/etc/sing-box/url/vless-direct-<域名>.txt`
- `/etc/sing-box/url/vless-warp-<域名>.txt`
- 软链：`./vless-url.txt`、`./vless-url-warp.txt`

## 装完之后的常用命令

```sh
sbctl url          # 查看两条链接
sbctl qr           # 出二维码（需先装 qrencode）
sbctl status       # 服务状态
sbctl restart      # 重启服务
sbctl log          # 看日志
sbctl warp on|off  # 把链路B 临时切回直连 / 再切回 WARP 出口
```

## 升级 core

把新的 `sing-box-<版本>-linux-amd64.tar.gz` / `-arm64.tar.gz` 放进 `bin/`，
再把 `config.conf` 里的 `FALLBACK_CORE_VERSION` 改成对应版本，重跑一次安装命令即可。

> 官方无后缀的包是 **glibc 动态链接**版。Alpine(musl) 机器还需要额外放
> `sing-box-<版本>-linux-<架构>-musl.tar.gz`，`install.sh` 检测到跑不起来会自动改用 musl 那份。

## 重新加密（改了配置或换了证书之后）

仓库里不放明文，改完本地文件要重新加密再上传。口令要和安装时 `--pass` 传的一致。

```sh
# 配置：改完 config.conf 后重新加密
openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -base64 \
  -in config.conf -out config.conf.enc -pass pass:你的口令

# 证书
openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -base64 \
  -in tls.cer -out secret/tls.cer.enc -pass pass:你的口令
openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -base64 \
  -in tls.key -out secret/tls.key.enc -pass pass:你的口令
```

> 加密只是「别让翻仓库的人顺手拿到」，口令弱的话防不住专门破解的。口令别写进任何文件。

## 说明

- 无环境变量，参数全在 `config.conf` 预置，命令行只用来临时覆盖
- 服务重启后自动拉起（systemd / OpenRC / rc.local 三种都支持）
- 安装时把 Cloudflare 的 13 个回源端口全部放行（TCP，IPv4 + IPv6），规则随服务启动自动恢复
- WARP 出口以用户态 WireGuard 跑在 sing-box 进程内，不额外起进程，约多占 5-15MB 内存
- 本仓库不依赖 233boy 等第三方脚本，只用 curl/wget、tar、openssl
