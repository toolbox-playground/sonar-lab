# SonarQube lab no GCP (Terraform) com GitHub Actions

Cenário de treinamento no projeto GCP: VM SonarQube criada via Terraform, app Hello World em Docker e pipeline no GitHub Actions que roda testes e envia o relatório ao SonarQube.

## Sumário

0. Pré-requisitos no WSL
1. Bucket de state remoto
2. Estrutura do repositório
3. App Hello World
4. Terraform (VM SonarQube)
5. Apply (e problemas conhecidos)
6. Configuração manual: Sonar, repo na org e secrets
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
gh auth login                           # o gh grava os secrets e fala com a API do GitHub
terraform -version && jq --version && gh --version
```

**Por quê:** `gcloud auth login` e ADC são credenciais separadas. Sem o `application-default`, o `terraform plan` falha com erro de credencial, mesmo com o gcloud logado.

Você precisa de permissão para criar Compute, Service Account, IAM binding, Secret Manager e bucket no projeto (por exemplo `roles/secretmanager.admin` para o secret e o binding). Se algum `apply` falhar por org policy (IP externo proibido, shielded VM obrigatório etc.) ou por `PERMISSION_DENIED`, confira as constraints e as roles do lab antes de mexer no código.

**Atenção às duas identidades do GitHub:** o `git` usa a **chave SSH** e o `gh` usa um **token**. Elas podem estar em contas diferentes (por exemplo, pessoal e da empresa). Isso causa o erro `Repository not found` descrito na Etapa 6.

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
├── Dockerfile
├── requirements.txt / requirements-dev.txt / pytest.ini
├── sonar-project.properties
├── .gitignore
└── .gitattributes
```

O repositório git fica na **raiz** (`sonar-lab/`), não dentro de `terraform/`.

**Line endings (LF):** os arquivos precisam estar em LF. Um `startup.sh.tpl` com CRLF (comum ao editar pelo Windows) faz o script falhar na VM com `/usr/bin/env: 'bash\r': No such file or directory`. Para converter o que já existe e evitar a recorrência:

```bash
# converte para LF (ignora .venv, .git e .terraform)
find . \( -path ./.venv -o -path ./.git -o -path ./terraform/.terraform \) -prune -o \
  -type f \( -name '*.tf' -o -name '*.tfvars' -o -name '*.tpl' -o -name '*.sh' \
             -o -name '*.txt' -o -name '*.ini' -o -name '*.py' -o -name '*.properties' \
             -o -name '*.yml' -o -name '*.yaml' -o -name 'Dockerfile' -o -name '.gitignore' \) \
  -exec sed -i 's/\r$//' {} +

# confere: deve imprimir OK
grep -rlI $'\r' --exclude-dir=.venv --exclude-dir=.terraform --exclude-dir=.git . || echo "OK: sem CRLF"
```

`.gitattributes`:

```
*.sh   text eol=lf
*.tpl  text eol=lf
*.tf   text eol=lf
*.yml  text eol=lf
*.yaml text eol=lf
Dockerfile text eol=lf
```

No WSL, rode também `git config core.autocrlf input`. Se você edita pelo VS Code do Windows, force LF nas configurações (`"files.eol": "\n"`).

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

O `terraform/tfplan` precisa estar aqui porque o plano guarda a senha do Postgres. Se você tiver anotações com credenciais ou IPs na pasta (por exemplo `anotacoes.txt`), adicione também.

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
- **Secret Manager para a senha do Postgres:** a senha não fica no metadata da VM.
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
  default = "southamerica-east1-b" # sobrescrito no terraform.tfvars; veja "Problemas conhecidos" na Etapa 5
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

# Permissões à conta de serviço da VM para escrever logs
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
# /24 significa que teremos 256 endereços IP disponíveis na sub-rede, o que é suficiente para uma VM de laboratório
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

  # A interface de rede da VM usa a sub-rede e o endereço IP estático.
  # nat_ip é necessário para que a VM tenha um IP público e possa ser acessada de fora da rede do Google Cloud.
  network_interface {
    subnetwork = google_compute_subnetwork.this.id
    access_config {
      nat_ip = google_compute_address.sonarqube.address
    }
  }

  # A conta de serviço da VM usa o scope cloud-platform; o que ela pode de fato fazer é limitado pelo IAM.
  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  # Instância protegida: inicialização segura, vTPM e monitoramento de integridade.
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # OS Login para gerenciar o SSH com contas do Google, e o script de inicialização que sobe SonarQube + PostgreSQL.
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

