# Guia do Aluno — Entender a aplicação e gravar o vídeo

> Este documento é **só seu** (não vai para o professor). Objetivo: em ~20 minutos de leitura você entende cada peça da aplicação, sabe *por que* de cada linha dos manifests, e tem um roteiro cronometrado de 5 minutos para o vídeo do YouTube.

---

## Parte 1 — Entendendo a aplicação (sem decoreba)

### 1.1 A história em uma frase

Você criou um **serviço de previsão do tempo** (`meteo-api`) rodando em Kubernetes, e usa o próprio cluster para **quebrar, estressar e vigiar** esse serviço — provando que ele se recupera sozinho (liveness probe), escala sozinho (HPA) e continua de pé mesmo quando o "olho que o vigia" (Prometheus) é desligado.

### 1.2 As peças e seus papéis

| Peça | Arquivo | Papel na demo |
|---|---|---|
| **App Node.js** | `app/server.js` | API de clima com 3 "superpoderes" escondidos: expor métricas, falhar sob comando, queimar CPU sob comando |
| **Dockerfile** | `app/Dockerfile` | Empacota a app na imagem `meteo-api:1.0` (multi-stage, usuário não-root) |
| **Deployment** | `k8s/app-deployment.yaml` | 2 réplicas + `requests/limits` de CPU + `livenessProbe` + `readinessProbe` |
| **Service + HPA** | `k8s/app-service-hpa.yaml` | Balanceia tráfego; HPA mantém CPU ~50%, entre 2 e 5 pods |
| **Prometheus** | `k8s/monitoring/prometheus.yaml` | Coleta métricas da app, do kube-state-metrics e do cAdvisor a cada 5s |
| **kube-state-metrics** | `k8s/monitoring/kube-state-metrics.yaml` | Traduz o estado dos objetos do K8s (pods, restarts, réplicas do HPA) em métricas |
| **load-generator** | `k8s/load-generator.yaml` | Busybox que martela `/busy` para o Experimento 3 |
| **Scripts** | `scripts/0*.sh` | Orquestram cada experimento, cronometram e te dizem o que filmar |

### 1.3 Os "superpoderes" da aplicação (o segredo da atividade)

A atividade pede que você **provoque** falha e **gere** carga. A ideia elegante é: em vez de você fazer malabarismos de fora do cluster, a própria aplicação tem comandos de autossabotagem controlada:

1. **`/fail?on=N`** — arma uma "doença": as próximas N respostas do `/healthz` são 200, depois ele passa a devolver **500**. O `livenessProbe` do Kubernetes bate nesse endpoint a cada 5s; ao ver o 500, o **kubelet mata e reinicia o container** → o `RESTARTS` sobe. É exatamente o mecanismo real de auto-recuperação do K8s, sem gambiarra.
2. **`/busy?sec=N&spin=K`** — solta um *busy-loop* de verdade (cálculo inútil de raízes quadradas) que consome CPU real por N segundos. Com `spin=1` o processo fica 100% ocupado. O `load-generator` chama isso em loop, a CPU passa de 50% do request e o **HPA reage** criando pods novos.
3. **`/metrics`** — expõe `meteoapi_*` (contadores de requisições, histograma de latência) + métricas padrão do Node. É o que o Prometheus coleta dos pods.

### 1.4 Por que cada linha do Deployment importa (perguntas prováveis da banca)

- `replicas: 2` → exigência da atividade; também é o mínimo do HPA.
- `resources.requests.cpu: 100m` → **sem request não existe HPA** (ele calcula a % de uso *em relação ao request*). É também o valor contra o qual o cAdvisor/cadastram a "pressão" de CPU.
- `resources.limits.cpu: 250m` → teto de 250 milicores por pod; garante que um pod sob stress não devore o nó inteiro.
- `livenessProbe (/healthz, a cada 5s, falha após 2 tentativas)` → o gatilho da auto-recuperação do Experimento 2.
- `readinessProbe (/readyz)` → durante restarts, o pod fora do ar é removido do Service antes de morrer, então o `curl` da aplicação **nunca dá erro** durante as demos.
- `imagePullPolicy: IfNotPresent` → a imagem foi construída localmente dentro do Minikube (`eval $(minikube docker-env)` no setup); sem isso o K8s tentaria baixá-la de um registry e falharia.

### 1.5 Por que o HPA usa 50% e os números que você vai citar

- O pod tem request de 100m. O HPA tenta manter o **uso médio em 50% de 100m = 50 milicores**. Quando a média passa disso, ele aplica a fórmula `replicasDesejadas = ceil(replicas × usoAtual / 50)` — ex.: 2 pods a 90% → `ceil(2 × 90/50) = 4`.
- `maxReplicas: 5` é o "quantidade máxima de pods" que o relatório pede.
- No `behavior`, o *scale-down* tem `stabilizationWindowSeconds: 60`: após tirar a carga, o HPA espera um minuto antes de reduzir — por isso o gráfico mostra um platô na descida. **Cite isso no vídeo, professor adora.**
- O HPA reavalia as métricas a cada ~15s (padrão do `--horizontal-pod-autoscaler-sync-period`), e o Prometheus coleta a cada 5s — as curvas do gráfico mostram esses passos.

