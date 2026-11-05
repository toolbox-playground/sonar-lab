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