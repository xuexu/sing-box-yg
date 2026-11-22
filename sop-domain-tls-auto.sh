_dom_ok() {
  case "$1" in ""|*[!a-zA-Z0-9.-]*) return 1 ;; esac
  case "$1" in *.*) ;; *) return 1 ;; esac
  case "$1" in [0-9]*.[0-9]*.[0-9]*.[0-9]*) return 1 ;; esac
  case "$1" in
    apple.com|*.apple.com|bing.com|*.bing.com|microsoft.com|*.microsoft.com) return 1 ;;
    icloud.com|*.icloud.com|cloudflare.com|*.cloudflare.com|amazon.com|*.amazon.com) return 1 ;;
    github.com|*.github.com|yahoo.com|*.yahoo.com|qq.com|*.qq.com|baidu.com|*.baidu.com) return 1 ;;
    adobe.com|*.adobe.com|mozilla.org|*.mozilla.org|speedtest.net|*.speedtest.net) return 1 ;;
    tesla.com|*.tesla.com|nvidia.com|*.nvidia.com|samsung.com|*.samsung.com) return 1 ;;
    outlook.com|*.outlook.com|live.com|*.live.com|office.com|*.office.com) return 1 ;;
    letsencrypt.org|*.letsencrypt.org|localhost|example.com|*.example.com) return 1 ;;
  esac
  return 0
}

sop_domain_tls_auto() {
local DOMAIN="" CERT_DIR="/root/ygkkkca"
local WS_PORT
WS_PORT=$(jq -r '.inbounds[1].listen_port // empty' /etc/s-box/sb.json 2>/dev/null)
if [ -z "$WS_PORT" ]; then
  WS_PORT=$(jq -r '[.inbounds[] | select(.tag == "vmess-sb") | .listen_port] | first // empty' /etc/s-box/sb.json 2>/dev/null)
fi
[ -z "$WS_PORT" ] && WS_PORT=2052
local TS; printf -v TS '%(%F)T' -1
local FAIL=0 cur="" curcl="" resid="" dnsip="" pubip="" ptr="" wc="" score=0 rest=""
local src="" cand="" pick="" CAND=/tmp/sop_dom_cand.txt SCORED=/tmp/sop_dom_scored.txt

echo "=========================================================="
echo " sing-box-yg 一键（DOMAIN 自动探测版）"
echo " 证书=$CERT_DIR   端口=$WS_PORT（vmess-sb 自动探测）   日期=$TS"
echo "=========================================================="

if [ ! -x /usr/bin/sb ] || [ ! -f /etc/s-box/sb.json ]; then
  echo "[ABORT] 未检测到 sing-box-yg（/usr/bin/sb 或 /etc/s-box/sb.json 缺失）"; return 1
fi

echo; echo "--- 0/5 DOMAIN 自动探测 ---"
curl -s4 --max-time 10 ifconfig.me > /tmp/sop_pubip.txt 2>/dev/null; read -r pubip < /tmp/sop_pubip.txt
echo "       本机公网: ${pubip:-<空>}"

: > "$CAND"
case "$1" in --detect|-d) ;; *) [ -n "$1" ] && printf 'argv\t%s\n' "$1" >> "$CAND" ;; esac
python3 - >> "$CAND" 2>/dev/null <<'PY'
import base64, json, os, re, glob
def emit(src, v):
    v = str(v).strip()
    if v: print("%s\t%s" % (src, v))
try:
    for line in open("/etc/s-box/server_domain.log", errors="ignore"):
        if line.strip(): emit("server_domain.log", line); break
except Exception: pass
try:
    d = json.load(open("/etc/s-box/sb.json"))
    for ib in d.get("inbounds", []):
        t = ib.get("tls") or {}
        if (t.get("reality") or {}).get("enabled"): continue
        emit("sb.json:%s" % ib.get("tag"), t.get("server_name") or "")