`terraform/outputs.tf`:

```hcl
output "sonar_url" {
  value = "http://${google_compute_address.sonarqube.address}:9000"
}

output "ssh_command" {
  value = "gcloud compute ssh ${google_compute_instance.sonarqube.name} --zone ${var.zone} --tunnel-through-iap --project ${var.project_id}"
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

**Senha:** o `startup-script` no metadata fica legível para qualquer identidade com `compute.instances.get` e aparece no Console da VM. O secret tem IAM próprio, concedido só à SA da VM, e o acesso gera audit log. Como a senha é gerada pelo `random_password`, o valor continua existindo no state, por isso o bucket do state tem IAM restrito e versionamento (Etapa 1).

---

## Etapa 5: Apply (e problemas conhecidos)

```bash
cd terraform
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

O startup script leva uns 3 a 5 minutos. Acompanhe assim:

```bash
$(terraform output -raw ssh_command) --command 'sudo tail -f /var/log/sonar-startup.log'   # Ctrl+C para sair
```

Quando o log terminar com o `docker compose up -d` criando os containers `db` e `sonarqube` (o `db` fica `Healthy`), espere o Sonar ficar `UP`, o que leva mais 1 a 2 minutos:

```bash
until curl -s "$(terraform output -raw sonar_url)/api/system/status" | grep -q '"status":"UP"'; do
  echo "aguardando..."; sleep 10
done
echo "Sonar UP"
```

Na primeira conexão por IAP o `gcloud` gera a chave SSH e pode pedir uma passphrase. O OS Login pode levar um minuto para propagar a permissão; se aparecer `Permission denied` ou erro 4003, espere e tente de novo.

### Problemas conhecidos

| Sintoma | Causa | Solução |
|---|---|---|
| `apply` falha com `ZONE_RESOURCE_POOL_EXHAUSTED` ("does not have enough resources") | A zona está sem capacidade para o `machine_type` | Troque `zone` no `terraform.tfvars` (por exemplo `southamerica-east1-a`) e rode `plan` + `apply` de novo; só a VM é criada, o resto já existe. Se as três zonas falharem, use outro `machine_type` (por exemplo `n2-standard-2`) ou tente mais tarde |
| `/var/log/sonar-startup.log` não existe; a serial mostra `'bash\r': No such file or directory` | `startup.sh.tpl` com CRLF; o script morre antes de criar o log | Converta para LF (Etapa 2), `terraform apply` (altera só o metadata da VM) e rode o startup manualmente (linha abaixo) |
| Startup script corrigido, mas nada acontece na VM | O startup script só roda no boot | `$(terraform output -raw ssh_command) --command 'sudo google_metadata_script_runner startup'` (prende o terminal por 3 a 5 minutos) |
| Log mostra `Falha ao ler o secret` | IAM do secret ainda não propagou ou falta permissão | O script tenta 30 vezes; se persistir, confira o binding `secretAccessor` da SA da VM |
| Sonar fica em `STARTING` ou o container reinicia em loop | `vm.max_map_count` baixo ou pouca memória | `sysctl vm.max_map_count` (deve dar `524288`) e `sudo docker logs sonarqube-sonarqube-1 --tail 50` |
| `apply` falha com `PERMISSION_DENIED` no Secret Manager | Falta `roles/secretmanager.admin` ou equivalente | Peça a role ao admin do projeto |

Para conferir o metadata que a VM recebeu (o primeiro byte deve ser `bash\n`, sem `\r`):

```bash
gcloud compute instances describe sonarqube-lab \
  --zone southamerica-east1-a --project tbx-gabriel-simoes --format=json \
  | jq -r '.metadata.items[] | select(.key=="startup-script") | .value' \
  | head -1 | od -c | head -2
```

---

## Etapa 6: Configuração manual: Sonar, repo na org e secrets

**Por quê manual:** senha do admin, token e secrets são setup único e não fazem parte do que o pipeline executa. A **ordem importa**: os secrets precisam existir antes do primeiro push, porque o push dispara o pipeline.

### 6.1 Primeiro login e senha

```bash
cd terraform
terraform output -raw sonar_url
```

Abra a URL e logue com `admin` / `admin`. O Sonar força a troca de senha no primeiro acesso. Use uma senha forte, porque a porta 9000 está aberta para a internet.