### 1.6 As três fontes de métricas do Prometheus (e o que cada uma cobre no relatório)

| Fonte (job) | O que fornece | Requisito da atividade que cobre |
|---|---|---|
| `meteo-api` (scrape dos pods via annotations) | `meteoapi_http_requests_total`, latências | métricas da aplicação |
| `kube-state-metrics` | `kube_pod_status_phase`, `kube_pod_container_status_restarts_total`, `kube_horizontalpodautoscaler_status_*`, `kube_deployment_status_replicas_*` | nº de pods ativos, estado dos pods, reinicializações, alterações do HPA |
| `cadvisor` (via kubelet) | `container_cpu_usage_seconds_total` | uso de CPU real dos containers |

### 1.7 Experimento 1 vs Experimento 2 — a distinção que o professor quer ouvir

| | Exp. 1 — Delete pod | Exp. 2 — Falha no container |
|---|---|---|
| Quem detecta | Deployment/ReplicaSet (o pod sumiu) | kubelet (livenessProbe falhou) |
| O que o K8s faz | Cria um **pod novo** (novo nome, novo IP) | **Reinicia o container** dentro do mesmo pod |
| Velocidade | Mais lento (scheduler + etcd + registro) | Mais rápido (nada de agendamento) |
| Identidade | Muda tudo | Mantém nome, IP, volume do pod |
| Métrica | `kube_pod_status_phase` (2→1→2) | `kube_pod_container_status_restarts_total` (0→1) |

Analogia para usar no vídeo: *"Reiniciar o container é trocar o motor do carro parado na garagem; recriar o pod é chamar um carro novo do pátio — mesma frota, placa nova."*

### 1.8 Experimento 4 — o conceito em uma frase

O Prometheus é um **observador passivo** (faz *pull*/scrape, não está no caminho das requisições). Derrubá-lo apaga a *visibilidade*, não o *serviço*. É o princípio do **baixo acoplamento**: monitoramento e aplicação falham de forma independente. (E o inverso também vale: se a aplicação cair, o Prometheus continua de pé para te contar o que aconteceu.)

---

## Parte 2 — Roteiro do vídeo (5 minutos, cronometrado)

> Dica de gravação: deixe **3 janelas lado a lado** antes de começar:
> (A) terminal com os scripts, (B) Prometheus em `localhost:9090/graph`, (C) um `watch kubectl get pods -l app=meteo-api`.
> Rode `./scripts/00-setup.sh` ANTES de ligar a câmera e confirme que os 2 pods estão `Running`.

### [0:00–0:30] Abertura e ambiente (30s)

Fale mostrando o terminal:
> "Trabalho da Atividade 4: tolerância a falhas e monitoramento. A aplicação é um serviço de previsão do tempo em Node.js, implantado no Minikube com 2 réplicas, requests e limits de CPU, liveness probe e HPA de 2 a 5 réplicas. O monitoramento é Prometheus + kube-state-metrics."

**Mostre:** `kubectl get pods` (2 pods Running) e `kubectl get hpa` (alvo 50%, min 2/max 5). *(Print 1 do relatório.)*

### [0:30–1:30] Experimento 1 — Deleção de pod (60s)

```bash
./scripts/01-exp1-delete-pod.sh
```

- Mostre o pod deletado sumindo da lista e o novo aparecendo (`ContainerCreating` → `Running`).
- O script imprime o **tempo de recuperação** — anote, será dito no vídeo.
- No Prometheus (janela B), cole: `sum(kube_pod_status_phase{pod=~"meteo-api.*"}) by (phase)` e mostre o vale 2→1→2 no gráfico.

**Fale:** "O ReplicaSet detectou a perda e criou um pod novo; recuperação em X segundos."

### [1:30–2:30] Experimento 2 — Falha no container (60s)

```bash
./scripts/02-exp2-container-failure.sh
```

- Mostre o RESTARTS mudar de 0 para 1 no `watch`/script.
- Prometheus: `sum(increase(kube_pod_container_status_restarts_total{pod=~"meteo-api.*"}[10m])) by (pod)`.
- **Fale a diferença:** "Aqui o kubelet reiniciou o *container* dentro do mesmo pod — mais rápido, mantém nome e IP. No experimento 1 o pod foi *recriado*: pod novo, IP novo. Reiniciar container é trocar o motor; recriar o pod é trocar o carro."

### [2:30–3:40] Experimento 3 — HPA em ação (70s)

```bash
./scripts/03-exp3-hpa-load.sh
```

