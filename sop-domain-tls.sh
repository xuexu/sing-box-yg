sop_domain_tls() {
local DOMAIN="xjp-amd1.1314510.xyz"
local CERT_DIR="/root/ygkkkca"
local WS_PORT="2052"
local TS; printf -v TS '%(%F)T' -1
local FAIL=0 cur="" dnsip="" pubip=""

echo "=========================================================="
echo " sing-box-yg 一键：vmess-ws 开 TLS + 节点地址改域名"
echo " 域名=$DOMAIN   证书=$CERT_DIR   端口=$WS_PORT   日期=$TS"
echo "=========================================================="

if [ -z "$DOMAIN" ]; then echo "[ABORT] 域名占位符未填写"; return 1; fi
if [ ! -x /usr/bin/sb ]; then echo "[ABORT] 未找到 /usr/bin/sb（未安装 sing-box-yg）"; return 1; fi
if [ ! -f /etc/s-box/sb.json ]; then echo "[ABORT] 未找到 /etc/s-box/sb.json"; return 1; fi

echo; echo "--- 1/5 环境检查 ---"
systemctl is-active --quiet sing-box && echo "[OK]   sing-box 运行中" || { echo "[WARN] sing-box 未运行"; FAIL=1; }
dig +short "$DOMAIN" > /tmp/sop_dns.txt 2>/dev/null; read -r dnsip < /tmp/sop_dns.txt
curl -s4 --max-time 10 ifconfig.me > /tmp/sop_pubip.txt 2>/dev/null; read -r pubip < /tmp/sop_pubip.txt
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
read -r cur 2>/dev/null < /etc/s-box/server_domain.log
if [ "$cur" = "$DOMAIN" ]; then
  echo "[OK]   server_domain.log = $DOMAIN（已持久化）"
else
  echo "[WARN] 域名未持久化，回退写 server_ip.log"
  printf '%s\n' "$DOMAIN" > /etc/s-box/server_ip.log
  printf '%s\n' "$DOMAIN" > /etc/s-box/server_ipcl.log
  echo "[WARN] 已写入地址文件，需手动在菜单重新生成一次订阅"
  FAIL=1
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
if [ -n "$pubip" ] && grep -q "$pubip" /etc/s-box/jhsub.txt 2>/dev/null; then
  echo "[WARN] 聚合订阅 jhsub.txt 仍含本机IP $pubip"
else echo "[OK]   聚合订阅无本机IP残留"; fi

echo "=========================================================="
if [ "$FAIL" = "0" ]; then echo " 结果：全部通过 ✅"
else echo " 结果：存在告警 ⚠️  详见上方 [WARN]/[FAIL]"; fi
echo " 重跑：sop_domain_tls     回滚：见 SOP 第 7 节"
echo "=========================================================="
}
sop_domain_tls