### 6.2 Token do Sonar

No Sonar: avatar (canto superior direito), **My Account**, **Security**, **Generate Tokens**. O token só é mostrado uma vez, então copie na hora.

| Opção | Como | Quando usar |
|---|---|---|
| **User token** | Name `github-actions`, Type `User Token` | Mais simples. A primeira análise cria o projeto sozinha |
| **Project Analysis Token** | Antes: **Projects, Create project, Manually**, com project key `hello-sonar-lab`. Depois gere o token do tipo `Project Analysis Token` desse projeto | Mais seguro: o token só envia análises daquele projeto |

- Com o projeto manual, a project key precisa bater com `sonar.projectKey` do `sonar-project.properties`. Se divergir, a análise cria um segundo projeto ou falha.
- Escolha a expiração do token. Se ele expirar, o scan passa a falhar com `401`; gere outro e regrave o secret `SONAR_TOKEN` (6.6).

### 6.3 Repositório na org

Crie manualmente em `https://github.com/organizations/SUA-ORG/repositories/new`:

- **Owner:** a org (não a conta pessoal)
- **Name:** `sonar-lab`, ou o padrão de nome da empresa
- **Visibility:** Private
- **Não marque** README, .gitignore nem license: o repo precisa nascer vazio para o primeiro push não conflitar.

Se a org restringe a criação de repositórios, peça a criação a um admin.

### 6.4 Acesso SSH ao repo da org

Primeiro diagnostique de qual conta cada ferramenta fala. O `git` usa a chave SSH e o `gh` usa o token:

```bash
ssh -T git@github.com          # conta da chave SSH
gh auth status                  # conta do gh
gh api user/memberships/orgs/SUA-ORG --jq '{state, role}'   # state deve ser "active"
gh repo view SUA-ORG/sonar-lab --json nameWithOwner,visibility
```

| Situação | O que significa | O que fazer |
|---|---|---|
| `ssh -T` e `gh` mostram a mesma conta, com acesso à org | Tudo certo | Vá direto para "Remote" abaixo, usando `git@github.com:SUA-ORG/sonar-lab.git` |
| `ssh -T` mostra a conta pessoal e o `gh` mostra a conta da empresa | A chave SSH não tem acesso à org. O `gh repo view` funciona e o `git ls-remote` dá `Repository not found` | Crie uma chave para a conta da empresa (abaixo) |
| `membership` dá `404` ou `state` diferente de `active` | A conta não é membro ativo da org (ou o convite está pendente) | Aceite o convite ou peça a um admin |
| `gh repo view` não encontra o repo | O repo não existe ou o nome está diferente | Crie o repo (6.3) ou liste: `gh repo list SUA-ORG --limit 100 --json name --jq '.[].name'` |
| Erro mencionando SAML ou SSO | A chave ou o token não estão autorizados na org | **Settings, SSH and GPG keys, Configure SSO, Authorize** (chave) e autorize o token do `gh` pelo link do erro |

**Chave dedicada à conta da empresa** (uma chave SSH só pode estar em uma conta do GitHub):

```bash
# 1) gerar
ssh-keygen -t ed25519 -C "SEU_EMAIL_DA_EMPRESA" -f ~/.ssh/id_ed25519_empresa

# 2) cadastrar na conta que o gh está usando (o token precisa do escopo admin:public_key)
gh ssh-key add ~/.ssh/id_ed25519_empresa.pub --title "WSL Gabriel (empresa)"

# 3) alias no ~/.ssh/config
cat >> ~/.ssh/config <<'EOF'

Host github-empresa
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519_empresa
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config

# 4) testar: deve responder com a conta da empresa
ssh -T git@github-empresa
```

O `IdentitiesOnly yes` impede o SSH de oferecer a chave pessoal para esse host. Se a org usa SAML SSO, autorize a chave nova na org (**Configure SSO**).

**Remote** (na raiz do repo, não dentro de `terraform/`):

```bash
cd ~/toolbox_wsl/estudos/Lab_SonarQube      # ajuste para o caminho do seu repo
git init -b main

ORG_REPO="SUA-ORG/sonar-lab"
: "${ORG_REPO:?defina ORG_REPO}"

# com alias (conta da empresa): git@github-empresa:...   |   sem alias: git@github.com:...
git remote add origin "git@github-empresa:${ORG_REPO}.git"
git remote -v

git ls-remote origin && echo "acesso OK"    # repo vazio não lista nada, mas imprime "acesso OK"
```

