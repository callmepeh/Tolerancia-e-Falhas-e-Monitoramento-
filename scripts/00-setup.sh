#!/usr/bin/env bash
# ============================================================
# 00-setup.sh — sobe o ambiente completo (Minikube + app + Prometheus)
# Uso: ./scripts/00-setup.sh
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
step() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  [ok]${NC} $*"; }
warn() { echo -e "${YELLOW}  [!]${NC} $*"; }

step "1/6 Verificando pré-requisitos"
for tool in minikube kubectl docker; do
  command -v "$tool" >/dev/null || { echo "ERRO: '$tool' não encontrado no PATH"; exit 1; }
done
ok "minikube, kubectl e docker disponíveis"

step "2/6 Subindo o cluster Minikube (se necessário)"
if ! minikube status >/dev/null 2>&1; then
  minikube start --cpus=2 --memory=4096 --driver=docker
else
  ok "Minikube já está rodando"
fi
# Carrega as imagens construídas dentro do Minikube (sem precisar de registry)
eval "$(minikube docker-env)"

step "3/6 Construindo a imagem da aplicação"
docker build -t meteo-api:1.0 ./app
ok "imagem meteo-api:1.0 construída"

step "4/6 Implantando a aplicação (Deployment + Service + HPA)"
kubectl apply -f k8s/app-deployment.yaml
kubectl apply -f k8s/app-service-hpa.yaml

step "5/6 Implantando o monitoramento"
kubectl apply -f k8s/monitoring/prometheus.yaml
kubectl apply -f k8s/monitoring/kube-state-metrics.yaml

step "6/6 Aguardando pods ficarem prontos"
kubectl -n default rollout status deployment/meteo-api --timeout=180s
kubectl -n monitoring rollout status deployment/prometheus --timeout=180s
kubectl -n monitoring rollout status deployment/kube-state-metrics --timeout=180s

echo
ok "Ambiente pronto!"
echo -e "
  Abrir Prometheus:  ${CYAN}minikube service prometheus -n monitoring${NC}
  Ou com port-forward:
    kubectl -n monitoring port-forward svc/prometheus 9090:9090
    kubectl -n default   port-forward svc/meteo-api  8080:8080

  Testar a aplicação:
    curl \$(minikube service meteo-api --url)/weather?city=curitiba
"
