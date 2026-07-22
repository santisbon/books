#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-backup-config.yaml}"

if [[ ! -f "$CONFIG" ]]; then
  echo "Config file not found: $CONFIG" >&2
  echo "Copy backup-config.yaml.example to $CONFIG and fill in your values." >&2
  exit 1
fi

if ! command -v aws &>/dev/null; then
  echo "aws CLI not found. Install it from https://aws.amazon.com/cli/" >&2
  exit 1
fi

yaml_get() {
  grep "^${1}:" "$CONFIG" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"' | tr -d "'"
}

# kubectl command to use; override for clusters reached via a wrapper,
# e.g. KUBECTL=mkctl bash scripts/backup.sh  (MicroCloud cluster, no local kubeconfig)
KUBECTL="${KUBECTL:-kubectl}"

PROFILE=$(yaml_get profile)
BUCKET=$(yaml_get bucket)
NAMESPACE=$(yaml_get namespace)

TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
PREFIX="bookorbit/$TIMESTAMP"
S3="aws s3 --profile $PROFILE --no-progress"
S3CP="$S3 cp --content-type application/octet-stream"

echo "Backing up to s3://$BUCKET/$PREFIX/"

$S3 mb "s3://$BUCKET" 2>/dev/null || true

echo "→ database..."
$KUBECTL exec -n "$NAMESPACE" deploy/bookorbit-postgres \
  -- pg_dump -U bookorbit bookorbit \
  | gzip \
  | $S3CP - "s3://$BUCKET/$PREFIX/postgres.sql.gz"

NICE_TAR='IONICE=""; command -v ionice >/dev/null 2>&1 && IONICE="ionice -c3"; exec nice -n 19 $IONICE tar'

# The /books and /data archives are tarred inside a pod that has the volumes
# mounted. Normally that is the running app pod. If the app is scaled to zero
# (quiesced for a fully consistent backup), exec has no pod to target and
# would hang until timeout, so start a short-lived backup-helper pod that
# mounts the two PVCs instead. The RWO volumes are free to attach because
# nothing else is using them. Mirrors restore-helper.yaml in the README.
FILES_TARGET="deploy/bookorbit"
REPLICAS=$($KUBECTL get deploy/bookorbit -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
if [[ "$REPLICAS" == "0" ]]; then
  echo "App is scaled to zero; starting backup-helper pod to read the volumes..."
  cleanup() {
    $KUBECTL delete pod backup-helper -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  $KUBECTL apply -n "$NAMESPACE" -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: backup-helper
spec:
  restartPolicy: Never
  containers:
    - name: helper
      image: busybox
      command: ["sleep", "3600"]
      volumeMounts:
        - { name: books, mountPath: /books, readOnly: true }
        - { name: data, mountPath: /data, readOnly: true }
  volumes:
    - name: books
      persistentVolumeClaim:
        claimName: bookorbit-books
    - name: data
      persistentVolumeClaim:
        claimName: bookorbit-data
EOF
  $KUBECTL wait --for=condition=Ready pod/backup-helper -n "$NAMESPACE" --timeout=120s
  FILES_TARGET="pod/backup-helper"
fi

echo "→ /books..."
$KUBECTL exec -n "$NAMESPACE" "$FILES_TARGET" \
  -- sh -c "$NICE_TAR czf - -C / --exclude=lost+found books" \
  | $S3CP - "s3://$BUCKET/$PREFIX/books.tar.gz"

echo "→ /data..."
$KUBECTL exec -n "$NAMESPACE" "$FILES_TARGET" \
  -- sh -c "$NICE_TAR czf - -C / --exclude=lost+found data" \
  | $S3CP - "s3://$BUCKET/$PREFIX/data.tar.gz"

echo "Done. Backup stored at s3://$BUCKET/$PREFIX/"