Se `origin` já existir, use `git remote set-url origin ...` no lugar de `git remote add`.

### 6.5 Identidade dos commits

Rode **um comando por linha** e só neste repo, para o commit não sair com a identidade pessoal:

```bash
git config user.name  "SEU NOME"
git config user.email "SEU_EMAIL_DA_EMPRESA"
git config --local --get-regexp '^user\.'
```

### 6.6 Secrets do GitHub

Os nomes precisam ser exatamente `SONAR_TOKEN` e `SONAR_HOST_URL`. A URL não leva barra no final.

```bash
cd ~/toolbox_wsl/estudos/Lab_SonarQube      # raiz do repo
ORG_REPO="SUA-ORG/sonar-lab"

gh secret set SONAR_TOKEN --repo "$ORG_REPO"        # cole o token (a digitação fica oculta)
gh secret set SONAR_HOST_URL --repo "$ORG_REPO" \
  --body "$(terraform -chdir=terraform output -raw sonar_url)"
gh secret list --repo "$ORG_REPO"                   # devem aparecer os dois nomes; o valor nunca é exibido
```

- **Pela web:** repo, **Settings, Secrets and variables, Actions, New repository secret**.
- **Secret de organização:** se várias pessoas usam o mesmo Sonar, um secret na org (**Org Settings, Secrets and variables, Actions**) evita repetir, mas exige admin.
- O `gh secret set` usa o token do `gh`, não a chave SSH. Ele também precisa estar autorizado na org (SSO).

### 6.7 Liberar a action do Sonar na org

Orgs costumam restringir actions de terceiros, e a `SonarSource/sonarqube-scan-action` é de terceiros. Em **Settings, Actions, General** (do repo ou da org):

- *Allow all actions*: não precisa fazer nada.
- *Allow select actions*: adicione `SonarSource/sonarqube-scan-action@*` à lista.

Se estiver bloqueada, o run falha logo no início dizendo que a action não é permitida na organização.

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

**Sobre a versão da action:** o fluxo foi validado com `@v8`. As release notes da v8.0.0 (maio/2026) têm uma seção de breaking change, então leia antes de atualizar. Se algo quebrar, `@v7` é a alternativa conhecida.

**Avisos que aparecem no run (não bloqueiam):**

- *Node.js 20 is deprecated*: `actions/checkout@v4` e `actions/setup-python@v5` estão sendo forçados para Node 24. Quando quiser, suba para as majors mais novas e leia as release notes.
- *`ubuntu-latest` vai migrar para Ubuntu 26* (a partir de 19/10/2026). Para estabilidade, fixe `runs-on: ubuntu-24.04`.

---

## Etapa 8: Rodar e validar

Pré-condições: secrets gravados (6.6), `.github/workflows/ci-sonar.yml` criado, action liberada na org (6.7) e `terraform/tfplan` no `.gitignore`.

```bash
cd ~/toolbox_wsl/estudos/Lab_SonarQube      # raiz do repo
git add -n .                                # simulação: confira o que entraria
```

Não devem aparecer `.venv`, `terraform/.terraform`, `terraform/tfplan`, `terraform/terraform.tfvars` nem arquivos com credenciais. Se aparecer, ajuste o `.gitignore`.

```bash
git add .
git status --short
git commit -m "feat: sonar lab"
git push -u origin main                     # vai pedir a passphrase da chave, se houver
gh run watch --repo "$ORG_REPO"
```

1. Veja o run em **Actions** do repo: `test-and-scan` e `docker-build` devem passar.
2. Abra `http://<IP>:9000`, logue como `admin` e confira o projeto `hello-sonar-lab` com cobertura e Quality Gate **Passed**.

No lab, o primeiro run resultou em: 8 linhas de código, cobertura 100%, duplicação 0%, Quality Gate **Passed** e **1 issue** de segurança (python:S4502), tratada na Etapa 9.

**Falhas possíveis no primeiro run:**

| Sintoma | Causa provável |
|---|---|
| Falha logo no início: action não permitida | Política da org (6.7) |
| `Unauthorized` ou `401` no scan | Token errado, expirado ou sem permissão; project key divergente (6.2) |
| Timeout ou `connection refused` no scan | O runner não alcança o Sonar: confira `allowed_cidrs` e se o Sonar está `UP` |
| Erro no step do scan relacionado à versão da action | Breaking change da v8; teste `@v7` |
| Job vermelho por Quality Gate | Esperado quando o gate reprova (`sonar.qualitygate.wait=true`) |

