# Start the project locally

Using Windows with WSL2? Complete the [WSL2 setup](#wsl2-setup-windows--ubuntu)
at the bottom of this guide before starting the project.

The runnable parts are observability and a local Keycloak identity service. The Go
API, React frontend, PostgreSQL, and MinIO described in the README are still planned.

This setup runs three official Elastic containers in separate Kubernetes pods:

| Component | Purpose |
| --- | --- |
| Elasticsearch | Store and search logs and telemetry |
| Kibana | Explore data and view dashboards |
| APM Server | Receive application traces, errors, and application metrics |

Elastic Cloud on Kubernetes (ECK) manages connections, passwords, and HTTPS
certificates. No custom Docker image or build is needed. This is a small local
setup with one instance of each component, intended for development.
Keycloak log shipping is included in section 7. Cluster metrics collection,
alerts, and application instrumentation will be added as services are implemented.

## Single-command startup

After completing the [WSL2 prerequisites](#wsl2-setup-windows--ubuntu), start Docker Desktop, open an
**Ubuntu Bash** terminal, and run from the project root:

```bash
bash scripts/start.sh
```

This starts/resumes the `webappsec` Minikube profile, installs ECK 3.5.0, deploys
Elastic, Filebeat, and Keycloak, and waits for their workloads to be ready. On the
first run, it prompts for a nonempty Keycloak admin password without echoing it.
Later runs reuse the existing Secret and persistent databases. It always targets
this project's `webappsec` context and can also be invoked by its absolute path
from another directory.

The script forwards **https://localhost:5601** (Kibana) and
**http://localhost:8080/admin/** (Keycloak). Open those addresses in your Windows
browser. Leave the terminal running; **Ctrl+C** closes both forwards while keeping
the cluster and its data. It prints the command to retrieve the Kibana password;
use the Keycloak password you entered on first startup. Local ports 5601 and 8080
must be free; close earlier port-forward commands before using the script.

To deploy without keeping port forwards running:

```bash
bash scripts/start.sh --no-forward
```

To pause the cluster after closing the forwards:

```bash
minikube stop --profile webappsec
```

Run the startup script again to resume. The script needs the tools and resources
listed in the WSL2 setup, internet access, and admin access to its local cluster.
It does not install Windows/WSL prerequisites. If startup fails, it stops and prints
the failing step; the manual instructions and troubleshooting below remain useful.
Readiness waits allow up to ten minutes per workload for first-time image pulls.
See section 7 to verify Keycloak logs in Kibana.

## 1. Prepare Kubernetes

Run commands from this repository's root in **Bash**, for example Ubuntu WSL.
Install kubectl and Minikube and have a Docker engine running and accessible from
that terminal. Internet access is needed for the operator, images, and APM package.

If you do not already have a local cluster:

```bash
minikube start --profile webappsec --driver=docker --cpus=4 --memory=8192
kubectl config use-context webappsec
```

Allocate about 8 GiB RAM and 4 CPUs to the cluster, plus disk space for images and
data. An existing kind or other local cluster works too if it has enough resources
and a default StorageClass. Check your target:

```bash
kubectl config current-context
kubectl get nodes
kubectl get storageclass
```

One StorageClass should be marked `(default)`. Elasticsearch requests a 5 GiB
persistent volume. Use a local cluster with admin permissions: ECK installs
cluster-wide resource definitions and RBAC.

## 2. Install ECK (once per cluster)

```bash
kubectl create -f https://download.elastic.co/downloads/eck/3.5.0/crds.yaml
kubectl apply -f https://download.elastic.co/downloads/eck/3.5.0/operator.yaml
kubectl -n elastic-system rollout status statefulset/elastic-operator --timeout=300s
```

If the CRDs already exist, skip the first command. ECK is pinned to 3.5.0 and
container versions to 9.5.4. The APM integration uses `latest`, following Elastic's
quickstart; Kibana needs internet access to Elastic's package registry to install it.

## 3. Start observability

```bash
kubectl apply -f k8s/observability/namespace.yaml
kubectl apply -f k8s/observability/stack.yaml
kubectl -n observability get elasticsearch,kibana,apmserver
kubectl -n observability get pods
```

First startup takes several minutes. Repeat the last two commands until all three
pods show `1/1` ready and the Elastic resources report green health. If pods do not
exist yet, give the operator time to create them. Applying the same files again
updates the setup. Elasticsearch data survives pod restarts on its volume.

## 4. Open Kibana

Keep this running in another terminal:

```bash
kubectl -n observability port-forward service/elastic-kb-http 5601:5601
```

Open **https://localhost:5601**. Acknowledge the browser's self-signed certificate
warning for this local instance. Log in as `elastic` with the generated password:

```bash
kubectl -n observability get secret elastic-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 --decode
printf '\n'
```

If using Windows PowerShell instead of Bash, decode the password with:

```powershell
$encodedPassword = kubectl -n observability get secret elastic-es-elastic-user -o 'jsonpath={.data.elastic}'
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedPassword))
```

The `elastic` account is an administrator for local setup. Future application
services should use restricted credentials. Services are internal to the cluster;
port forwarding binds to localhost by default.

## 5. Verify with a sample security log

Find **Dev Tools > Console** in Kibana using the navigation search. Run these
requests in order. The template sets zero replicas for our single node and maps
the timestamp as a date:

```http
PUT _index_template/webappsec-logs
{
  "index_patterns": ["logs-webappsec-*"],
  "template": {
    "settings": { "number_of_shards": 1, "number_of_replicas": 0 },
    "mappings": {
      "properties": { "@timestamp": { "type": "date" } }
    }
  }
}

POST logs-webappsec-local/_doc?refresh=true
{
  "@timestamp": "2026-10-07T10:00:00Z",
  "service.name": "authentication",
  "log.level": "WARN",
  "event.action": "login",
  "event.outcome": "failure",
  "user.id": "demo-user",
  "message": "Local observability smoke test: login rejected"
}

GET logs-webappsec-local/_search
```

The POST should return `"result": "created"` and the search should contain the
event. Replace the timestamp with the current UTC time when adding new events.

Find **Data Views** in Kibana. Create `WebAppSec logs` using index pattern
`logs-webappsec-*` and timestamp field `@timestamp`. Open **Discover**, select
that view, and set an absolute time range including October 7, 2026 (or your
replacement timestamp). Search for:

```text
event.outcome: "failure"
```

Future services should log actions, outcomes, resource IDs, and safe user IDs.
Never log passwords, cookies, session tokens, encryption keys, or plaintext file
contents. This example verifies storage and search; it does not configure alerts.

## 6. APM for future Go services

The APM endpoint inside Kubernetes is:

```text
https://elastic-apm-http.observability.svc:8200
```

ECK creates the secret token in `elastic-apm-token` under key `secret-token` and
the certificate in `elastic-apm-http-certs-public` under key `tls.crt`. Mount these
into future service pods using Kubernetes Secret references. Configure the Go APM
agent with `ELASTIC_APM_SERVICE_NAME`, `ELASTIC_APM_SERVER_URL`,
`ELASTIC_APM_SECRET_TOKEN`, and `ELASTIC_APM_SERVER_CERT` (the mounted certificate
path). Add instrumentation to the application before expecting traces in Kibana.

## 7. Start Keycloak and view its logs in Kibana

Complete sections 1-4 first. On WSL2, run the commands below in **Ubuntu Bash**.
The log flow is **Keycloak stdout > Filebeat > Elasticsearch > Kibana**.

Keycloak uses the pinned official image `quay.io/keycloak/keycloak:26.8.0`, one
replica, and an embedded H2 database on a 1 GiB persistent volume. It runs in
`start-dev` mode over local HTTP for this initial setup. The planned application
HTTPS/OIDC configuration and PostgreSQL-backed Keycloak deployment are future
work; keep this instance local. No application OIDC clients or users are created.

### Create the namespace and admin Secret

```bash
kubectl apply -f k8s/keycloak/namespace.yaml

# Enter a strong local admin password; input is hidden and not stored in Git.
read -rsp 'Keycloak admin password: ' KEYCLOAK_ADMIN_PASSWORD
printf '\n'
printf '%s' "$KEYCLOAK_ADMIN_PASSWORD" | kubectl -n webappsec create secret generic keycloak-admin \
  --from-literal=username=admin --from-file=password=/dev/stdin
unset KEYCLOAK_ADMIN_PASSWORD
```

Do not use an empty password. Create this Secret once; on later starts, skip the
password commands if it exists. Bootstrap credentials only create the first admin
on an empty database. Changing the Secret later does not change that admin's
password; change it through Keycloak instead.

### Deploy the collector and Keycloak

```bash
kubectl apply -f k8s/observability/keycloak-logs.yaml
kubectl apply -f k8s/keycloak/keycloak.yaml
kubectl -n webappsec rollout status deployment/keycloak --timeout=300s
kubectl -n observability get beat keycloak-logs
kubectl -n observability get pods -l beat.k8s.elastic.co/name=keycloak-logs
kubectl -n webappsec logs deployment/keycloak --tail=30
```

Filebeat runs once per node and reads only the log path matching the Keycloak
container in `webappsec`. It parses the container envelope and Keycloak's ECS JSON
into searchable fields. ECK supplies Elasticsearch credentials and CA trust; no
Elastic password is copied into the Keycloak manifest. The collector reads host
log directories as root, with read-only mounts, and does not require Kubernetes
API permissions. This assumes the standard Linux node log paths used by
Minikube/kind. Filebeat's read offsets persist on each node to reduce replay after
collector restarts. Its data uses the default `filebeat-*` index/data stream.

### Open Keycloak

Keep this command running in another Ubuntu terminal:

```bash
kubectl -n webappsec port-forward service/keycloak 8080:8080
```

Open **http://localhost:8080/admin/** in your Windows browser (or local browser on
Linux). Log in as `admin` with the password you entered. A `webappsec` realm is
imported automatically. Select it in the realm dropdown. The import enables the
`jboss-logging` event listener and stores user events for one day; admin event
logging and admin event payloads are disabled. Existing realms are skipped on
subsequent startup imports, so later realm changes must be made in the console.

### Verify real logs in Kibana

In Kibana, find **Data Views** and create `Keycloak logs` with index pattern
`filebeat-*` and time field `@timestamp`. Then open **Discover**, select that view,
use **Last 15 minutes**, and search:

```text
service.name: "keycloak"
```

You should see startup messages. To generate a security event, open
**http://localhost:8080/realms/webappsec/account/**, choose **Sign in** if needed,
and try a nonexistent username such as `observability-demo` with a dummy password.
The rejected login is logged by the realm's event listener. Refresh Discover and
search:

```text
service.name: "keycloak" and message: "LOGIN_ERROR"
```

Allow a short delay for collection. Successful login events use Keycloak's default
listener level (DEBUG) and are not included at INFO; failed login events are WARN
and are included. Keycloak events may contain usernames, IP addresses, and other
authentication metadata: use dummy test accounts and do not enable request bodies
or verbose debug logging. The collector preserves Keycloak's message; it does not
convert login event text into separate `event.action` or `event.outcome` fields.

If logs do not appear, check:

```bash
kubectl -n webappsec get pods,pvc
kubectl -n webappsec logs deployment/keycloak --tail=50
kubectl -n observability get beat keycloak-logs
kubectl -n observability logs -l beat.k8s.elastic.co/name=keycloak-logs -c filebeat --tail=100
```

- Missing admin Secret causes `CreateContainerConfigError`; create the Secret.
- Pending Keycloak PVC requires a default StorageClass.
- Image pulls need access to `quay.io` as well as `docker.elastic.co`.
- For Filebeat errors, check Elasticsearch health, host log paths, and read
  permissions. Some initial image-build messages may be plain text and produce a
  JSON parse error field; JSON server/event messages should still be collected.
- If `filebeat-*` does not exist yet, wait for Filebeat to send its first events.
- If a failed login produces no event, check **Realm settings > Events > Event
  listeners** in `webappsec` and confirm `jboss-logging` is selected. Imported
  configuration is not reapplied to an existing realm.

### Remove Keycloak

To remove Keycloak and **delete its database, realms, users, and admin Secret**:

```bash
kubectl delete -f k8s/observability/keycloak-logs.yaml
kubectl delete -f k8s/keycloak/keycloak.yaml
kubectl delete -f k8s/keycloak/namespace.yaml
```

Previously indexed logs stay in Elasticsearch until its data is removed. The
collector's small offset registry remains on the Kubernetes nodes and is removed
when the local cluster is deleted.

## Troubleshooting

```bash
kubectl -n observability get pods,pvc,services
kubectl -n observability get events --sort-by=.metadata.creationTimestamp
kubectl -n observability describe pod elastic-es-default-0
kubectl -n observability logs elastic-es-default-0 -c elasticsearch --tail=100
kubectl -n elastic-system logs statefulset/elastic-operator --tail=100
```

- **Pending pod/PVC:** check available memory and the default StorageClass.
- **ImagePullBackOff:** check internet access to `docker.elastic.co`.
- **APM not ready:** wait for Elasticsearch and Kibana, then check Kibana/APM pod
  logs. Installing the APM package needs access to `epr.elastic.co`.
- **Port in use:** forward `5602:5601` instead and open `https://localhost:5602`.
- **Yellow Elasticsearch:** replicas cannot allocate on one node. The sample log
  template has zero replicas; other integrations may create indices with replicas.

## Stop or reset

Stop port forwarding with Ctrl+C. Pause Minikube and keep data:

```bash
minikube stop --profile webappsec
```

Resume with `minikube start --profile webappsec` and restart port forwarding.

Remove the Keycloak log collector first if you installed section 7. To remove
the observability stack and **delete its stored telemetry**:

```bash
kubectl delete -f k8s/observability/stack.yaml
kubectl delete -f k8s/observability/namespace.yaml
```

ECK stays installed for reuse. Do not delete shared CRDs/operator if another stack
uses them. Deleting the Minikube profile also destroys its local cluster data.

## References

- [Install ECK](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s/install-using-yaml-manifest-quickstart)
- [Elasticsearch quickstart](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s/elasticsearch-deployment-quickstart)
- [Kibana quickstart](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s/kibana-instance-quickstart)
- [APM with ECK](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s/use-an-elasticsearch-cluster-managed-by-eck)

- [Keycloak containers](https://www.keycloak.org/server/containers)
- [Keycloak console logging](https://www.keycloak.org/server/logging/console)
- [Filebeat on Kubernetes](https://www.elastic.co/docs/reference/beats/filebeat/running-on-kubernetes)

## WSL2 setup (Windows + Ubuntu)

Complete these steps before section 1. Use **Windows PowerShell** only where
specified; run Docker, Minikube, and kubectl commands in **Ubuntu Bash**.

### A. Check WSL2 in Windows PowerShell

```powershell
wsl --update
wsl --list --verbose
```

Your Ubuntu distribution should show `VERSION 2`. If it shows `1`, convert it:

```powershell
wsl --set-version Ubuntu-26.04 2
```

Replace `Ubuntu-26.04` with the exact name from the list. If Ubuntu is not
installed yet, run `wsl --install -d Ubuntu`, restart Windows if prompted, and
complete Ubuntu's username/password setup.

### B. Connect Docker Desktop to Ubuntu

Install [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/)
if needed, then start it. In Docker Desktop:

1. Under **Settings > General**, enable **Use the WSL 2 based engine** if shown.
2. Under **Settings > Resources > WSL Integration**, enable your Ubuntu
   distribution, such as `Ubuntu-26.04`, and apply the changes.
3. Use Linux containers. If WSL Integration is missing, switch Docker Desktop
   to Linux containers from its tray menu.

This guide uses Docker Desktop as the engine. You do not need to install a second
Docker Engine inside Ubuntu or enable Docker Desktop's built-in Kubernetes.
See [Docker's WSL instructions](https://docs.docker.com/desktop/features/wsl/).

Open Ubuntu from Windows Terminal, or enter it from PowerShell:

```powershell
wsl -d Ubuntu-26.04
```

In **Ubuntu Bash**, verify that Docker's client and server are accessible:

```bash
docker version
docker run --rm hello-world
```

If `docker` is missing or cannot connect, check that Docker Desktop is running
and integration is enabled for this exact distribution, then reopen Ubuntu.

### C. Check WSL memory and CPUs

In **Ubuntu Bash**:

```bash
free -h
nproc
```

WSL/Docker must have more than the 8 GiB requested by Minikube, with room for
Ubuntu and Docker, and at least 4 CPUs. If WSL's limits are too low and your PC has
sufficient resources, edit `%UserProfile%\.wslconfig` in **Windows**, preserving
any existing settings. For example, on a PC with enough RAM and CPU cores:

```ini
[wsl2]
memory=12GB
processors=4
localhostForwarding=true
```

Leave RAM available for Windows; the example is not suitable for an 8 GiB PC.
After saving, close running WSL work, quit Docker Desktop, and run in PowerShell:

```powershell
wsl --shutdown
```

This stops all WSL distributions. Restart Docker Desktop and reopen Ubuntu.
See [Microsoft's WSL configuration reference](https://learn.microsoft.com/en-us/windows/wsl/wsl-config).

### D. Install Linux kubectl and Minikube in Ubuntu

Skip installing a tool if its version command already works. Keep both tools in
Ubuntu so they use the same Linux Kubernetes configuration.

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates

# Choose the Linux binary matching the WSL CPU architecture.
case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) echo "Unsupported architecture"; return 1 2>/dev/null || exit 1 ;;
esac

# kubectl: download and verify its checksum before installing.
kubectl_version=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fLO "https://dl.k8s.io/release/${kubectl_version}/bin/linux/${arch}/kubectl"
curl -fLO "https://dl.k8s.io/release/${kubectl_version}/bin/linux/${arch}/kubectl.sha256"
printf '%s  kubectl\n' "$(cat kubectl.sha256)" | sha256sum --check
# Continue only if the checksum reports OK.
sudo install -m 0755 kubectl /usr/local/bin/kubectl

# Minikube: install the Linux binary.
curl -fL -o minikube-linux "https://github.com/kubernetes/minikube/releases/latest/download/minikube-linux-${arch}"
sudo install -m 0755 minikube-linux /usr/local/bin/minikube

kubectl version --client
minikube version
```

Installation references: [kubectl on Linux](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)
and [Minikube installation](https://minikube.sigs.k8s.io/docs/start/).

### E. Open this project and continue

In **Ubuntu Bash**, use the Linux project path:

```bash
cd /home/jan/WebAppSecCourse
ls START.MD k8s/observability/stack.yaml
```

Replace `/home/jan` if your username/location differs. The Windows path
`\\wsl.localhost\Ubuntu-26.04\home\jan\WebAppSecCourse` refers to the same directory.
Keep the repository in Ubuntu's filesystem for this workflow.

Use `bash scripts/start.sh` for automatic startup, or continue manually with
**section 1**, including `minikube start` and selecting the
`webappsec` context. Run Minikube as your normal Ubuntu user, without `sudo`.
A missing kubectl context before creating the cluster is expected.

For **section 4**, run `kubectl port-forward` in an Ubuntu terminal and leave it
open, then open `https://localhost:5601` in your **Windows browser**. Use this
forwarded address; the Minikube node IP is not directly reachable from Windows
with the Docker driver. See [Minikube's WSL2 guide](https://minikube.sigs.k8s.io/docs/tutorials/wsl_docker_driver/).
If the browser cannot connect, check the port-forward terminal for errors and
check that WSL localhost forwarding is enabled. After restarting WSL or Docker,
start Minikube again and restart port forwarding.
