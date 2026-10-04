# meteo-api — Atividade 4 de Sistemas Distribuídos

> **Tolerância a Falhas e Monitoramento com Kubernetes + Prometheus**

Aplicação distribuída implantada em Kubernetes local (Minikube) com mecanismos de **tolerância a falhas**, **auto-recuperação**, **escalonamento horizontal** e **monitoramento com Prometheus**.

**Aplicação escolhida:** um serviço de **previsão do tempo** (`meteo-api`) — diferente de todas as aplicações anteriores da disciplina (não é to-do list, calculadora, blog ou API de tarefas). É uma API HTTP em Node.js puro (sem frameworks) que expõe clima de cidades, métricas Prometheus, probes de saúde e endpoints especiais usados para **provocar falhas e carga de forma controlada**.

---

## Sumário

1. [Arquitetura](#arquitetura)
2. [Pré-requisitos](#pré-requisitos)
3. [Como executar (passo a passo)](#como-executar-passo-a-passo)
4. [Endpoints da aplicação](#endpoints-da-aplicação)
5. [Os 4 experimentos](#os-4-experimentos)
6. [Consultas PromQL úteis](#consultas-promql-úteis)
7. [Estrutura do repositório](#estrutura-do-repositório)

---

## Arquitetura

```
                          ┌──────────────────────────────────────────────┐
                          │                CLUSTER MINIKUBE              │
                          │                                              │
  curl / navegador ──────►│  ┌────────────────────┐                      │
                          │  │ svc/meteo-api :80  │                      │
                          │  └─────────┬──────────┘                      │
                          │            │ (selector app=meteo-api)        │
                          │   ┌────────┴─────────┐                       │
                          │   ▼                  ▼   (2..5 pods, HPA)   │
                          │ ┌──────────┐     ┌──────────┐                │
                          │ │ meteo-api│     │ meteo-api│  requests/limits│
                          │ │ 100m/250m│     │ 100m/250m│  livenessProbe │
                          │ └────┬─────┘     └────┬─────┘                │
                          │      │ /metrics       │ /metrics             │
                          │      ▼                ▼                      │
                          │ ┌──────────────────────────────────┐         │
                          │ │ PROMETHEUS (ns monitoring) :9090 │         │
                          │ │  • scrape dos pods da app        │         │
                          │ │  • scrape kube-state-metrics     │         │
                          │ │  • scrape cAdvisor (CPU real)    │         │
                          │ └──────────────────────────────────┘         │
                          │ ┌──────────────────────────────────┐         │
                          │ │ kube-state-metrics               │         │
                          │ │ (pods, restarts, réplicas, HPA)  │         │
                          │ └──────────────────────────────────┘         │
                          └──────────────────────────────────────────────┘
```

| Componente | Função |
|---|---|
| `Deployment meteo-api` | 2 réplicas iniciais, `requests cpu=100m`, `limits cpu=250m` |
| `livenessProbe /healthz` | kubelet reinicia o container se a rota falhar (auto-recuperação) |
| `readinessProbe /readyz` | tira pods não prontos da rotação do Service (sem downtime) |
| `HPA meteo-api` | mantém CPU média em 50% do request, entre 2 e 5 réplicas |
| `Service meteo-api` | ClusterIP que balanceia entre os pods prontos |
| `load-generator` | busybox que bombardeia `/busy` para acionar o HPA |
| `Prometheus` | coleta métricas da aplicação, do kube-state-metrics e do cAdvisor |
| `kube-state-metrics` | expõe estado dos objetos K8s (pods, restarts, réplicas do HPA) |

---

## Pré-requisitos

- **Docker** (ou Podman) rodando
- **Minikube** >= 1.30
- **kubectl** >= 1.27
- **bash** (Linux/macOS/Git Bash)

## Como executar (passo a passo)

### 1. Subir tudo de uma vez (recomendado)

```bash
./scripts/00-setup.sh
```

O script: inicia o Minikube, constrói a imagem `meteo-api:1.0` dentro do cluster, aplica os manifests da aplicação e do monitoramento e aguarda os pods ficarem prontos.

### 2. Verificar

```bash
kubectl get pods -l app=meteo-api          # 2 pods Running
kubectl get hpa meteo-api                  # alvo 50%, min 2, max 5
kubectl -n monitoring get pods             # prometheus + kube-state-metrics

# Abrir a UI do Prometheus (Ctrl-C para sair)
minikube service prometheus -n monitoring
```

> Alternativa ao `minikube service`: `kubectl -n monitoring port-forward svc/prometheus 9090:9090` e abrir `http://localhost:9090`.

### 3. Testar a aplicação

```bash
APP_URL=$(minikube service meteo-api --url)
curl "$APP_URL/"
curl "$APP_URL/weather?city=curitiba"
```

---

## Endpoints da aplicação

| Rota | Descrição |
|---|---|
| `GET /` | informações do serviço (versão, pod que respondeu, uptime) |
| `GET /healthz` | **livenessProbe** — devolve 200, ou 500 quando a falha programada está ativa |
| `GET /readyz` | **readinessProbe** — sempre 200 |
| `GET /metrics` | métricas Prometheus (`meteoapi_*` + métricas padrão do Node) |
| `GET /weather?city=X` | consulta o clima de uma cidade |
| `GET /fail?on=N` | **arma a falha**: após N chamadas OK ao `/healthz`, ele passa a devolver 500 (Experimento 2) |
| `GET /busy?sec=N&spin=K` | **gera carga de CPU real** por N segundos com fração K de ocupação (Experimento 3) |

Exemplo de resposta:

```json
{"city":"curitiba","temp":15.8,"cond":"garoa","umid":81,"servedBy":"meteo-api-7d9f6c8b5d-x2p4q"}
```

O campo `servedBy` mostra qual pod atendeu — útil para demonstrar o balanceamento entre réplicas.

---

## Os 4 experimentos

Cada script guia o experimento de forma interativa, medindo os tempos e indicando **quais telas gravar** para o vídeo/relatório.

### Experimento 1 — Deleção de Pod

```bash
./scripts/01-exp1-delete-pod.sh
```

- Deleta um pod e acompanha em tempo real: pod removido → novo pod criado → `Running`/`Ready`.
- O script imprime o **tempo de recuperação** calculado.
- No Prometheus: `kube_pod_status_phase{pod=~"meteo-api.*"}` cai de 2→1→2.

### Experimento 2 — Falha no Container

```bash
./scripts/02-exp2-container-failure.sh
```

- Injeta a falha **dentro do processo** (`/fail?on=2`): o `/healthz` começa a devolver 500.
- O `livenessProbe` detecta, o kubelet mata o container e o `RESTARTS` incrementa.
- O script imprime a explicação de **recriar pod vs reiniciar container**.

### Experimento 3 — Sobrecarga de CPU (HPA)

```bash
./scripts/03-exp3-hpa-load.sh
```

- Implanta o `load-generator`, que ataca `/busy` continuamente.
- Mostra a CPU subir, o HPA escalar de 2 até o **máximo de 5 réplicas**, e depois reduzir de volta a 2 quando a carga é removida.
- O script imprime o **tempo de escalonamento**.

### Experimento 4 — Interrupção do Monitoramento

```bash
./scripts/04-exp4-prometheus-down.sh
```

- Derruba o Prometheus (`scale --replicas=0`), prova que a **aplicação continua respondendo HTTP 200** durante a interrupção, depois o traz de volta e confirma que as métricas retornam.
- Imprime a explicação de por que **falha no monitoramento ≠ falha na aplicação** (o Prometheus é um observador passivo, fora do caminho crítico).

---

## Consultas PromQL úteis

Cole na aba *Graph* do Prometheus (`http://localhost:9090/graph`):

```promql
# Pods ativos (Running)
sum(kube_pod_status_phase{namespace="default", phase="Running", pod=~"meteo-api.*"})

# Uso real de CPU por pod (núcleos)
sum(rate(container_cpu_usage_seconds_total{pod=~"meteo-api.*"}[1m])) by (pod)

# Estado dos pods (não-Running chama atenção)
sum(kube_pod_status_phase{pod=~"meteo-api.*"}) by (phase)

# Reinicializações de container
sum(increase(kube_pod_container_status_restarts_total{pod=~"meteo-api.*"}[10m])) by (pod)

# Rélicas atuais / desejadas / máximo do HPA (alterações do HPA)
kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler="meteo-api"}
kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler="meteo-api"}
kube_horizontalpodautoscaler_spec_max_replicas{horizontalpodautoscaler="meteo-api"}

# Disponibilidade do Deployment
sum(kube_deployment_status_replicas_available{deployment="meteo-api"})
```

---

## Estrutura do repositório

```
.
├── app/                          # Aplicação
│   ├── server.js                 # API Node puro + prom-client
│   ├── package.json
│   └── Dockerfile
├── k8s/                          # Manifests Kubernetes
│   ├── app-deployment.yaml       # Deployment (2 réplicas, probes, requests/limits)
│   ├── app-service-hpa.yaml      # Service + HPA (2..5, CPU 50%)
│   ├── load-generator.yaml       # Gerador de carga do Experimento 3
│   └── monitoring/
│       ├── prometheus.yaml       # Namespace, ConfigMap, Deployment, RBAC
│       └── kube-state-metrics.yaml
├── scripts/                      # Automação dos experimentos
│   ├── 00-setup.sh               # Sobe o ambiente completo
│   ├── 01-exp1-delete-pod.sh
│   ├── 02-exp2-container-failure.sh
│   ├── 03-exp3-hpa-load.sh
│   └── 04-exp4-prometheus-down.sh
└── docs/
    └── GUIA-DO-ALUNO.md          # Roteiro para gravação do vídeo + teoria
```

---

## Limpeza

```bash
minikube delete   # encerra o cluster e libera os recursos
```
