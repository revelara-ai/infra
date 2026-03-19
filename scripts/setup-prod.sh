#!/usr/bin/env bash
set -euo pipefail

# Phase 1E: One-time production GCP setup
# Run this script once before deploying production infrastructure.

PROJECT_ID="incident-kb"
NAMESPACE="prod"
REGION="us-central1"
SA_NAME="relynce"
GSA_EMAIL="relynce@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== Phase 1E: Production Setup ==="
echo "Project: ${PROJECT_ID}"
echo "Namespace: ${NAMESPACE}"
echo ""

# 1. Reserve global static IP
echo "--- Reserving static IP ---"
gcloud compute addresses create relynce-prod-ip --global --project="${PROJECT_ID}" 2>/dev/null || echo "Static IP already exists"
IP=$(gcloud compute addresses describe relynce-prod-ip --global --project="${PROJECT_ID}" --format='get(address)')
echo "Static IP: ${IP}"
echo "ACTION REQUIRED: Create DNS A records for app.relynce.ai and api.relynce.ai -> ${IP}"
echo ""

# 2. Create GCS buckets with versioning
echo "--- Creating GCS buckets ---"
gsutil mb -p "${PROJECT_ID}" -l "${REGION}" gs://relynce-backups-prod/ 2>/dev/null || echo "Backup bucket exists"
gsutil versioning set on gs://relynce-backups-prod/
gsutil mb -p "${PROJECT_ID}" -l "${REGION}" gs://relynce-incidents-prod/ 2>/dev/null || echo "Storage bucket exists"
gsutil versioning set on gs://relynce-incidents-prod/
echo ""

# 3. Create namespace
echo "--- Creating namespace ---"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
echo ""

# 4. Create KSA and bind Workload Identity
echo "--- Setting up Workload Identity ---"
kubectl create serviceaccount "${SA_NAME}" -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

gcloud iam service-accounts describe "${GSA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "${SA_NAME}" --project="${PROJECT_ID}" \
    --display-name="Relynce Production"

gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${SA_NAME}]" \
  --project="${PROJECT_ID}"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/storage.objectAdmin"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/aiplatform.user"

kubectl annotate serviceaccount "${SA_NAME}" -n "${NAMESPACE}" \
  iam.gke.io/gcp-service-account="${GSA_EMAIL}" --overwrite
echo ""

# 5. Create GCP Secret Manager secrets (placeholders)
echo "--- Creating Secret Manager secrets ---"
SECRETS=(
  "relynce-prod-db-user"
  "relynce-prod-db-password"
  "relynce-prod-migrate-db-user"
  "relynce-prod-migrate-db-password"
  "relynce-prod-jwt-secret"
  "relynce-prod-workos-api-key"
  "relynce-prod-workos-client-id"
  "relynce-prod-workos-organization"
  "relynce-prod-workos-redirect-uri"
  "relynce-prod-google-client-id"
  "relynce-prod-google-client-secret"
  "relynce-prod-google-redirect-uri"
  "relynce-prod-stripe-secret-key"
  "relynce-prod-stripe-webhook-secret"
  "relynce-prod-stripe-developer-price"
  "relynce-prod-stripe-team-price"
  "relynce-prod-integrations-encryption-key"
)

for secret in "${SECRETS[@]}"; do
  gcloud secrets describe "${secret}" --project="${PROJECT_ID}" >/dev/null 2>&1 || {
    echo -n "placeholder" | gcloud secrets create "${secret}" --data-file=- --project="${PROJECT_ID}"
    echo "Created: ${secret}"
  }
done

# Set known values
echo -n "polaris_api" | gcloud secrets versions add relynce-prod-db-user --data-file=- --project="${PROJECT_ID}" 2>/dev/null || true
echo -n "incident" | gcloud secrets versions add relynce-prod-migrate-db-user --data-file=- --project="${PROJECT_ID}" 2>/dev/null || true
echo -n "https://api.relynce.ai/api/v1/auth/workos/callback" | gcloud secrets versions add relynce-prod-workos-redirect-uri --data-file=- --project="${PROJECT_ID}" 2>/dev/null || true

# Generate random passwords
DB_PW=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
JWT_SECRET=$(openssl rand -base64 48 | tr -d '/+=' | head -c 48)
ENCRYPTION_KEY=$(openssl rand -hex 32)

echo -n "${DB_PW}" | gcloud secrets versions add relynce-prod-db-password --data-file=- --project="${PROJECT_ID}"
echo -n "${JWT_SECRET}" | gcloud secrets versions add relynce-prod-jwt-secret --data-file=- --project="${PROJECT_ID}"
echo -n "${ENCRYPTION_KEY}" | gcloud secrets versions add relynce-prod-integrations-encryption-key --data-file=- --project="${PROJECT_ID}"

# Grant GSA access to all secrets
echo "--- Granting secret access ---"
for secret in "${SECRETS[@]}"; do
  gcloud secrets add-iam-policy-binding "${secret}" \
    --member="serviceAccount:${GSA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor" \
    --project="${PROJECT_ID}" > /dev/null
done
echo ""

echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Create DNS A records: app.relynce.ai -> ${IP}, api.relynce.ai -> ${IP}"
echo "  2. Install CNPG operator: kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.1.yaml"
echo "  3. Deploy infra: kubectl apply -k overlays/prod/"
echo "  4. Bootstrap DB password (see runbook)"
echo "  5. Store WorkOS + Stripe live keys in Secret Manager"
