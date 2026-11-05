# SonarQube lab no GCP (Terraform) com GitHub Actions

Cenário de treinamento no projeto GCP `tbx-gabriel-simoes` (Lab Toolbox): VM SonarQube criada via Terraform, app Hello World em Docker e pipeline no GitHub Actions que roda testes e envia o relatório ao SonarQube.

## Sumário

0. Pré-requisitos no WSL
1. Bucket de state remoto
2. Estrutura do repositório
3. App Hello World
4. Terraform (VM SonarQube)
5. Apply
6. Bootstrap do SonarQube (senha, token e secrets)
7. Pipeline no GitHub Actions
8. Rodar e validar
9. Cenário de treinamento
10. Custo e limpeza
11. Mapeamento com o Definition of Done

---

## Visão geral

```
git push ─► GitHub Actions ─► pytest + coverage ─► sonar-scanner ──HTTP :9000──► VM sonarqube-lab (GCP)
                         └──► docker build (Hello World)                          ├─ SonarQube Community (container)
                                                                                   └─ PostgreSQL 16 (container)
```

### Decisão de rede (define o resto do desenho)

Os runners hospedados do GitHub têm IP dinâmico, então não dá para liberar o firewall só para eles. Opções:

| Opção | Prós | Contras |
|---|---|---|
| Liberar `:9000` para `0.0.0.0/0` | Simples, funciona com `ubuntu-latest` | Exposto à internet, e o token trafega em HTTP |
| Self-hosted runner na mesma VPC | Sonar fica fechado, acesso por IP interno | Mais uma VM para manter |
| Liberar só o seu IP | Seguro | O pipeline do GitHub não alcança o Sonar |

Neste guia uso a variável `allowed_cidrs`. Para o lab, deixe `0.0.0.0/0` (ou os ranges do GitHub) e use senha forte. Para algo mais sério, migre para o self-hosted runner ou ponha HTTPS na frente.

---

## Etapa 0: Pré-requisitos no WSL

```bash
gcloud auth login
gcloud auth application-default login   # o Terraform usa ADC, não o login normal do gcloud
gcloud config set project tbx-gabriel-simoes
sudo apt install gh jq -y
gh auth login                           # o bootstrap usa gh para gravar os secrets
terraform -version && jq --version && gh --version
```

**Por quê:** `gcloud auth login` e ADC são credenciais separadas. Sem o `application-default`, o `terraform plan` falha com erro de credencial, mesmo com o gcloud logado.

Você precisa de permissão para criar Compute, Service Account, IAM binding e bucket no projeto. Se algum `apply` falhar por org policy (IP externo proibido, shielded VM obrigatório etc.), confira as constraints do lab antes de mexer no código.

---

## Etapa 1: Bucket de state remoto

```bash
PROJECT_ID=tbx-gabriel-simoes
REGION=southamerica-east1

gcloud storage buckets create "gs://${PROJECT_ID}-tfstate" \
  --project="$PROJECT_ID" --location="$REGION" --uniform-bucket-level-access
gcloud storage buckets update "gs://${PROJECT_ID}-tfstate" --versioning
```

**Por quê:** o state contém a senha do Postgres gerada pelo Terraform. Local, ele vira um arquivo sensível solto na máquina. No GCS fica versionado, com IAM, e outras pessoas do treinamento podem reutilizar o repo. Criamos o bucket por CLI porque o Terraform não consegue criar o próprio backend.

---

## Etapa 2: Estrutura do repositório

```
sonar-lab/
├── .github/workflows/ci-sonar.yml
├── app/            (__init__.py, main.py)
├── tests/          (test_main.py)
├── terraform/      (versions.tf, variables.tf, main.tf, outputs.tf, terraform.tfvars, scripts/startup.sh.tpl)
├── scripts/bootstrap-sonar.sh
├── Dockerfile
├── requirements.txt / requirements-dev.txt / pytest.ini
└── sonar-project.properties
```

---

## Etapa 3: App Hello World

**Por quê Python/Flask:** é pequeno, o Sonar analisa Python bem e o `pytest-cov` gera o `coverage.xml` que o Sonar lê. Assim o treinamento mostra cobertura de teste e não só análise estática.

`app/__init__.py` fica vazio.

`app/main.py`:

