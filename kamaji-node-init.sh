#!/bin/bash
set -euo pipefail

### 1. Install K3s management cluster
echo "🟢 Installing K3s management cluster..."
export INSTALL_K3S_EXEC="--flannel-backend none \
  --disable-network-policy \
  --disable traefik \
  --disable servicelb \
  --cluster-cidr 172.16.2.0/24 \
  --advertise-address 192.168.56.101 \
  --node-ip 192.168.56.101 \
  --node-external-ip 172.17.0.101 \
  --tls-san 192.168.56.200 \
  --cluster-init"

curl -sfL https://get.k3s.io | sh -

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

### 2. Install Calico CNI
echo "🟢 Installing Calico CNI..."
wget -q https://docs.projectcalico.org/manifests/tigera-operator.yaml
wget -q https://docs.projectcalico.org/manifests/custom-resources.yaml

kubectl apply -f tigera-operator.yaml

sed -i 's|cidr: .*|cidr: 172.16.2.0/24|' custom-resources.yaml
kubectl apply -f custom-resources.yaml

echo "✅ Waiting for Calico pods..."
kubectl -n calico-system wait --for=condition=Available --timeout=180s deploy/tigera-operator

# Enable IP forwarding
kubectl patch configmap cni-config -n calico-system --type merge -p '{"data":{"allow_ip_forwarding":"true"}}'

### 3. Install Helm
echo "🟢 Installing Helm..."
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x get_helm.sh && ./get_helm.sh

### 4. Install MetalLB
echo "🟢 Installing MetalLB..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml

# Wait for MetalLB controller to be ready
kubectl -n metallb-system wait --for=condition=Available --timeout=180s deploy/controller

# Apply MetalLB IP pool and advertisement
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kamaji-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.56.200-192.168.56.210
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2adv
  namespace: metallb-system
EOF

### 5. Install Cert-Manager
echo "🟢 Installing Cert-Manager..."
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true

kubectl -n cert-manager wait --for=condition=Available --timeout=180s deploy/cert-manager

### 6. Install Kamaji Controller
echo "🟢 Installing Kamaji..."
helm repo add clastix https://clastix.github.io/charts
helm repo update

helm install kamaji clastix/kamaji \
  --version 0.0.0+latest \
  --namespace kamaji-system \
  --create-namespace \
  --set image.tag=latest

echo "✅ Waiting for Kamaji controller..."
kubectl -n kamaji-system wait --for=condition=Available --timeout=180s deploy/kamaji

echo "✅ All components installed successfully."
