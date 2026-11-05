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