```python
from flask import Flask, jsonify

app = Flask(__name__)


@app.get("/")
def hello():
    return jsonify(message="Hello, World!")


@app.get("/health")
def health():
    return jsonify(status="ok")
```

`tests/test_main.py`:

```python
from app.main import app


def test_hello():
    resp = app.test_client().get("/")
    assert resp.status_code == 200
    assert resp.get_json() == {"message": "Hello, World!"}


def test_health():
    resp = app.test_client().get("/health")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}
```

`pytest.ini` (sem o `pythonpath`, o pytest não acha o pacote `app`):

```ini
[pytest]
pythonpath = .
testpaths = tests
```

`requirements.txt`:

```
flask>=3.0,<4
gunicorn>=22
```

`requirements-dev.txt`:

```
pytest>=8
pytest-cov>=5
```

`Dockerfile`:

```dockerfile
FROM python:3.12-slim
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ ./app/
USER nobody
EXPOSE 8080
CMD ["gunicorn", "-b", "0.0.0.0:8080", "app.main:app"]
```

`sonar-project.properties`:

```properties
sonar.projectKey=hello-sonar-lab
sonar.projectName=Hello Sonar Lab
sonar.sources=app
sonar.tests=tests
sonar.python.version=3.12
sonar.python.coverage.reportPaths=coverage.xml
sonar.sourceEncoding=UTF-8
```

`.gitignore`:

```
__pycache__/
.pytest_cache/
coverage.xml
.venv/
terraform/.terraform/
terraform/*.tfstate*
terraform/terraform.tfvars
terraform/tfplan
```

Teste local antes de seguir:

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt -r requirements-dev.txt
pytest --cov=app --cov-report=xml:coverage.xml --cov-report=term
docker build -t hello-sonar:local .
```

---

## Etapa 4: Terraform (VM SonarQube)

**O que será criado e por quê:**

- **VPC e subnet dedicadas:** o lab não depende da `default`, que pode não existir ou ter regras permissivas.
- **IP estático:** a URL do Sonar não muda se a VM reiniciar. O `SONAR_HOST_URL` do GitHub fica estável.
- **Firewall `:9000` (restrito por `allowed_cidrs`) e SSH só via IAP:** a porta 22 fica fechada para a internet e você entra com `--tunnel-through-iap`.
- **Service Account própria com roles mínimas:** a VM não usa a SA default do Compute, que costuma ter Editor.
- **Startup script instalando Docker e subindo Sonar + Postgres via compose:** a VM nasce pronta, sem passo manual.

`terraform/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }

  backend "gcs" {
    bucket = "tbx-gabriel-simoes-tfstate"
    prefix = "sonar-lab"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
```

`terraform/variables.tf`:

```hcl
variable "project_id" {
  type    = string
  default = "tbx-gabriel-simoes"
}

variable "region" {
  type    = string
  default = "southamerica-east1"
}

variable "zone" {
  type    = string
  default = "southamerica-east1-b"
}

variable "machine_type" {
  type        = string
  default     = "e2-standard-2" # 8 GB RAM: SonarQube (web + CE + Elasticsearch embutido) fica folgado
  description = "e2-medium (4 GB) funciona, mas fica apertado durante análises"
}

variable "disk_size_gb" {
  type    = number
  default = 50
}

variable "sonar_image" {
  type        = string
  default     = "sonarqube:community"
  description = "Para estabilidade do treinamento, fixe uma versão (ex.: tag X.Y-community)"
}

variable "allowed_cidrs" {
  type        = list(string)
  description = "CIDRs com acesso a :9000. Sem default de propósito: exige decisão explícita."
}
```

`terraform/terraform.tfvars` (não commitar):

```hcl
# Lab com runners hospedados do GitHub = aberto. Troque por seu IP/32 para testes manuais.
allowed_cidrs = ["0.0.0.0/0"]
zone          = "southamerica-east1-a"
```

`terraform/main.tf`:

```hcl
locals {
  name = "sonarqube-lab"
  labels = {
    app        = "sonarqube"
    env        = "lab"
    managed_by = "terraform"
  }
}

# Habilita o Secret Manager, que será usado para armazenar a senha do Postgres usada pelo SonarQube.
resource "google_project_service" "secretmanager" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

# Cria um secret no Secret Manager para armazenar a senha do Postgres usada pelo SonarQube.
resource "google_secret_manager_secret" "postgres" {
  secret_id = "${local.name}-db-password"
  labels    = local.labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.secretmanager]
}

