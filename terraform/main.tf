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
