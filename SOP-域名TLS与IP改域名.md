# SOP：sing-box-yg 开启 vmess-ws TLS + 节点地址改用域名

> 适用于 [yonggekkk/sing-box-yg](https://github.com/yonggekkk/sing-box-yg) 脚本环境（VPS）。
> 目标：① 给 vmess-ws 节点启用 TLS；② 让所有分享链接 / 订阅中的**服务器 IP 换成域名**，方便套 CDN、换 IP 不掉订阅。
> 域名与证书路径均为占位符，换服务器只需替换下表三个变量。

## 0. 变量约定（换服务器只改这里）

| 变量 | 说明 | 本机实测值（示例） |
|---|---|---|
| `<YOUR_DOMAIN>` | 已解析到本机的域名 | `xjp-amd1.1314510.xyz` |
| `<CERT_DIR>` | 证书所在目录 | `/root/ygkkkca` |
| `<WS_PORT>` | vmess-ws 入站端口 | `2052` |

关键路径（脚本固定，一般不用改）：

| 路径 | 作用 |
|---|---|
| `/usr/bin/sb` | 主脚本（菜单入口 `sb`） |
| `/etc/s-box/sb.json` | sing-box 运行配置（vmess 入站 TLS 写在这里） |
| `/etc/s-box/server_ip.log` | **节点地址来源（IPv4）** ← 改域名就是改这里 |
| `/etc/s-box/server_ipcl.log` | 备用/优选地址来源 |
| `/etc/s-box/server_domain.log` | 打补丁后持久化域名（优先于上面两个） |
| `/etc/s-box/vm_ws_tls.txt` | 生成的 vmess-ws-tls 分享链接 |

## 1. 前置检查

```bash
# 1.1 脚本已装、服务在跑
command -v sb && systemctl is-active sing-box

# 1.2 域名解析到本机公网 IP
dig +short <YOUR_DOMAIN>
curl -s4 ifconfig.me; echo

# 1.3 端口放行（云厂商安全组 + 本机防火墙）
ss -lntp | grep -E ":<WS_PORT>|:443"
```

> 1.2 两条结果必须一致；不一致先改 DNS，否则 TLS 一定失败（客户端 SNI 与证书不匹配）。

## 2. 证书准备

### 2.1 已有证书 → 校验域名匹配与有效期

```bash
openssl x509 -in <CERT_DIR>/cert.crt -noout -subject -dates -ext subjectAltName
```

- `subjectAltName` 必须包含 `<YOUR_DOMAIN>`（通配符 `*.example.com` 也可覆盖一级子域）。
- 不匹配就重新签（2.2），**不要**硬用，否则客户端报 `certificate is not valid for the name`。

### 2.2 无证书 / 证书过期 → acme.sh 申请（推荐）

```bash
curl -s https://get.acme.sh | sh -s email=you@example.com

# 独立模式签发（需先停掉占用 80 端口的服务）
~/.acme.sh/acme.sh --issue -d <YOUR_DOMAIN> --standalone

# 安装到脚本读取的固定路径，并设置续期后自动重启
~/.acme.sh/acme.sh --install-cert -d <YOUR_DOMAIN> \
  --key-file       <CERT_DIR>/private.key \
  --fullchain-file <CERT_DIR>/cert.crt \
  --reloadcmd      "systemctl restart sing-box"
```

### 2.3 自签（仅测试，客户端需关闭证书校验）

```bash
mkdir -p <CERT_DIR>
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -days 3650 -keyout <CERT_DIR>/private.key -out <CERT_DIR>/cert.crt \
  -subj "/CN=<YOUR_DOMAIN>" -addext "subjectAltName=DNS:<YOUR_DOMAIN>"
```

## 3. 开启 vmess-ws 的 TLS

### 3.1 备份配置

```bash
cp /etc/s-box/sb.json /etc/s-box/sb.json.bak.$(date +%F)
```

### 3.2 写入 tls 块（幂等，可重复执行）

```bash
python3 - <<'PY'
import json
DOMAIN = "<YOUR_DOMAIN>"
CERT   = "<CERT_DIR>/cert.crt"
KEY    = "<CERT_DIR>/private.key"
p = "/etc/s-box/sb.json"

d = json.load(open(p))
n = 0
for ib in d.get("inbounds", []):
    if ib.get("type") == "vmess" and ib.get("transport", {}).get("type") == "ws":
        ib["tls"] = {
            "enabled": True,
            "server_name": DOMAIN,
            "certificate_path": CERT,
            "key_path": KEY,
        }
        n += 1
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
print(f"已为 {n} 个 vmess-ws 入站开启 TLS")
PY
```

生成结果应形如：

```json
{
  "type": "vmess",
  "tag": "vmess-sb",
  "listen_port": 2052,
  "transport": { "type": "ws", "path": "<uuid>-vm" },
  "tls": {
    "enabled": true,
    "server_name": "<YOUR_DOMAIN>",
    "certificate_path": "/root/ygkkkca/cert.crt",
    "key_path": "/root/ygkkkca/private.key"
  }
}
```

### 3.3 校验并重启

```bash
/etc/s-box/sing-box check -c /etc/s-box/sb.json && systemctl restart sing-box
systemctl is-active sing-box
ss -lntp | grep ":<WS_PORT>"
```

### 3.4 验证 TLS 握手

```bash
openssl s_client -connect <YOUR_DOMAIN>:<WS_PORT> -servername <YOUR_DOMAIN> </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates
```

能看到正确 subject / 日期 = TLS 生效。

> ⚠️ **重要**：用脚本菜单「3 变更配置」改任何配置都会**重新生成 sb.json**，可能覆盖 3.2 的 tls 块。改完菜单配置后务必重跑 3.2 + 3.3，或在菜单里同步选择 TLS 证书项。

## 4. 节点地址 IP → 域名

原理：脚本所有分享链接/订阅里的 `add` 字段都读自 `/etc/s-box/server_ip.log`（及 `server_ipcl.log`），**不需要改脚本逻辑**，改这两个文件即可。分两档做法。

### 4.1 快速法（一次性，适合先验证）

```bash
cp /etc/s-box/server_ip.log   /etc/s-box/server_ip.log.bak
cp /etc/s-box/server_ipcl.log /etc/s-box/server_ipcl.log.bak

echo "<YOUR_DOMAIN>" > /etc/s-box/server_ip.log
echo "<YOUR_DOMAIN>" > /etc/s-box/server_ipcl.log

# 重新生成分享链接与订阅
bash /usr/bin/sb     # 进菜单 → 执行「生成/更新分享与订阅」项（内部函数 sbshare）
```

### 4.2 持久法（推荐，可复用）—— 打域名补丁

补丁为 `sing-box-yg-domain.patch`，新增：`-d/--domain` 启动参数、`set_domain()` 函数、菜单「3 → 10：节点地址设为域名」。
域名持久化到 `/etc/s-box/server_domain.log`，脚本每次生成订阅时优先读它，因此**换域名、重装订阅都不会丢**。

```bash
cd /root
cp -n /usr/bin/sb sb.bak.orig              # 备份原脚本（已有备份不覆盖）

# 补丁头文件名固定为 fork_sb.sh，需按此命名再打
cp /usr/bin/sb fork_sb.sh
patch -p0 --dry-run --batch -N < sing-box-yg-domain.patch   # 试运行，必须无 FAILED
patch -p0          --batch -N < sing-box-yg-domain.patch    # 生成 fork_sb_patched.sh

install -m 755 fork_sb_patched.sh /usr/bin/sb
```

参数说明（很关键，否则会卡在交互提问）：

| 参数 | 作用 |
|---|---|
| `--dry-run` | 只检查不写文件 |
| `--batch` | 不向用户提问（防止交互挂起） |
| `-N` | 已应用过的补丁自动跳过，而非提示 `Reversed (or previously applied) patch detected!` |

> 若不带 `--batch`，遇到已打补丁的脚本会停在 `Assume -R? [n]` 等待输入，SSH 会话表现为“卡住”。

用法（二选一）：

```bash
# 方式 A：命令行一次性设定并刷新订阅
sb -d <YOUR_DOMAIN>

# 方式 B：菜单交互
sb            # 3 变更配置 → 10 节点地址设为域名 → 输入 <YOUR_DOMAIN>
```

撤销域名（回到 IP 输出）：

```bash
rm -f /etc/s-box/server_domain.log
bash /usr/bin/sb          # 重新生成一次分享/订阅
```

> ⚠️ 补丁基于特定上游版本。**其它服务器脚本版本不同时，必须先 `--dry-run`**；出现 `FAILED` 就退回 4.1，或按 4.3 手工改。
> ⚠️ 菜单「7 更新脚本」会覆盖 `/usr/bin/sb`，**更新后需重打补丁**。

### 4.3 手工等价改法（补丁打不上时）

在脚本中把读取 IP 的位置改为优先读域名文件：

```bash
grep -n "server_ip\.log" /usr/bin/sb
```

把每个 `IFS= read -r server_ip < /etc/s-box/server_ip.log` 之前插入：

```bash
[[ -s /etc/s-box/server_domain.log ]] && IFS= read -r server_ip < /etc/s-box/server_domain.log
```

## 5. 验证清单

| # | 检查项 | 命令 | 期望 |
|---|---|---|---|
| 1 | 配置合法 | `/etc/s-box/sing-box check -c /etc/s-box/sb.json` | 无输出/OK |
| 2 | 服务运行 | `systemctl is-active sing-box` | `active` |
| 3 | 端口监听 | `ss -lntp \| grep :<WS_PORT>` | 有 sing-box |
| 4 | TLS 生效 | 见 3.4 | 返回正确域名证书 |
| 5 | 链接含域名 | `cat /etc/s-box/vm_ws_tls.txt` 解码 | `add`/`host`/`sni` = `<YOUR_DOMAIN>` |
| 6 | 订阅无 IP 残留 | `grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' /etc/s-box/*.txt` | 无本机公网 IP（其它 IP 属正常） |

vmess 链接解码校验：

```bash
python3 -c "
import base64,json
s=open('/etc/s-box/vm_ws_tls.txt').read().strip().split('//',1)[1]
d=json.loads(base64.b64decode(s))
print('add =',d['add']); print('tls =',d.get('tls')); print('sni =',d.get('sni')); print('port=',d['port'])
"
```

期望：`add` 与 `sni` 均为 `<YOUR_DOMAIN>`，`tls = tls`，`port = <WS_PORT>`。

## 6. 客户端配置要点

| 字段 | 值 |
|---|---|
| 地址 (add) | `<YOUR_DOMAIN>`（**不要填 IP**） |
| 端口 | `<WS_PORT>` |
| TLS / tls | 开启（`tls`） |
| SNI / serverName | `<YOUR_DOMAIN>` |
| Host / ws headers | `<YOUR_DOMAIN>` |
| path | `<uuid>-vm`（与 sb.json 中 `transport.path` 一致） |
| allowInsecure | 仅自签证书时开启 |

## 7. 回滚

```bash
# 回滚 TLS
cp /etc/s-box/sb.json.bak.<日期> /etc/s-box/sb.json
systemctl restart sing-box

# 回滚域名
rm -f /etc/s-box/server_domain.log
cp /etc/s-box/server_ip.log.bak /etc/s-box/server_ip.log
cp /etc/s-box/server_ipcl.log.bak /etc/s-box/server_ipcl.log

# 回滚脚本补丁
cp /root/sb.bak.orig /usr/bin/sb
```

## 8. 常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| 客户端连不上、日志报 `x509: certificate is valid for ...` | 证书 SAN 与填写的域名不一致 | 重签证书，或改用证书里的名字 |
| TLS 握手失败 / 无响应 | 端口未放行，或用了 2052 却套 Cloudflare 小黄云 | 放行安全组；CF 代理只走 443/8443 等支持端口，或关闭代理 |
| 订阅里还是 IP | 只改了 `server_ip.log`，没重新生成订阅 | 重跑 4.1 的 `sbshare` 步骤 / `sb -d <域名>` |
| 改了菜单配置后 TLS 又没了 | 菜单 3 重新生成 sb.json 覆盖 tls 块 | 重跑 3.2 + 3.3 |
| 点了「7 更新脚本」后域名失效 | 脚本被上游版本覆盖 | 重打 4.2 补丁 |
| 执行 patch 时终端“卡住”无输出 | 未加 `--batch`，停在 `Assume -R? [n]` 提问 | Ctrl+C 退出，改用 `patch -p0 --batch -N` |
| 证书 90 天后失效 | acme.sh 未装 reloadcmd 或 cron 失效 | `~/.acme.sh/acme.sh --list` 检查，补 `--reloadcmd` |
| 域名生效但节点慢 | 域名解析到境外/被污染 | 换解析线路，或套 CDN 优选 IP |

## 9. 执行顺序速查（TL;DR）

```bash
# 1) 证书就绪并匹配域名
openssl x509 -in <CERT_DIR>/cert.crt -noout -ext subjectAltName
# 2) 备份
cp /etc/s-box/sb.json /etc/s-box/sb.json.bak.$(date +%F)
# 3) 写入 tls 块（3.2 脚本）
# 4) 校验重启
/etc/s-box/sing-box check -c /etc/s-box/sb.json && systemctl restart sing-box
# 5) 域名化
cp -n /usr/bin/sb sb.bak.orig && cp /usr/bin/sb fork_sb.sh
patch -p0 --dry-run --batch -N < sing-box-yg-domain.patch && patch -p0 --batch -N < sing-box-yg-domain.patch
install -m 755 fork_sb_patched.sh /usr/bin/sb
sb -d <YOUR_DOMAIN>
# 6) 验证（第 5 节清单）
```

## 附录 A：本机实测基线（xjp-amd1，供比对）

| 项目 | 值 |
|---|---|
| 主脚本 | `/usr/bin/sb`，148778 B（打补丁后 149732 B） |
| 补丁文件 | `/root/sing-box-yg-domain.patch`，3701 B，7 个 hunk |
| 补丁自检 | 对原始脚本 `--dry-run --batch -N` 返回 `exit=0` |
| 原脚本备份 | `/root/sb.bak.orig` |
| 打补丁副本 | `/root/sb.patched.sh` |
| vmess 入站 | tag `vmess-sb`，端口 2052，ws path `<uuid>-vm` |
| 证书 | `/root/ygkkkca/cert.crt` + `private.key`（Let's Encrypt，有效期 3 个月） |
| 自签证书 | `/etc/s-box/cert.pem` + `private.key`（脚本默认，未用于 vmess） |
| 地址来源 | `server_ip.log` 与 `server_ipcl.log` 均已写入域名 |
| 订阅端口 / token | `subport.log` / `subtoken.log`（注意保密） |

## 附录 B：一次性检查脚本（可直接贴到新服务器跑）

```bash
D=<YOUR_DOMAIN>; P=<WS_PORT>
echo "域名解析: $(dig +short $D)"; echo "本机公网: $(curl -s4 ifconfig.me)"
systemctl is-active sing-box
/etc/s-box/sing-box check -c /etc/s-box/sb.json && echo "配置OK"
python3 - <<PY
import json
d=json.load(open('/etc/s-box/sb.json'))
for ib in d.get('inbounds',[]):
    if ib.get('type')=='vmess':
        t=ib.get('tls') or {}
        print('port',ib['listen_port'],'tls',t.get('enabled'),'sni',t.get('server_name'),'cert',t.get('certificate_path'))
PY
echo "地址来源: $(cat /etc/s-box/server_ip.log) | $(cat /etc/s-box/server_ipcl.log)"
openssl s_client -connect $D:$P -servername $D </dev/null 2>/dev/null | openssl x509 -noout -subject -dates
```