# Cria uma versão do secret no Secret Manager com a senha do Postgres gerada pelo recurso random_password.postgres.
resource "google_secret_manager_secret_version" "postgres" {
  secret      = google_secret_manager_secret.postgres.id
  secret_data = random_password.postgres.result
}

# Binding no SECRET (não no projeto): a SA da VM só lê este secret
resource "google_secret_manager_secret_iam_member" "vm_accessor" {
  secret_id = google_secret_manager_secret.postgres.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}

# o serviço de Compute Engine, que é necessário para criar VMs
resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

# random_password é usado para gerar a senha do Postgres, que será usada pelo SonarQube
resource "random_password" "postgres" {
  length  = 24
  special = false
}

# service_account é usado para criar uma conta de serviço que será usada pela VM do SonarQube
resource "google_service_account" "vm" {
  account_id   = "${local.name}-vm"
  display_name = "SonarQube lab VM"
}

# Permissões à conta de serviço da VM para escrever logs e métricas
resource "google_project_iam_member" "vm_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# Permissões à conta de serviço da VM para escrever métricas
resource "google_project_iam_member" "vm_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# Rede e sub-rede para a VM do SonarQube com depends_on para garantir que o serviço de Compute Engine esteja habilitado antes de criar a rede
resource "google_compute_network" "this" {
  name                    = "${local.name}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.compute]
}

# Sub-rede para a VM do SonarQube
# /24 sigifica que teremos 256 endereços IP disponíveis na sub-rede, o que é suficiente para uma VM de laboratório
resource "google_compute_subnetwork" "this" {
  name          = "${local.name}-subnet"
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = "10.10.0.0/24"
}

# Firewall para permitir tráfego HTTP na porta 9000
resource "google_compute_firewall" "sonar_http" {
  name          = "${local.name}-allow-9000"
  network       = google_compute_network.this.name
  direction     = "INGRESS"
  source_ranges = var.allowed_cidrs
  target_tags   = ["sonarqube"]

  allow {
    protocol = "tcp"
    ports    = ["9000"]
  }
}


# Firewall para permitir tráfego SSH na porta 22 apenas do range do IAP (Identity-Aware Proxy) do Google Cloud
resource "google_compute_firewall" "iap_ssh" {
  name          = "${local.name}-allow-iap-ssh"
  network       = google_compute_network.this.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["sonarqube"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Endereço IP estático para a VM do SonarQube
resource "google_compute_address" "sonarqube" {
  name       = "${local.name}-ip"
  region     = var.region
  depends_on = [google_project_service.compute]
}

# Criando a VM do SonarQube com a imagem do Ubuntu 24.04 LTS, tamanho de disco e tipo de máquina definidos nas variáveis
resource "google_compute_instance" "sonarqube" {
  name                      = local.name
  machine_type              = var.machine_type
  zone                      = var.zone
  tags                      = ["sonarqube"]
  labels                    = local.labels
  allow_stopping_for_update = true

# Define a imagem, tamanho do disco e o tipo de disco (pd-balanced).
  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.disk_size_gb
      type  = "pd-balanced"
    }
  }

# A interface de rede da VM é configurada para usar a sub-rede e o endereço IP estático.
# nat_ip é necessário para que a VM tenha um IP público e possa ser acessada de fora da rede do Google Cloud.
  network_interface {
    subnetwork = google_compute_subnetwork.this.id
    access_config {
      nat_ip = google_compute_address.sonarqube.address
    }
  }

# A conta de serviço da VM é configurada para ter acesso a todos os recursos do Google Cloud (cloud-platform) e é usada para autenticação e autorização.
  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

# A configuração de instância protegida é habilitada para aumentar a segurança da VM, incluindo inicialização segura, vTPM e monitoramento de integridade.
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

# A metadata da VM é configurada para habilitar o OS Login, que permite gerenciar o acesso SSH à VM usando contas do Google, e para executar um script de inicialização que configura o SonarQube e o PostgreSQL.
  metadata = {
    enable-oslogin = "TRUE"
    startup-script = templatefile("${path.module}/scripts/startup.sh.tpl", {
      project_id  = var.project_id
      secret_id   = google_secret_manager_secret.postgres.secret_id
      sonar_image = var.sonar_image
    })
  }

# O secret e a permissão precisam existir antes da VM bootar
  depends_on = [
    google_project_service.compute,
    google_secret_manager_secret_version.postgres,
    google_secret_manager_secret_iam_member.vm_accessor,
  ]
}
```

`terraform/scripts/startup.sh.tpl`:

```bash
#!/usr/bin/env bash
set -euo pipefail
exec > >(tee -a /var/log/sonar-startup.log) 2>&1

