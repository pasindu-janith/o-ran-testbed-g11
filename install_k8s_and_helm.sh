#!/bin/bash -x
################################################################################
# Optimized for Ubuntu 20.04 - Kubernetes v1.28.11
################################################################################

usage() {
    echo "Usage: $0 [ -k <k8s version> -d <docker version> -e <helm version> -c <cni-version>]" 1>&2;
    exit 1;
}

wait_for_pods_running () {
  NS="$2"
  # Ensure kubectl is available before running check
  if ! command -v kubectl &> /dev/null; then
    echo "kubectl not found yet. Skipping pod check..."
    return
  fi
  
  CMD="kubectl get pods -n $NS "
  [ "$NS" = "all-namespaces" ] && CMD="kubectl get pods --all-namespaces "
  
  KEYWORD="Running"
  [ "$#" = "3" ] && KEYWORD="${3}.*Running"

  CMD2="$CMD | grep \"$KEYWORD\" | wc -l"
  NUMPODS=$(eval "$CMD2")
  echo "waiting for $NUMPODS/$1 pods running in namespace [$NS] with keyword [$KEYWORD]"
  while [ "$NUMPODS" -lt "$1" ]; do
    sleep 5
    NUMPODS=$(eval "$CMD2")
    echo "> waiting for $NUMPODS/$1 pods running in namespace [$NS] with keyword [$KEYWORD]"
  done 
}

# --- Default Versions ---
KUBEV="1.28.11"
HELMV="3.14.4"
DOCKERV="20.10.21"
KUBECNIV="1.1.1" 

while getopts ":k:d:e:c:" o; do
    case "${o}" in
        e) HELMV=${OPTARG} ;;
        d) DOCKERV=${OPTARG} ;;
        k) KUBEV=${OPTARG} ;;
        c) KUBECNIV=${OPTARG} ;;
        *) usage ;;
    esac
done

set -x
export DEBIAN_FRONTEND=noninteractive
echo "$(hostname -I) $(hostname)" >> /etc/hosts

# Version formatting for Ubuntu 20.04
DOCKERVERSION="${DOCKERV}-0ubuntu1~20.04.2"
KUBEVERSION="${KUBEV}-1.1" 
APTOPTS="--allow-downgrades --allow-change-held-packages --allow-unauthenticated --ignore-hold"

# 1. Prepare Repositories & Keys
# Using --batch --yes to avoid the "Overwrite?" prompt seen in your logs
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" > /etc/apt/sources.list.d/kubernetes.list

# 2. Unhold and Cleanup
# This prevents the "Held packages were changed" error
apt-mark unhold kubeadm kubelet kubectl docker.io kubernetes-cni || true

apt-get update
for PKG in kubeadm docker.io; do
    if dpkg -l | grep -q "${PKG}"; then
        [ "${PKG}" = "kubeadm" ] && kubeadm reset -f --silent && rm -rf ~/.kube
        apt-get -y $APTOPTS purge kubeadm kubelet kubectl kubernetes-cni docker.io
    fi
done
apt-get -y autoremove

# 3. Installation
# Re-installing with specific versions
apt-get install -y $APTOPTS docker.io=${DOCKERVERSION} || apt-get install -y $APTOPTS docker.io
apt-get install -y $APTOPTS kubelet=${KUBEVERSION} kubeadm=${KUBEVERSION} kubectl=${KUBEVERSION} kubernetes-cni

# Lock versions to prevent accidental updates
apt-mark hold docker.io kubelet kubeadm kubectl

# 4. Docker Configuration
cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "100m" },
  "storage-driver": "overlay2"
}
EOF
systemctl daemon-reload
systemctl restart docker

# 5. Kubernetes Cluster Init
swapoff -a
# Ensure we use the freshly installed kubeadm
/usr/bin/kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=v${KUBEV}

# Setup Kubeconfig for root
mkdir -p /root/.kube
cp -i /etc/kubernetes/admin.conf /root/.kube/config
export KUBECONFIG=/root/.kube/config
echo "export KUBECONFIG=/root/.kube/config" >> /root/.bashrc

# 6. Pod Network (Flannel)
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 7. Wait for System Pods
# For 1.28, we wait for core components to stabilize
wait_for_pods_running 6 kube-system

# Untaint master to allow pod scheduling (Supports both old and new labels)
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
kubectl taint nodes --all node-role.kubernetes.io/master- || true

# 8. Helm Installation
if [ ! -f "helm-v${HELMV}-linux-amd64.tar.gz" ]; then
    wget https://get.helm.sh/helm-v${HELMV}-linux-amd64.tar.gz
fi
tar -zxvf helm-v${HELMV}-linux-amd64.tar.gz
mv linux-amd64/helm /usr/local/bin/helm
rm -rf linux-amd64

echo "Deployment Complete. Use 'kubectl get nodes' to verify."