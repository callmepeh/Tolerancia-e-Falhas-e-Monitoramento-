#!/usr/bin/env bash
# ============================================================
# 02-exp2-container-failure.sh — Experimento 2: Falha no Container
#
# A falha é provocada dentro do processo: chamamos /fail?on=2
# no pod escolhido, e o /healthz começa a devolver 500 após
# 2 respostas OK. O livenessProbe detecta e o kubelet mata o
# container -> RESTARTS incrementa -> container volta.
#
# No final, explica a diferença entre recriar pod vs reiniciar container.
# ============================================================
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
step() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  [ok]${NC} $*"; }
ts()   { date +%H:%M:%S; }

step "Estado ANTES do experimento"
kubectl get pods -l app=meteo-api
POD=$(kubectl get pods -l app=meteo-api -o jsonpath='{.items[0].metadata.name}')
RESTARTS_BEFORE=$(kubectl get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}')
echo -e "Pod alvo: ${RED}${POD}${NC} (restarts antes: ${RESTARTS_BEFORE})"
read -r -p "Pressione ENTER para armar a falha..."

step "Armando a falha no processo (via /fail?on=2)"
kubectl exec "$POD" -- wget -q -O - "http://localhost:8080/fail?on=2" 2>/dev/null || \
  kubectl exec "$POD" -- curl -s "http://localhost:8080/fail?on=2"

echo -e "\n[${GREEN}$(ts)${NC}] Falha armada. O livenessProbe (a cada 5s) logo detectará o 500."
echo "Acompanhe o RESTARTS subir:\n"

PREV=""
while true; do
  LINE=$(kubectl get pods -l app=meteo-api \
    -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount' 2>/dev/null)
  if [ "$LINE" != "$PREV" ]; then
    echo "[$(ts)]"
    echo "$LINE" | sed 's/^/    /'
    echo
    PREV="$LINE"
  fi
  AFTER=$(kubectl get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
  if [ "$AFTER" != "$RESTARTS_BEFORE" ] && [ "$AFTER" != "?" ]; then
    T1=$(date +%s)
    echo -e "${GREEN}RESTARTS mudou de ${RESTARTS_BEFORE} para ${AFTER} em $((T1 - T0))s${NC}"
    break
  fi
  sleep 2
done

step "Aguardando o container voltar a Ready"
kubectl wait --for=condition=Ready pod/"$POD" --timeout=120s && ok "pod Ready novamente"

echo
cat <<'EOF'
============================================================
 DIFERENÇA: RECRIAR POD vs REINICIAR CONTAINER
============================================================
 REINICIAR CONTAINER (o que aconteceu aqui):
   - Quem detectou foi o kubelet, via livenessProbe.
   - Ação: matar e reiniciar o CONTAINER dentro do MESMO pod.
   - IP do pod, nome e identidade NÃO mudam.
   - É mais rápido (sem agendar novo pod, sem subir etcd).
   - Métrica que mostra: RESTARTS (kube_pod_container_status_restarts_total)

 RECRIAR POD (Experimento 1):
   - Quem detectou foi o Deployment/ReplicaSet (pod sumiu).
   - Ação: criar um pod NOVO, com novo nome e novo IP.
   - Passa pelo scheduler, Provisioning, etcd, etc.
   - É mais lento, mas resolve também problemas de nó.
   - Métricas: kube_pod_status_phase / replicas do Deployment
============================================================
EOF