APP_DIR=/opt/sonarqube

# 1) Parâmetros de kernel exigidos pelo Elasticsearch embutido (idempotente)
cat > /etc/sysctl.d/99-sonarqube.conf <<'EOF'
vm.max_map_count=524288
fs.file-max=131072
EOF
sysctl --system

# 2) Dependências: jq (parse do JSON) e Docker (só instala se não existir)
apt-get update -y
apt-get install -y jq curl
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

# 3) Lê a senha do Postgres no Secret Manager via metadata server (sem gcloud)
TOKEN="$(curl -fsS -H 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' \
  | jq -r '.access_token')"

POSTGRES_PASSWORD=""
for i in $(seq 1 30); do
  POSTGRES_PASSWORD="$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/${secret_id}/versions/latest:access" \
    | jq -r '.payload.data' | base64 -d || true)"
  [[ -n "$POSTGRES_PASSWORD" ]] && break
  echo "Secret indisponível (tentativa $i), aguardando..."
  sleep 10
done
[[ -n "$POSTGRES_PASSWORD" ]] || { echo "Falha ao ler o secret" >&2; exit 1; }

# 4) Grava o .env (600, só root) e o docker-compose
mkdir -p "$APP_DIR"
umask 077
printf 'POSTGRES_PASSWORD=%s\n' "$POSTGRES_PASSWORD" > "$APP_DIR/.env"

# $${...} é escapado para o Terraform: o compose é quem resolve, a partir do .env
cat > "$APP_DIR/docker-compose.yml" <<'EOF'
services:
  db:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: sonar
      POSTGRES_PASSWORD: $${POSTGRES_PASSWORD}
      POSTGRES_DB: sonarqube
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U sonar -d sonarqube"]
      interval: 10s
      timeout: 5s
      retries: 10

  sonarqube:
    image: ${sonar_image}
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      SONAR_JDBC_URL: jdbc:postgresql://db:5432/sonarqube
      SONAR_JDBC_USERNAME: sonar
      SONAR_JDBC_PASSWORD: $${POSTGRES_PASSWORD}
    ports:
      - "9000:9000"
    volumes:
      - sonar_data:/opt/sonarqube/data
      - sonar_extensions:/opt/sonarqube/extensions
      - sonar_logs:/opt/sonarqube/logs

volumes:
  pgdata:
  sonar_data:
  sonar_extensions:
  sonar_logs:
EOF
chmod 600 "$APP_DIR/docker-compose.yml"

# 5) Sobe (idempotente)
docker compose --env-file "$APP_DIR/.env" -f "$APP_DIR/docker-compose.yml" up -d
```

**Por quê da parte de kernel:** o Sonar embute um Elasticsearch que se recusa a subir sem limites altos no host. A documentação pede `vm.max_map_count` ≥ 524288, `fs.file-max` ≥ 131072 e pelo menos 131072 file descriptors e 8192 threads para o usuário que roda o Sonar. Esses sysctl são do kernel da VM, não do container, então ficam no startup script. Sem eles o container entra em crash loop.

**Por quê da imagem:** a tag `community` da imagem oficial é o Community Build, a oferta gratuita do Sonar. Para o treinamento ficar reprodutável, fixe uma tag de versão em `sonar_image` depois do primeiro deploy.

**Senha:** O startup-script no metadata fica legível para qualquer identidade com compute.instances.get e aparece no Console da VM. O secret tem IAM próprio, concedido só à SA da VM, e o acesso gera audit log.

---

## Etapa 5: Apply

```bash
cd terraform
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

O startup script leva uns 3 a 5 minutos. Acompanhe assim:

```bash
$(terraform output -raw ssh_command) --command 'sudo tail -f /var/log/sonar-startup.log'
curl -s "$(terraform output -raw sonar_url)/api/system/status"   # esperado: "status":"UP"
```

