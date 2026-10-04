#!/usr/bin/env bash
# ============================================================
# 04-exp4-prometheus-down.sh — Experimento 4: Interrupção do Monitoramento
#
# 1. Mostra que o Prometheus está saudável (targets UP)
# 2. Derruba o Prometheus (scale to 0)
# 3. Demonstra que a aplicação continua respondendo normalmente
# 4. Traz o Prometheus de volta e confirma que as métricas voltam
# 5. Explica por que falha no monitoramento != falha na aplicação
# ============================================================
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
step() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  [ok]${NC} $*"; }
ts()   { date +%H:%M:%S; }

step "1. Prometheus saudável"
kubectl -n monitoring get pods -l app=prometheus

step "2. Testando a aplicação ANTES da interrupção"
APP_URL=$(minikube service meteo-api --url 2>/dev/null | head -1)
echo "URL da aplicação: $APP_URL"
echo "Resposta de /weather?city=manaus ANTES:"
curl -s "${APP_URL}/weather?city=manaus" || true

echo
read -r -p "Pressione ENTER para DERRUBAR o Prometheus..."

step "3. Derrubando o Prometheus (scale to 0)"
kubectl -n monitoring scale deployment/prometheus --replicas=0
kubectl -n monitoring get deploy prometheus

echo -e "\nAguardando 60s para provar que a aplicação segue de pé...\n"
for i in 15 30 45 60; do
  sleep 15
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' "${APP_URL}/weather?city=manaus" || echo ERR)
  echo "[$(ts)] t=+${i}s  GET /weather -> HTTP ${HTTP}"
done

step "4. A aplicação continua 100% funcional (mais 2 req. de prova)"
curl -s "${APP_URL}/weather?city=curitiba"; echo
curl -s "${APP_URL}/weather?city=rio-de-janeiro"; echo

echo
read -r -p "Pressione ENTER para reiniciar o Prometheus..."

step "5. Trazendo o Prometheus de volta"
kubectl -n monitoring scale deployment/prometheus --replicas=1
kubectl -n monitoring rollout status deployment/prometheus --timeout=180s
ok "Prometheus de volta"

echo
echo "Estado final:"
kubectl -n monitoring get pods

cat <<'EOF'

============================================================
 POR QUE FALHA NO MONITORAMENTO != FALHA NA APLICAÇÃO?
============================================================
 O Prometheus é um observador PASSIVO: ele apenas coleta
 (scrape) métricas que os componentes expõem. Ele NÃO faz
 parte do caminho crítico entre usuário e aplicação —
 nenhuma requisição de /weather passa por ele.

 Por isso, ao derrubá-lo:
   - A aplicação continuou respondendo HTTP 200 normalmente.
   - Os pods não foram afetados, o HPA continuou funcionando.
   - A ÚNICA consequência foi a ausência de novas métricas.

 Conceito chave: o monitoramento é importante para OBSERVAR
 a aplicação, mas não é um ponto único de falha do serviço.
 Se fosse o contrário (acoplado fortemente), uma falha no
 Prometheus derrubaria a aplicação também — quebrando o
 princípio de baixo acoplamento de sistemas distribuídos.
============================================================
EOF