- Mostre o `kubectl get hpa` subindo: TARGET passa de 50%, REPLICAS vai 2→3→4→5.
- Destaque o **máximo de 5** ("quantidade máxima de pods").
- Prometheus: `sum(rate(container_cpu_usage_seconds_total{pod=~"meteo-api.*"}[1m])) by (pod)` + `kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler="meteo-api"}`.
- Remova a carga quando o script pedir e mostre o scale-down (cite a janela de estabilização de 60s).
- Anote o **tempo de escalonamento** impresso pelo script.

### [3:40–4:30] Experimento 4 — Prometheus fora do ar (50s)

```bash
./scripts/04-exp4-prometheus-down.sh
```

- Mostre o `curl` devolvendo HTTP 200 **com o Prometheus derrubado**.
- Reinicie e mostre os targets voltando a UP (`Status → Targets` na UI).
- **Fale:** "O Prometheus é um observador passivo — coleta métricas, não participa do caminho das requisições. Falha no monitoramento não é falha na aplicação: baixo acoplamento."

### [4:30–5:00] Fechamento (30s)

> "Em resumo: o Kubernetes se recuperou de dois tipos de falha — pod perdido e container travado —, escalou horizontalmente sob carga com teto de 5 réplicas, e a aplicação permaneceu disponível mesmo com o monitoramento fora do ar. O relatório com todas as evidências e tempos medidos está no PDF. Obrigado!"

---

## Parte 3 — Checklist de evidências para o relatório (4–6 páginas)

Sugestão de estrutura do PDF (cada print com **legenda explicativa**):

1. **Capítulo ambiente** — print `minikube status` + `kubectl get nodes`; versões (`kubectl version --short`).
2. **Configuração** — trecho do `app-deployment.yaml` (requests/limits/probes) + do HPA; prints `kubectl get deploy`, `kubectl get hpa`, `kubectl top pods`.
3. **Exp. 1** — print ANTES (`get pods`), DURANTE (`ContainerCreating` visível), DEPOIS (2/2 Running) + print do gráfico Prometheus com o vale + **tempo de recuperação**.
4. **Exp. 2** — print do `kubectl exec` armando a falha, print do RESTARTS 0→1, print do gráfico de restarts + explicação pod vs container.
5. **Exp. 3** — print `kubectl get hpa` com TARGET alto, print pods escalados (5/5), print gráfico CPU + réplicas, **tempo de escalonamento**, print do scale-down.
6. **Exp. 4** — print `scale --replicas=0` + curl 200 durante a interrupção, print targets DOWN e depois UP, explicação observador passivo.
7. **Análise final** — tabela dos tempos medidos + 3 conclusões (auto-recuperação, escalonamento, desacoplamento) + **link do YouTube** na primeira página.

Comandos que rendem bons prints extras:

```bash
kubectl get hpa meteo-api -w                 # HPA em tempo real
kubectl top pods                             # consumo por pod
kubectl describe hpa meteo-api               # eventos de escala
kubectl get events --sort-by=.lastTimestamp  # linha do tempo do cluster
```

---

## Parte 4 — Problemas comuns (e a saída de emergência)

| Sintoma | Causa provável | Solução |
|---|---|---|
| Pods em `ErrImagePull` | Imagem não existe dentro do Minikube | `eval $(minikube docker-env)` e `docker build -t meteo-api:1.0 ./app` de novo |
| HPA mostra `<unknown>/50%` | Metrics-server ausente ou sem requests de CPU | `minikube addons enable metrics-server`; confirme os `requests` no Deployment |
| HPA não escala | Carga insuficiente | Suba 2º load-generator ou troque `spin=1` por chamadas em mais pods |
| `minikube service` não abre | Porta ocupada | Use `kubectl port-forward svc/prometheus -n monitoring 9090:9090` |
| Exp. 2 não reinicia | Falha desarmada de outra sessão | `kubectl exec <pod> -- wget -qO- localhost:8080/fail?on=0` e repita |
| Cluster lento no vídeo | Minikube com poucos recursos | `minikube start --cpus=2 --memory=4096` |

**Plano B para o vídeo:** se algo falhar ao vivo, rode o script de novo — todos são idempotentes (podem ser repetidos sem quebrar o estado).

---

## Parte 5 — Frases prontas (cola de narração)

- *"O livenessProbe permite ao kubelet detectar um processo travado e reiniciar o container automaticamente."*
- *"O HPA calcula as réplicas desejadas dividindo o uso observado pelo alvo de 50% do request de CPU."*
- *"O scale-down demora um pouco por causa da janela de estabilização, que evita oscilação — flapping."*
- *"Derrubar o Prometheus não afeta a aplicação porque ele só faz scrape — é pull, não push, e não integra o caminho crítico."*
- *"Tolerância a falhas aqui é reativa (self-healing) e adaptativa (autoscaling), duas faces do mesmo princípio de autogerência."*
