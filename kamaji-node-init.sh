#!/bin/bash
set -euo pipefail

### Globals
KUBECONFIG=/etc/rancher/k3s/k3s.yaml
K3S_NODE_IP="192.168.56.101"
K3S_EXTERNAL_IP="172.17.0.101"
VIP="192.168.56.200"
POD_CIDR="172.16.2.0/24"

### Functions

clean_up() {
  echo "🧹 Cleaning up any existing Kubernetes setup..."

  if command -v k3s &> /dev/null; then
    echo "🛑 Uninstalling K3s..."
    /usr/local/bin/k3s-uninstall.sh || true
    rm -rf /etc/rancher /var/lib/rancher /var/lib/kubelet /etc/cni /opt/cni /var/lib/cni /etc/sysconfig/kubelet
  fi

  echo "🧽 Removing Helm and Argo CD CLI if present..."
  rm -f /usr/local/bin/helm /usr/local/bin/argocd
  rm -f ./get_helm.sh ./argocd-linux-amd64

  echo "🧽 Removing leftover manifests..."
  rm -f tigera-operator.yaml custom-resources.yaml

  echo "♻️  Restarting container runtime..."
  systemctl restart containerd || true
}

install_dependencies() {
  echo "🔧 Installing required packages..."
  apt-get update && apt-get install -y curl jq sudo
}

install_k3s() {
  echo "🟢 Installing K3s management cluster..."

  export INSTALL_K3S_EXEC="--flannel-backend none \
    --disable-network-policy \
    --disable traefik \
    --disable servicelb \
    --cluster-cidr ${POD_CIDR} \
    --advertise-address ${K3S_NODE_IP} \
    --node-ip ${K3S_NODE_IP} \
    --node-external-ip ${K3S_EXTERNAL_IP} \
    --tls-san ${VIP} \
    --cluster-init"

  curl -sfL https://get.k3s.io | sh -
  export KUBECONFIG=$KUBECONFIG
}

install_calico() {
  echo "🟢 Installing Calico CNI..."

  wget -q https://docs.projectcalico.org/manifests/tigera-operator.yaml
  wget -q https://docs.projectcalico.org/manifests/custom-resources.yaml

  kubectl create -f tigera-operator.yaml
  sed -i "s|cidr: .*|cidr: ${POD_CIDR}|" custom-resources.yaml
  kubectl apply -f custom-resources.yaml

  echo "⌛ Waiting for 'tigera-operator' namespace to be ready..."
  for i in {1..30}; do
    if kubectl get ns tigera-operator &> /dev/null; then
      break
    fi
    sleep 2
  done

  echo "✅ Waiting for Tigera operator to be available..."
  kubectl -n tigera-operator wait --for=condition=Available --timeout=180s deploy/tigera-operator

  echo "⌛ Waiting for 'calico-system' namespace to be created..."
  for i in {1..30}; do
    if kubectl get ns calico-system &> /dev/null; then
      break
    fi
    sleep 2
  done

  echo "⌛ Waiting for all pods in 'calico-system' to be ready..."
for i in {1..60}; do
  not_ready=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | grep -v "Running\|Completed" || true)
  if [[ -z "$not_ready" ]]; then
    echo "✅ All Calico pods are running."
    break
  fi
  sleep 5
done

  echo "🔧 Patching CNI config to allow IP forwarding..."
  kubectl patch configmap cni-config -n calico-system --type merge -p '{"data":{"allow_ip_forwarding":"true"}}' || true
}


install_helm() {
  echo "🟢 Installing Helm..."
  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod +x get_helm.sh && ./get_helm.sh
}

install_metallb() {
  echo "🟢 Installing MetalLB..."
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml
  kubectl -n metallb-system wait --for=condition=Available --timeout=180s deploy/controller

  cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kamaji-pool
  namespace: metallb-system
spec:
  addresses:
    - ${VIP}-192.168.56.210
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2adv
  namespace: metallb-system
EOF
}

install_cert_manager() {
  echo "🟢 Installing Cert-Manager..."
  helm repo add jetstack https://charts.jetstack.io
  helm repo update

  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --set installCRDs=true

  kubectl -n cert-manager wait --for=condition=Available --timeout=180s deploy/cert-manager
}

install_kamaji() {
  echo "🟢 Installing Kamaji Controller..."
  helm repo add clastix https://clastix.github.io/charts
  helm repo update

  helm install kamaji clastix/kamaji \
    --version 0.0.0+latest \
    --namespace kamaji-system \
    --create-namespace \
    --set image.tag=latest

  kubectl -n kamaji-system wait --for=condition=Available --timeout=180s deploy/kamaji
}

install_argocd() {
  echo "🟣 Installing Argo CD..."
  kubectl create namespace argocd || true
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  echo "🔧 Installing Argo CD CLI..."
  VERSION=$(curl -L -s https://raw.githubusercontent.com/argoproj/argo-cd/stable/VERSION)
  curl -sSL -o argocd-linux-amd64 "https://github.com/argoproj/argo-cd/releases/download/v$VERSION/argocd-linux-amd64"
  sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
  rm argocd-linux-amd64

  echo "✅ Argo CD CLI installed: $(argocd version --client)"

  echo "🔧 Exposing Argo CD on NodePort 32080..."
  kubectl -n argocd patch svc argocd-server \
    --type merge \
    -p '{
      "spec": {
        "type": "NodePort",
        "ports": [
          {
            "name": "http",
            "port": 80,
            "protocol": "TCP",
            "targetPort": 8080,
            "nodePort": 32080
          },
          {
            "name": "https",
            "port": 443,
            "protocol": "TCP",
            "targetPort": 8080
          }
        ]
      }
    }'

  echo "🔐 Logging into Argo CD via CLI..."
  for i in {1..30}; do
    echo "⌛ Waiting for Argo CD admin secret..."
    if kubectl -n argocd get secret argocd-initial-admin-secret &> /dev/null; then
      break
    fi
    sleep 5
  done

  ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

  argocd login "${K3S_NODE_IP}:32080" \
    --username admin \
    --password "$ARGOCD_PASSWORD" \
    --insecure

  echo "✅ Argo CD installed and logged in successfully!"
}

### Main Execution
main() {
  clean_up
  install_dependencies
  install_k3s
  install_calico
  install_helm
  install_metallb
  install_cert_manager
  install_kamaji
  install_argocd
}

main "$@"