---

## Etapa 9: Cenário de treinamento (o Sonar apontando problema)

Com o fluxo verde, adicione código ruim de propósito para ver o gate falhar.

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

Faça commit e push. O Sonar tende a reportar a credencial hardcoded, o `except` genérico, a variável não usada e o uso de MD5. O arquivo também não tem teste, então a cobertura em código novo cai.

**O Quality Gate pode não reprovar.** O resultado depende das condições do gate ativo (aba **Quality gates**; clique em "All conditions passed" no card do projeto para ver o que é avaliado). No primeiro run do lab o gate passou com uma issue de severidade alta aberta, então não conte com o job vermelho sem conferir as condições. Se quiser que o gate falhe de forma previsível (opcional): em **Quality gates**, copie o "Sonar way" (o gate padrão não é editável), adicione uma condição sobre issues em código novo, defina a cópia como padrão do projeto e só depois faça o push do `legacy.py`.

### O achado do Sonar (python:S4502)

O Sonar apontou "Make sure disabling CSRF protection is safe here" na linha 3 do `app/main.py` (`app = Flask(__name__)`). Essa regra dispara em apps Flask sem proteção CSRF configurada. O app só tem dois endpoints GET que devolvem JSON, sem sessão nem escrita, então na prática não é explorável. Para um treinamento é um bom material de triagem:

- **Triagem (recomendo):** na tela da issue, mude o status de Open para Accept ou False Positive, com um comentário justificando. É o fluxo que o time vai usar no dia a dia.
- **Correção:** habilitar `CSRFProtect` do `flask-wtf`. Mostra o ciclo "issue, correção, issue some", mas adiciona dependência e `SECRET_KEY` a um app que não precisa delas.

**Exercício para o grupo:** triar ou corrigir cada issue (a S4502 e as do `legacy.py`), dar push e ver o Quality Gate voltar para verde.

---

## Etapa 10: Custo e limpeza

```bash
# pausar entre sessões de treino (o IP estático reservado continua sendo cobrado enquanto a VM está parada)
gcloud compute instances stop sonarqube-lab --zone southamerica-east1-a --project tbx-gabriel-simoes
gcloud compute instances start sonarqube-lab --zone southamerica-east1-a --project tbx-gabriel-simoes

# destruir tudo ao final
cd terraform && terraform destroy
```

Se você trocou a zona no `terraform.tfvars`, use a mesma zona nos comandos acima.

- **Destruir a VM apaga os dados do Sonar** (histórico de análises), porque os volumes ficam no disco de boot. Para o lab isso é aceitável.
- **Recriar o lab** (`destroy` e `apply`) gera **novo IP estático** e um Sonar zerado (`admin/admin`, sem token). Refaça a Etapa 6 e atualize os secrets `SONAR_HOST_URL` e `SONAR_TOKEN`.
- O `terraform destroy` **não** apaga o repositório nem os secrets do GitHub, nem o bucket de state. Remova pela web se não forem mais necessários.

---

## Etapa 11: Mapeamento com o Definition of Done

| Critério | Onde foi atendido | Evidência |
|---|---|---|
| Criar VM na estrutura do GCP da Toolbox via Terraform | Etapas 4 e 5 | `terraform apply` criou a VM `sonarqube-lab`; o Sonar responde na `:9000` |
| Criar pipeline | Etapa 7 | Workflow `ci-sonar` com `test-and-scan` e `docker-build` (imagem Hello World) |
| Executar testes e envio das informações ao SonarQube | Etapas 7 e 8 | Run verde; projeto `hello-sonar-lab` no Sonar com cobertura 100% e Quality Gate Passed |

---

## Sources

- [Repositório oficial da sonarqube-scan-action](https://github.com/sonarsource/sonarqube-scan-action)
- [Release v8.0.0 da action (PR de bump com release notes)](https://github.com/zaphiro-technologies/github-workflows/pull/289)
- [Imagem oficial sonarqube no Docker Hub](https://hub.docker.com/_/sonarqube/)
- [Pré-requisitos de kernel para SonarQube (vm.max_map_count, file-max)](https://rajendrasinhparmar-github-io.pages.dev/posts/setup-sonarqube-on-ubuntu)
