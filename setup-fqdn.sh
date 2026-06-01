#!/bin/bash
set -e

# ============================================================
# GT AI OS - FQDN Routing Setup
# <TENANT_FQDN>   → <VM_IP>:3002
# <CTP_FQDN>      → <VM_IP>:3001

# Example values:
#   VM_IP="10.255.255.60"
#   TENANT_FQDN="chat.example.com"
#   CTP_FQDN="ctp-chat.example.com"
# ============================================================

VM_IP="<VM_IP>"
TENANT_FQDN="<TENANT_FQDN>"
CTP_FQDN="<CTP_FQDN>"

echo "=== [1/6] Installing nginx + stream module ==="
sudo apt update && sudo apt install -y nginx libnginx-mod-stream
sudo systemctl enable nginx

echo "=== [2/6] Writing stream.conf ==="
sudo tee /etc/nginx/stream.conf > /dev/null <<EOF
stream {
  map \$ssl_preread_server_name \$backend {
    ${TENANT_FQDN}   ${VM_IP}:3002;
    ${CTP_FQDN}      ${VM_IP}:3001;
  }
  server {
    listen 443;
    proxy_pass \$backend;
    ssl_preread on;
  }
}
EOF

echo "=== [3/6] Injecting stream.conf into nginx.conf ==="
# Remove any existing include to avoid duplicates
sudo sed -i '/include \/etc\/nginx\/stream.conf/d' /etc/nginx/nginx.conf
# Add include at top level, before http block
sudo sed -i '/^http {/i include /etc/nginx/stream.conf;' /etc/nginx/nginx.conf
# Remove default site
sudo rm -f /etc/nginx/sites-enabled/default

echo "=== [4/6] Testing and reloading nginx ==="
sudo nginx -t && sudo systemctl reload nginx

echo "=== [5/6] Patching RKE2 ingress off port 443 ==="
KUBECTL="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"

echo "Current ingress ports:"
$KUBECTL -n kube-system get daemonset rke2-ingress-nginx-controller -o json | \
  python3 -c "import json,sys; ds=json.load(sys.stdin); ports=ds['spec']['template']['spec']['containers'][0]['ports']; [print(i, p) for i,p in enumerate(ports)]"

$KUBECTL -n kube-system patch daemonset rke2-ingress-nginx-controller \
  --type=json -p='[{"op":"remove","path":"/spec/template/spec/containers/0/ports/0"}]'

echo "Waiting for ingress pods to restart..."
sleep 15

echo "=== [6/6] Restarting nginx and verifying port ownership ==="
sudo systemctl restart nginx
sleep 5

echo ""
echo "--- Port 443 ownership ---"
sudo ss -tlnp | grep 443

echo ""
echo "=== Setup complete ==="
echo "Test from an EXTERNAL machine (not this VM):"
echo "  curl -vk https://${TENANT_FQDN} 2>&1 | grep -E 'subject|issuer|Connected'"
echo "  curl -vk https://${CTP_FQDN} 2>&1 | grep -E 'subject|issuer|Connected'"
echo ""
echo "nginx should own :443 and cert should NOT say 'Kubernetes Ingress Controller Fake Certificate'"