Se o status ficar em `STARTING` por muito tempo, entre na VM e rode `sudo docker logs sonarqube-sonarqube-1 --tail 50`. Quase sempre é `vm.max_map_count` ou falta de memória.

---

## Etapa 6: Bootstrap do SonarQube (senha, token e secrets do GitHub)

**Por quê:** o Sonar sobe com `admin/admin` e a action precisa de `SONAR_TOKEN` e `SONAR_HOST_URL`. A action lê as duas variáveis do ambiente do step, vindas de secrets do GitHub. Automatizar evita copiar token à mão e deixa o lab refazível.

`scripts/bootstrap-sonar.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- variáveis ---------------------------------------------------------
: "${SONAR_ADMIN_PASSWORD:?Defina SONAR_ADMIN_PASSWORD (nova senha do admin)}"
: "${GH_REPO:?Defina GH_REPO no formato owner/repo}"
TF_DIR="${TF_DIR:-terraform}"
TOKEN_NAME="${TOKEN_NAME:-github-actions}"

SONAR_URL="$(terraform -chdir="$TF_DIR" output -raw sonar_url)"

# --- 1) espera o Sonar ficar UP ----------------------------------------
echo ">> Aguardando SonarQube em ${SONAR_URL}"
status=""
for i in $(seq 1 60); do
  status="$(curl -fsS "${SONAR_URL}/api/system/status" 2>/dev/null | jq -r '.status' 2>/dev/null || true)"
  [[ "$status" == "UP" ]] && break
  echo "   tentativa ${i}: status='${status:-sem resposta}'"
  sleep 10
done
[[ "$status" == "UP" ]] || { echo "Timeout aguardando o SonarQube" >&2; exit 1; }

# --- 2) troca a senha padrão (idempotente) -----------------------------
valid="$(curl -s -u "admin:${SONAR_ADMIN_PASSWORD}" "${SONAR_URL}/api/authentication/validate" | jq -r '.valid' 2>/dev/null || true)"
if [[ "$valid" != "true" ]]; then
  echo ">> Trocando a senha padrão do admin"
  curl -fsS -u admin:admin -X POST "${SONAR_URL}/api/users/change_password" \
    --data-urlencode "login=admin" \
    --data-urlencode "previousPassword=admin" \
    --data-urlencode "password=${SONAR_ADMIN_PASSWORD}"
fi

# --- 3) gera token de usuário (recria se já existir) -------------------
echo ">> Gerando token '${TOKEN_NAME}'"
curl -s -u "admin:${SONAR_ADMIN_PASSWORD}" -X POST "${SONAR_URL}/api/user_tokens/revoke" \
  --data-urlencode "name=${TOKEN_NAME}" >/dev/null || true
TOKEN="$(curl -fsS -u "admin:${SONAR_ADMIN_PASSWORD}" -X POST "${SONAR_URL}/api/user_tokens/generate" \
  --data-urlencode "name=${TOKEN_NAME}" | jq -r '.token')"

# --- 4) grava os secrets no GitHub (token nunca é impresso) ------------
echo ">> Gravando secrets em ${GH_REPO}"
gh secret set SONAR_TOKEN    --repo "$GH_REPO" --body "$TOKEN"
gh secret set SONAR_HOST_URL --repo "$GH_REPO" --body "$SONAR_URL"

echo ">> OK. Sonar: ${SONAR_URL} (usuário: admin)"
```

Execução:

```bash
chmod +x scripts/bootstrap-sonar.sh
read -rsp "Nova senha do admin Sonar: " SONAR_ADMIN_PASSWORD; export SONAR_ADMIN_PASSWORD; echo
export GH_REPO=SEU_USUARIO/sonar-lab
./scripts/bootstrap-sonar.sh
```

Usei **token de usuário** (do admin) porque ele pode criar o projeto na primeira análise. Um token de projeto só funciona depois que o projeto existe.

---

## Etapa 7: Pipeline no GitHub Actions

`.github/workflows/ci-sonar.yml`:

```yaml
name: ci-sonar

on:
  push:
    branches: [main]
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  contents: read

jobs:
  test-and-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # histórico completo: o Sonar precisa dele para blame e detecção de new code

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip
          cache-dependency-path: requirements*.txt

      - name: Instalar dependências
        run: pip install -r requirements.txt -r requirements-dev.txt

      - name: Testes + cobertura
        run: pytest --cov=app --cov-report=xml:coverage.xml --cov-report=term

      - name: SonarQube scan
        uses: SonarSource/sonarqube-scan-action@v8
        env:
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
          SONAR_HOST_URL: ${{ secrets.SONAR_HOST_URL }}
        with:
          args: >
            -Dsonar.qualitygate.wait=true

  docker-build:
    needs: test-and-scan
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build da imagem Hello World
        run: docker build -t hello-sonar:${{ github.sha }} .
```

