#!/bin/bash
set -euo pipefail

# can't remember what this does but it looks important
sudo cat > /etc/sysctl.d/20-bridge-nf.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
EOF


# ==============================================================================
# Turn off swap
# https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/#before-you-begin
# ==============================================================================
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab


# ==============================================================================
# Install containerd
# https://kubernetes.io/docs/setup/production-environment/container-runtimes/#containerd
# ==============================================================================
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Setup required sysctl params, these persist across reboots.
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# (Install containerd)
sudo apt-get update && sudo apt-get install -y containerd

# Configure containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml

# Restart containerd
sudo systemctl restart containerd


# ==============================================================================
# Install kubeadm
#
# Letting iptables see bridged traffic
# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#letting-iptables-see-bridged-traffic
# ==============================================================================
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system


# ==============================================================================
# Installing kubeadm, kubelet and kubectl 
# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#installing-kubeadm-kubelet-and-kubectl
# ==============================================================================
sudo apt-get update && sudo apt-get install -y apt-transport-https curl
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl


# ==============================================================================
# Creating a cluster with kubeadm
# ==============================================================================
# --pod-network-cidr=10.244.0.0/16 is required for flannel
# https://coreos.com/flannel/docs/latest/kubernetes.html
sudo kubeadm init --pod-network-cidr=10.244.0.0/16

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# ==============================================================================
# Install flannel
# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#pod-network
# ==============================================================================
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml


# ==============================================================================
# Let pods run on this node
# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#control-plane-node-isolation
# ==============================================================================
kubectl taint nodes --all node-role.kubernetes.io/master-

# ==============================================================================
# Install nginx ingress
#
# This is a horrible way of doing it, but I need to somehow add `hostNetwork: true`
# to the Pod definitions.
# I think the "real" answer is extending nginx-ingress somewhere
# (app.kubernetes.io/part-of?)
# (The real real answer is using a real cloud load balancer but we're trying to
# do things cheap but as real as possible here)
# https://stackoverflow.com/a/56998424/4396258
# ==============================================================================
NGINX_FILE="${HOME}/nginx-ingress.yaml"
curl -L https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/baremetal/deploy.yaml > $NGINX_FILE
sed -i '/dnsPolicy\: ClusterFirst$/ s:$:\n      hostNetwork\: true:' "$NGINX_FILE"
kubectl apply -f "$NGINX_FILE"

# ==============================================================================
# Create hello world app
# ==============================================================================
cat > "${HOME}/hello-k8s.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: hello-kubernetes
spec:
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: hello-kubernetes
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-kubernetes
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello-kubernetes
  template:
    metadata:
      labels:
        app: hello-kubernetes
    spec:
      containers:
      - name: hello-kubernetes
        image: paulbouwer/hello-kubernetes:1.8
        ports:
        - containerPort: 8080
EOF
kubectl apply -f "${HOME}/hello-k8s.yaml"

# ==============================================================================
# Create ingress
# ==============================================================================
cat > "${HOME}/ingress.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minimal-ingress
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/add-base-url: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - host: k8s.mark.pizza
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hello-kubernetes
            port:
              number: 80
EOF