#!/usr/bin/bash
# migrate-to-persistent-storage.sh
#
# One-time migration: move postgres and redis data from the ephemeral
# minikube hostpath provisioner (/tmp/hostpath-provisioner/) to the
# persistent Docker volume (/var/data/).
#
# After this, data survives WSL2/Docker reboots because /var is the
# only path backed by a Docker volume in minikube's Docker-driver container.
#
# Usage: ./migrate-to-persistent-storage.sh
#
# Prerequisites:
#   - minikube running with Docker driver
#   - kubectl configured to talk to minikube
#   - Current data in /tmp/hostpath-provisioner/default/

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Minikube Persistent Storage Migration ==="
echo ""
echo "This script will:"
echo "  1. Back up postgres data (pg_dump)"
echo "  2. Copy existing data to /var/data/ inside minikube"
echo "  3. Delete old StatefulSets and PVCs"
echo "  4. Apply new manifests with persistent-local StorageClass"
echo "  5. Wait for pods to come back up"
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Step 1: Back up postgres
echo ""
echo "--- Step 1: Backing up postgres ---"
BACKUP_FILE="/tmp/polaris-pg-backup-$(date +%Y%m%d-%H%M%S).sql"
POSTGRES_POD=$(kubectl get pod -l app.kubernetes.io/name=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -n "$POSTGRES_POD" ]; then
    echo "Dumping all databases from $POSTGRES_POD..."
    kubectl exec "$POSTGRES_POD" -- pg_dumpall -U incident > "$BACKUP_FILE" 2>/dev/null || true
    if [ -s "$BACKUP_FILE" ]; then
        echo "Backup saved to $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
    else
        echo "Warning: pg_dump produced empty output (database may be empty)"
        rm -f "$BACKUP_FILE"
        BACKUP_FILE=""
    fi
else
    echo "No postgres pod running, skipping backup"
    BACKUP_FILE=""
fi

# Step 2: Copy data to persistent location inside minikube
echo ""
echo "--- Step 2: Copying data to /var/data/ inside minikube ---"
minikube ssh -- "sudo mkdir -p /var/data/postgres /var/data/redis"

# Check if source data exists and copy it
if minikube ssh -- "test -d /tmp/hostpath-provisioner/default/data-postgres-0" 2>/dev/null; then
    echo "Copying postgres data..."
    minikube ssh -- "sudo cp -a /tmp/hostpath-provisioner/default/data-postgres-0/. /var/data/postgres/"
    echo "Done."
else
    echo "No existing postgres data to copy (will start fresh)"
fi

if minikube ssh -- "test -d /tmp/hostpath-provisioner/default/data-redis-0" 2>/dev/null; then
    echo "Copying redis data..."
    minikube ssh -- "sudo cp -a /tmp/hostpath-provisioner/default/data-redis-0/. /var/data/redis/"
    echo "Done."
else
    echo "No existing redis data to copy (will start fresh)"
fi

# Step 3: Delete old StatefulSets and PVCs
echo ""
echo "--- Step 3: Removing old StatefulSets and PVCs ---"
kubectl delete statefulset postgres redis --ignore-not-found --wait=true
kubectl delete pvc data-postgres-0 data-redis-0 --ignore-not-found --wait=true

# Clean up any old PVs from the default provisioner
kubectl delete pv --selector='!kubernetes.io/no-provisioner' \
    --field-selector='spec.storageClassName=standard' \
    --ignore-not-found 2>/dev/null || true

# Step 4: Apply new manifests
echo ""
echo "--- Step 4: Applying new manifests with persistent-local StorageClass ---"
kubectl apply -k "$INFRA_DIR"

# Step 5: Wait for pods
echo ""
echo "--- Step 5: Waiting for pods to start ---"
echo "Waiting for postgres..."
kubectl rollout status statefulset/postgres --timeout=120s
echo "Waiting for redis..."
kubectl rollout status statefulset/redis --timeout=60s

# Step 6: Verify
echo ""
echo "--- Step 6: Verification ---"
echo ""
echo "PVCs:"
kubectl get pvc data-postgres-0 data-redis-0 -o wide 2>/dev/null || echo "(PVCs not yet bound)"
echo ""
echo "PVs:"
kubectl get pv pv-postgres pv-redis -o wide 2>/dev/null || echo "(PVs not found)"
echo ""
echo "Pods:"
kubectl get pods -l 'app.kubernetes.io/name in (postgres,redis)' -o wide
echo ""

# Step 7: Restore backup if we took one and data was freshly initialized
if [ -n "${BACKUP_FILE:-}" ] && [ -f "$BACKUP_FILE" ]; then
    POSTGRES_POD=$(kubectl get pod -l app.kubernetes.io/name=postgres -o jsonpath='{.items[0].metadata.name}')
    echo "--- Optional: Restore backup ---"
    echo "A backup was saved at: $BACKUP_FILE"
    echo ""
    echo "If the data copy preserved your database (likely), you DON'T need to restore."
    echo "If the database is empty, restore with:"
    echo "  kubectl exec -i $POSTGRES_POD -- psql -U incident < $BACKUP_FILE"
fi

echo ""
echo "=== Migration complete ==="
echo ""
echo "Your data now lives on the Docker volume (minikube -> /var)."
echo "It will survive WSL2 reboots and minikube stop/start cycles."