**Por quê de cada decisão:**

- **Ordem testes, depois scan:** o `coverage.xml` precisa existir antes do scanner. Sem ele, o Sonar mostra 0% de cobertura.
- **`fetch-depth: 0`:** a documentação da action recomenda desativar o shallow clone para os relatórios ficarem mais relevantes.
- **`sonar.qualitygate.wait=true`:** o job só termina depois que o Sonar processa a análise e avalia o Quality Gate, e falha se reprovar. Sem isso o pipeline fica verde mesmo com o gate vermelho.
- **`docker-build` depois do scan:** é o "Hello World image". Só builda se a qualidade passou. Push para o Artifact Registry fica como extensão (precisa de Workload Identity Federation, que dá outro guia).

**Sobre a versão da action:** usei `@v8`, mas a release v8.0.0 (maio/2026) traz uma seção de breaking change nas release notes. Leia antes de rodar. Se algo quebrar, `@v7` é a alternativa conhecida.

---

## Etapa 8: Rodar e validar

```bash
git add . && git commit -m "feat: sonar lab" && git push origin main
```

1. Veja o run em **Actions** do repo: testes, scan e build devem passar.
2. Abra `http://<IP>:9000`, logue como `admin` e confira o projeto `hello-sonar-lab` com cobertura e Quality Gate **Passed**.

---

## Etapa 9: Cenário de treinamento (o Sonar apontando problema)

Com o fluxo verde, adicione código ruim de propósito para o grupo ver o gate falhar.

`app/legacy.py`:

```python
"""Módulo de treinamento: problemas propositais para o SonarQube apontar."""
import hashlib

DB_PASSWORD = "admin123"  # credencial hardcoded


def parse(value):
    try:
        return int(value)
    except:  # except genérico
        pass


def checksum(data: str) -> str:
    unused = 42  # variável não usada
    return hashlib.md5(data.encode()).hexdigest()  # hash fraco
```

Faça commit e push. O Sonar tende a reportar a credencial hardcoded, o `except` genérico, a variável não usada e o uso de MD5. O arquivo também não tem teste, então a cobertura em código novo cai. É provável que o Quality Gate reprove e o job fique vermelho.

**Exercício para o grupo:** corrigir cada issue ou adicionar testes, dar push e ver o gate voltar para verde.

---

## Etapa 10: Custo e limpeza

```bash
# pausar entre sessões de treino (o IP estático reservado continua sendo cobrado enquanto a VM está parada)
gcloud compute instances stop sonarqube-lab --zone southamerica-east1-b --project tbx-gabriel-simoes
gcloud compute instances start sonarqube-lab --zone southamerica-east1-b --project tbx-gabriel-simoes

# destruir tudo ao final
cd terraform && terraform destroy
```

Destruir a VM apaga os dados do Sonar (histórico de análises), porque os volumes ficam no disco de boot. Para o lab isso é aceitável.

---

## Mapeamento com o Definition of Done

| Critério | Onde foi atendido |
|---|---|
| Criar VM na estrutura do GCP da Toolbox via Terraform | Etapas 4 e 5 (`terraform apply`) |
| Criar pipeline | Etapa 7 (`ci-sonar.yml`, com build da imagem Hello World) |
| Executar testes e enviar informações ao SonarQube | Etapas 7 e 8 (pytest com cobertura, scanner e Quality Gate) |

---

## Sources

- [Repositório oficial da sonarqube-scan-action](https://github.com/sonarsource/sonarqube-scan-action)
- [Release v8.0.0 da action (PR de bump com release notes)](https://github.com/zaphiro-technologies/github-workflows/pull/289)
- [Imagem oficial sonarqube no Docker Hub](https://hub.docker.com/_/sonarqube/)
- [Pré-requisitos de kernel para SonarQube (vm.max_map_count, file-max)](https://rajendrasinhparmar-github-io.pages.dev/posts/setup-sonarqube-on-ubuntu)
