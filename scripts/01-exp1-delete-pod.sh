#!/usr/bin/env bash
# ============================================================
# 01-exp1-delete-pod.sh — Experimento 1: Deleção de Pod
#
# Demonstra: pod removido -> novo pod criado -> Running ->
# comportamento no Prometheus + tempo de recuperação.
# ============================================================
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
step() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  [ok]${NC} $*"; }
ts()   { date +%H:%M:%S; }

step "Estado ANTES da deleção"
kubectl get pods -l app=meteo-api -o wide
POD_BEFORE=$(kubectl get pods -l app=meteo-api -o jsonpath='{.items[0].metadata.name}')
REPLICAS_BEFORE=$(kubectl get deploy meteo-api -o jsonpath='{.status.readyReplicas}')
echo -e "Pod a ser deletado: ${RED}${POD_BEFORE}${NC}  (réplicas prontas: ${REPLICAS_BEFORE})"
echo -e "${YELLOW}>>> GRAVE A TELA AQUI (print do 'kubectl get pods')${NC}"
read -r -p "Pressione ENTER para deletar o pod..."

T0=$(date +%s)
echo -e "\n[${GREEN}$(ts)${NC}] Deletando pod ${POD_BEFORE}..."
kubectl delete pod "$POD_BEFORE" --wait=false

echo -e "\nObservando a recuperação (ctrl-C para abortar):\n"
PREV_STATE=""
while true; do
  READY=$(kubectl get deploy meteo-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  DESIRED=$(kubectl get deploy meteo-api -o jsonpath='{.spec.replicas}')
  NEW_POD=$(kubectl get pods -l app=meteo-api \
    --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.startTime}{"\n"}{end}' 2>/dev/null)

  STATE="${READY}/${DESIRED}"
  if [ "$STATE" != "$PREV_STATE" ]; then
    echo "[$(ts)] réplicas prontas: ${READY}/${DESIRED}"
    echo -e "$NEW_POD" | sed 's/^/    /'
    echo
    PREV_STATE="$STATE"
  fi

  if [ "$READY" = "$DESIRED" ] && [ "$READY" -ge "$REPLICAS_BEFORE" ]; then
    # dá 2 ciclos extra para estabilizar
    sleep 2
    READY2=$(kubectl get deploy meteo-api -o jsonpath='{.status.readyReplicas}')
    if [ "$READY2" = "$DESIRED" ]; then
      T1=$(date +%s)
      echo -e "${GREEN}[${RESET}${GREEN}$(ts)${NC}] aplicação recuperada!"
      echo
      echo "=============================================="
      echo " TEMPO DE RECUPERAÇÃO: $((T1 - T0)) segundos"
      echo "=============================================="
      echo
      ok "estado final:"
      kubectl get pods -l app=meteo-api -o wide
      break
    fi
  fi
  sleep 2
done

step "O que observar no Prometheus"
cat <<'EOF'
  Query sugerida (cole em http://localhost:9090/graph):
    kube_pod_status_phase{phase="Running", pod=~"meteo-api.*"}
    sum(kube_deployment_status_replicas_available{deployment="meteo-api"})
    sum(rate(container_cpu_usage_seconds_total{pod=~"meteo-api.*"}[1m])) by (pod)

  O gráfico mostrará: valor cai de 2 -> 1 (pod morto) e volta a 2
  (novo pod Running). O intervalo entre a queda e a recuperação é
  o tempo de recuperação medido pelo script.
EOF