except Exception: pass
for f in sorted(glob.glob("/etc/s-box/*.txt")):
    try: txt = open(f, errors="ignore").read()
    except Exception: continue
    b = os.path.basename(f)
    for m in re.finditer(r"vmess://([A-Za-z0-9+/=]+)", txt):
        try:
            s = m.group(1)
            j = json.loads(base64.b64decode(s + "=" * (-len(s) % 4)))
            for k in ("add", "sni", "host"):
                if j.get(k): emit("link:" + b, j[k])
        except Exception: pass
    for m in re.finditer(r"(?:hy2|hysteria2|tuic|vless|trojan)://[^\s\"'<>]+", txt):
        u = m.group(0)
        h = re.search(r"@([^:/?#]+)", u)
        if h: emit("link:" + b, h.group(1))
        q = re.search(r"[?&](?:sni|peer|host)=([^&#]+)", u)
        if q: emit("link:" + b, q.group(1))
PY

if [ -f "$CERT_DIR/cert.crt" ]; then
  openssl x509 -in "$CERT_DIR/cert.crt" -noout -ext subjectAltName 2>/dev/null \
    | grep -o 'DNS:[^,[:space:]]*' | sed 's/^DNS://' > /tmp/sop_san.txt 2>/dev/null
  while read -r cand; do
    case "$cand" in
      \*.*) printf 'cert-wildcard\t%s\n' "$cand" >> "$CAND" ;;
      "")   : ;;
      *)    printf 'cert-san\t%s\n' "$cand" >> "$CAND" ;;
    esac
  done < /tmp/sop_san.txt
fi

if [ -n "$pubip" ]; then
  dig +short -x "$pubip" > /tmp/sop_ptr.txt 2>/dev/null; read -r ptr < /tmp/sop_ptr.txt
  [ -n "$ptr" ] && printf 'ptr\t%s\n' "${ptr%.}" >> "$CAND"
fi

wc=$(grep -m1 '^cert-wildcard' "$CAND" 2>/dev/null | cut -f2); wc=${wc%.}; wc=${wc,,}

: > "$SCORED"
while IFS=$'\t' read -r src cand; do
  cand=${cand%.}; cand=${cand,,}
  case "$src" in cert-wildcard) continue ;; esac
  _dom_ok "$cand" || continue
  score=0
  if [ -n "$wc" ]; then
    case "$cand" in *."${wc#\*.}") score=$((score + 3)) ;; esac
  fi
  case "$src" in cert-san) score=$((score + 4)) ;; esac
  case "$src" in server_domain.log|sb.json:*) score=$((score + 1)) ;; esac
  dig +short "$cand" > /tmp/sop_dd.txt 2>/dev/null
  if [ -n "$pubip" ] && grep -qxF "$pubip" /tmp/sop_dd.txt; then score=$((score + 2)); fi
  printf '%d\t%s\t%s\n' "$score" "$src" "$cand" >> "$SCORED"
done < "$CAND"

pick=$(sort -k1,1nr "$SCORED" 2>/dev/null | head -1)
if [ -z "$pick" ]; then
  echo "[FAIL] 未能自动探测到域名（候选为空或全部非法）"
  echo "       已收集候选："; sed -n '1,12p' "$CAND" | sed 's/^/         /'
  [ -n "$wc" ] && echo "       仅发现通配证书 $wc，无法据此推断子域名"
  echo "       请显式指定：sop_domain_tls_auto your.domain.com"
  return 1
