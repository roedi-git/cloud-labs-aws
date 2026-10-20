# T03 – Kubernetes lokal, Registry und Serverless Container

Zwei Teile: In der Übung läuft PlaceFinder in einem lokalen Kubernetes-Cluster, den k3d im Dev Container anlegt. In der Selbstlernphase kommt das Image in Amazon ECR und läuft mit **Amazon ECS Express Mode** auf Fargate.

## Teil 1: Kubernetes lokal mit k3d (Übung)

**Kosten:** keine – alles läuft im Dev Container. Drei Nodes brauchen zusammen rund 1,5 bis 2 GB Arbeitsspeicher; unter WSL ggf. die Grenze in `.wslconfig` erhöhen.

| Skript | Aufgabe |
|---|---|
| `cluster-up.sh` | Cluster `pf` anlegen (1 Server, 2 Agents, k3s 1.36) oder wieder starten |
| `build-image.sh` | Image `placefinder:<version>` aus `../placefinder` bauen und in die Nodes laden; mit `--push` zusätzlich als `:<version>` und `:t03` nach ghcr.io (Teil 2; `--tag t05` für den Stand von Termin 5) |
| `cluster-down.sh` | Cluster löschen; die Images bleiben in Docker |

```bash
cd /workspaces/cloud-labs-aws/t03-container
./cluster-up.sh                         # beim ersten Mal 1–2 Minuten (k3s-Image laden)
./build-image.sh                        # placefinder:0.1.0, Version aus pyproject.toml
cd /workspaces/placefinder
kubectl apply --filename deploy/k8s/    # eigenes Manifest aus der Übung
kubectl get pods --output wide          # drei Pods, verteilt auf die Nodes
kubectl port-forward svc/placefinder 8000:80
```

Wie es weitergeht – neue Version ausrollen, Konfiguration ändern, Helm-Chart, Autoscaler – steht im README von PlaceFinder, Abschnitt *Kubernetes*. Die Musterlösung liegt im Tag `t03` von PlaceFinder: `git fetch upstream --tags`, dann `git diff t03 -- deploy/` (`upstream` einrichten: siehe [t02-vm](../t02-vm/README.md#container-und-compose)).

**Typische Probleme**

- `ErrImagePull` oder `ImagePullBackOff`: Das Image ist nicht in den Nodes. `./build-image.sh` nach `./cluster-up.sh` ausführen; Tag im Manifest und Version müssen übereinstimmen.
- Pods bleiben `Pending`: zu wenig Speicher, `kubectl describe pod <name>` zeigt den Grund.
- Nach einem Neubau des Dev Containers kennt `kubectl` den Cluster nicht mehr: `./cluster-up.sh` startet ihn und trägt ihn wieder ein.

Aufräumen nach der Selbstlernphase: `./cluster-down.sh`.

## Teil 2: Registry und ECS Express Mode (Selbstlernphase)

**Ziel:** Das PlaceFinder-Image liegt in Amazon ECR und läuft mit **Amazon ECS Express Mode** auf Fargate. Express Mode legt mit einem Aufruf Task Definition, Dienst, Application Load Balancer mit HTTPS-Zertifikat, Autoscaling und Logs an.

**Kosten:** Fargate-Task mit 0,25 vCPU und 512 MB ca. 0,01 USD pro Stunde, Load Balancer ca. 0,03 USD pro Stunde plus öffentliche IPv4-Adressen – zusammen etwa 1 USD pro Tag aus dem Guthaben. ECR: 500 MB im Free Tier. **Nach der Übung löschen.**

AWS App Runner nimmt seit 30. April 2026 keine neuen Kunden mehr an; AWS empfiehlt stattdessen ECS Express Mode.

### Voraussetzungen

- Docker im Dev Container
- Image `$PLACEFINDER_IMAGE:t03` auf ghcr.io: `./build-image.sh --push`, danach das Paket auf GitHub öffentlich machen (*Packages* → *placefinder* → *Package settings* → *Change visibility*). Das Skript prüft, ob das geklappt hat.
- Das Konto hat eine Default-VPC (Standard bei neuen Konten). Express Mode legt Load Balancer und Tasks dort an.

### Schritte

```bash
./push-image.sh                 # ECR-Repository anlegen, Image hochladen
./deploy.sh                     # Express-Mode-Dienst anlegen, auf /health warten
```

`push-image.sh` legt das Repository mit Schwachstellen-Scan beim Push und einer Lebenszyklusregel an, die nur die fünf neuesten Images behält. `deploy.sh` legt drei IAM-Rollen an: die Execution Role, mit der ECS das Image lädt und Logs schreibt, die Infrastructure Role, mit der Express Mode Load Balancer und Autoscaling verwaltet, und die Rolle `pf-<owner>-deployer` für den Aufruf selbst. Express Mode legt Log-Gruppe und Security Group mit den Zugangsdaten des Aufrufers an und lehnt dabei die Sitzung von `aws login` ab („The security token included in the request is invalid“). Das Skript übernimmt deshalb vorher die Deployer-Rolle; nur der eigene IAM-Benutzer darf sie übernehmen, und sie hat dieselben Rechte wie er.

Der erste Start dauert etwa fünf Minuten. Der Status lässt sich verfolgen mit:

```bash
aws ecs describe-express-gateway-service --service-arn <arn> --query service.status
```

### Prüfen

```bash
url=$(grep SERVICE_URL ../.state/t03.env | cut --delimiter = --fields 2)
curl "$url/health"
curl "$url/places?q=Erfurt"
aws ecr describe-image-scan-findings --repository-name pf-<owner>-placefinder --image-id imageTag=t03
```

In der ECS-Konsole unter *Clusters* → *default* sind Dienst, Tasks, Load Balancer und Logs zu sehen.

### Aufräumen

```bash
./destroy.sh     # Dienst (inkl. Load Balancer), Log-Gruppe, ECR-Repository, Rollen
```

Wer in Termin 5 weiterarbeiten will, kann den Dienst bis dahin stehen lassen – das kostet dann aber etwa 1 USD pro Tag.

### Fragen zum Weiterdenken

- Warum skaliert ECS Express Mode nicht auf null, Cloud Run und Azure Container Apps dagegen schon? Was bedeutet das für die Kosten?
- Welche Ressourcen hat Express Mode im Hintergrund angelegt (*EC2* → *Load Balancers*, *Target Groups*, *Security Groups*)?
- Wofür ist die Infrastructure Role nötig, und warum muss sie beim Löschen als Letztes entfernt werden?

## Andere Anbieter

| | AWS | Azure | Google Cloud |
|---|---|---|---|
| Registry | Amazon ECR | Azure Container Registry (hier: ghcr.io) | Artifact Registry |
| Serverless Container | ECS Express Mode auf Fargate | Azure Container Apps | Cloud Run |
| Skalierung auf null | nein | ja | ja |
