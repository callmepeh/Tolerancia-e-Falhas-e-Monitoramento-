#!/usr/bin/env bash
# ============================================================
# 03-exp3-hpa-load.sh — Experimento 3: Sobrecarga de CPU (HPA)
#
# 1. Mostra o HPA estável em 2 réplicas
# 2. Implanta o load-generator (attacks /busy)
# 3. Acompanha: CPU sobe -> HPA aumenta réplicas -> max 5
# 4. Remove a carga -> HPA reduz de volta para 2
# 5. Mede o tempo de escalonamento
# ============================================================
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
step() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  [ok]${NC} $*"; }
ts()   { date +%H:%M:%S; }

step "Estado ANTES: HPA e pods"
kubectl get hpa meteo-api
kubectl get pods -l app=meteo-api
echo
read -r -p "Pressione ENTER para iniciar a carga..."

T0=$(date +%s)
step "Iniciando o load-generator (ataca /busy do Service)"
kubectl apply -f k8s/load-generator.yaml
echo "Pods do gerador de carga:"
kubectl get pods -l app=load-generator

echo -e "\nAcompanhando o HPA (as linhas são impressas quando algo muda)...\n"
LAST=""
MAX_SEEN=2
while true; do
  CURRENT=$(kubectl get hpa meteo-api --no-headers 2>/dev/null | awk '{print $3}')
  DESIRED=$(kubectl get hpa meteo-api --no-headers 2>/dev/null | awk '{print $4}')

  if [ "$CURRENT" != "$LAST" ]; then
    echo "[$(ts)] HPA: réplicas atuais=${CURRENT}, desejadas=${DESIRED}"
    LAST="$CURRENT"
  fi

  if [ "$DESIRED" -gt "$MAX_SEEN" ]; then
    MAX_SEEN=$DESIRED
  fi

  if [ "$DESIRED" -ge 5 ]; then
    echo -e "${GREEN}[${RESET}$(ts)${NC}] HPA chegou ao MÁXIMO (5 réplicas)!"
    T1=$(date +%s)
    break
  fi
  sleep 3
done

echo
echo "=============================================="
echo " TEMPO DE ESCALONAMENTO (2 -> 5): $((T1 - T0)) s"
echo "=============================================="
kubectl get pods -l app=meteo-api -o wide
echo
read -r -p "Pressione ENTER para REMOVER a carga e observar o scale-down..."

step "Removendo o load-generator"
kubectl delete -f k8s/load-generator.yaml

echo -e "\nAguardando o HPA estabilizar de volta em 2 réplicas...\n"
while true; do
  DESIRED=$(kubectl get hpa meteo-api --no-headers 2>/dev/null | awk '{print $4}')
  CURRENT=$(kubectl get hpa meteo-api --no-headers 2>/dev/null | awk '{print $3}')
  echo "[$(ts)] HPA: atual=${CURRENT}, desejado=${DESIRED}"
  if [ "$DESIRED" = "2" ] && [ "$CURRENT" = "2" ]; then
    ok "scale-down concluído: de volta a 2 réplicas"
    break
  fi
  sleep 10
done

kubectl get pods -l app=meteo-api
echo
cat <<'EOF'
O que observar no Prometheus:
  sum(rate(container_cpu_usage_seconds_total{pod=~"meteo-api.*"}[1m])) by (pod)
  kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler="meteo-api"}
  kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler="meteo-api"}
  (há inclusive a métrica ..._spec_max_replicas = 5, o "quantidade máxima de pods")
EOF