fi
score=${pick%%$'\t'*}; rest=${pick#*$'\t'}; src=${rest%%$'\t'*}; DOMAIN=${rest#*$'\t'}

echo "[OK]   DOMAIN = $DOMAIN   （来源：$src，匹配分：$score）"
if [ "$score" -ge 5 ]; then echo "       判定：证书覆盖 + 解析指向本机（强匹配）"
elif [ "$score" -ge 3 ]; then echo "       判定：证书覆盖或解析指向本机（中等匹配）"
elif [ "$score" -ge 1 ]; then echo "       判定：仅有来源可信度（弱匹配，建议人工确认）"
else echo "[WARN] 判定：无任何交叉验证，域名可能来自伪装字段，请人工确认或显式传参"; FAIL=1; fi

if [ "$1" = "--detect" ] || [ "$1" = "-d" ]; then
  echo "       打分前 5："; sort -k1,1nr "$SCORED" | head -5 | sed 's/^/         /'
  echo "       全部候选（前 12）："; sed -n '1,12p' "$CAND" | sed 's/^/         /'
  return 0
fi

echo; echo "--- 1/5 环境检查 ---"
systemctl is-active --quiet sing-box && echo "[OK]   sing-box 运行中" || { echo "[WARN] sing-box 未运行"; FAIL=1; }
dig +short "$DOMAIN" > /tmp/sop_dns.txt 2>/dev/null; read -r dnsip < /tmp/sop_dns.txt
echo "       域名解析: ${dnsip:-<空>}"
echo "       本机公网: ${pubip:-<空>}"
if [ -n "$dnsip" ] && [ "$dnsip" = "$pubip" ]; then echo "[OK]   解析与公网IP一致"
else echo "[WARN] 解析与公网IP不一致（套CDN可忽略），否则TLS会失败"; fi

echo; echo "--- 2/5 证书校验 ---"
if [ -f "$CERT_DIR/cert.crt" ] && [ -f "$CERT_DIR/private.key" ]; then
  openssl x509 -in "$CERT_DIR/cert.crt" -noout -subject -dates -ext subjectAltName > /tmp/sop_cert.txt 2>/dev/null
  sed -n '1,6p' /tmp/sop_cert.txt
  san_base=${DOMAIN#*.}
  if grep -qF "$DOMAIN" /tmp/sop_cert.txt; then echo "[OK]   证书覆盖 $DOMAIN"
  elif [ "$san_base" != "$DOMAIN" ] && grep -qF "*.$san_base" /tmp/sop_cert.txt; then
    echo "[OK]   通配证书 *.$san_base 覆盖 $DOMAIN"
  else echo "[WARN] 证书SAN未包含 $DOMAIN，客户端会报证书名不匹配"; FAIL=1; fi
  if openssl x509 -in "$CERT_DIR/cert.crt" -noout -checkend 604800 >/dev/null 2>&1; then echo "[OK]   7天内不过期"
  else echo "[WARN] 证书即将或已过期"; fi
else
  echo "[ABORT] 证书缺失：$CERT_DIR/cert.crt 或 private.key"
  return 1
fi

echo; echo "--- 3/5 写入 vmess-ws TLS 块 ---"
cp -f /etc/s-box/sb.json "/etc/s-box/sb.json.bak.$TS"
DOMAIN="$DOMAIN" CERT="$CERT_DIR/cert.crt" KEY="$CERT_DIR/private.key" python3 - <<'PY'
import os, json
p = "/etc/s-box/sb.json"
d = json.load(open(p)); n = 0
for ib in d.get("inbounds", []):
    if ib.get("type") == "vmess" and ib.get("transport", {}).get("type") == "ws":
        ib["tls"] = {"enabled": True, "server_name": os.environ["DOMAIN"],
                     "certificate_path": os.environ["CERT"], "key_path": os.environ["KEY"]}
        n += 1
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
print(f"[OK]   已为 {n} 个 vmess-ws 入站写入 tls 块")
PY
if /etc/s-box/sing-box check -c /etc/s-box/sb.json > /tmp/sop_check.txt 2>&1; then
  echo "[OK]   配置校验通过"
  systemctl restart sing-box && sleep 2
  systemctl is-active --quiet sing-box && echo "[OK]   服务已重启" || { echo "[FAIL] 重启失败"; FAIL=1; }
  ss -lntp > /tmp/sop_ss.txt 2>/dev/null
  grep -qE ":$WS_PORT([^0-9]|$)" /tmp/sop_ss.txt && echo "[OK]   端口 $WS_PORT 监听中" || { echo "[WARN] 端口 $WS_PORT 未监听"; FAIL=1; }
else
  echo "[FAIL] 配置校验失败，已回滚到 $TS 备份"
  sed -n '1,5p' /tmp/sop_check.txt
  cp -f "/etc/s-box/sb.json.bak.$TS" /etc/s-box/sb.json
  systemctl restart sing-box
  return 1
fi

echo; echo "--- 4/5 节点地址改为域名 ---"
[ -f /etc/s-box/server_ip.log ]   && cp -f /etc/s-box/server_ip.log   /etc/s-box/server_ip.log.bak
[ -f /etc/s-box/server_ipcl.log ] && cp -f /etc/s-box/server_ipcl.log /etc/s-box/server_ipcl.log.bak
printf '3\n10\n0\n' | timeout 150 sb -d "$DOMAIN" > /tmp/sop_domain.log 2>&1
# 成功判定只看 server_ip.log 的内容（不再依赖 server_domain.log）
read -r cur   2>/dev/null < /etc/s-box/server_ip.log
read -r curcl 2>/dev/null < /etc/s-box/server_ipcl.log
if [ "$cur" != "$DOMAIN" ]; then
  echo "[WARN] sb -d 未把节点地址写成域名（当前 server_ip.log = ${cur:-<空>}），改为直接写入"
  printf '%s\n' "$DOMAIN" > /etc/s-box/server_ip.log
  printf '%s\n' "$DOMAIN" > /etc/s-box/server_ipcl.log
  read -r cur   2>/dev/null < /etc/s-box/server_ip.log
  read -r curcl 2>/dev/null < /etc/s-box/server_ipcl.log
fi
if [ "$cur" = "$DOMAIN" ]; then
  echo "[OK]   server_ip.log = $DOMAIN"
else
  echo "[FAIL] server_ip.log 写入失败（当前 = ${cur:-<空>}）"
  FAIL=1
fi
[ "$curcl" = "$DOMAIN" ] && echo "[OK]   server_ipcl.log = $DOMAIN" \
  || echo "[WARN] server_ipcl.log 未同步为域名（只影响 cli 订阅）"

# 订阅是否刷新：额外确认聚合订阅里已含域名
if grep -qF "$DOMAIN" /etc/s-box/jhsub.txt 2>/dev/null; then
  echo "[OK]   聚合订阅 jhsub.txt 已含域名"
else
  echo "[WARN] 聚合订阅 jhsub.txt 未含 $DOMAIN，请在菜单 3 → 8/9 重新生成订阅"
fi

echo; echo "--- 5/5 结果验证 ---"
DOMAIN="$DOMAIN" python3 - <<'PY'
import base64, json, os
D = os.environ["DOMAIN"]; p = "/etc/s-box/vm_ws_tls.txt"
try:
    s = open(p).read().strip().split("//", 1)[1]
    d = json.loads(base64.b64decode(s + "=" * (-len(s) % 4)))
    print("       add =", d.get("add"), "| sni =", d.get("sni"),
          "| tls =", d.get("tls"), "| port =", d.get("port"))
    if d.get("add") == D and d.get("sni") == D and str(d.get("tls")).lower() == "tls":
        print("[OK]   链接已用域名且 TLS 开启")
    else:
        print("[WARN] 链接字段不符，请在菜单重新生成订阅")
except Exception as e:
    print("[WARN] 解析 vm_ws_tls.txt 失败:", e)
PY
timeout 15 openssl s_client -connect "$DOMAIN:$WS_PORT" -servername "$DOMAIN" </dev/null > /tmp/sop_tls.txt 2>&1
grep -q "Verify return code: 0" /tmp/sop_tls.txt && echo "[OK]   TLS 握手验证通过" \
  || { echo "[WARN] TLS 握手异常，摘要："; grep -m2 -i "verify\|error" /tmp/sop_tls.txt; FAIL=1; }
# 残留 IP 检查：聚合订阅里任何形如 x.x.x.x 且非本机/内网的地址都要报出来
resid=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' /etc/s-box/jhsub.txt 2>/dev/null | sort -u | awk -F. '
  $1<=255 && $2<=255 && $3<=255 && $4<=255 {
    if ($1==0 || $1==10 || $1==127 || $1>=224) next
    if ($1==192 && $2==168) next
    if ($1==172 && $2>=16 && $2<=31) next
    if ($1==169 && $2==254) next
    print
  }')
if [ -n "$resid" ]; then
  echo "[WARN] 聚合订阅 jhsub.txt 仍含 IP 地址（节点地址应为域名）："
  printf '%s\n' "$resid" | sed 's/^/         /'
  if [ -n "$pubip" ] && printf '%s\n' "$resid" | grep -qxF "$pubip"; then
    echo "         其中 $pubip 是本机公网 IP"
  fi
else
  echo "[OK]   聚合订阅无 IP 残留"
fi

echo "=========================================================="
if [ "$FAIL" = "0" ]; then echo " 结果：全部通过 ✅"
else echo " 结果：存在告警 ⚠️  详见上方 [WARN]/[FAIL]"; fi
echo " 重跑：sop_domain_tls_auto       仅探测：sop_domain_tls_auto --detect"
echo "=========================================================="
}
sop_domain_tls_auto "$@"
