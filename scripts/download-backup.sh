#!/usr/bin/env bash
# Downloads the latest bookorbit backup from S3-compatible object storage.
# Finds the most recent timestamp prefix under s3://<bucket>/bookorbit/,
# and downloads all three archives (postgres.sql.gz, books.tar.gz, data.tar.gz)
# into a local directory named after that timestamp.
# Usage: bash scripts/download-backup.sh [backup-config.yaml]
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

PROFILE=$(yaml_get profile)
BUCKET=$(yaml_get bucket)

# List all timestamp prefixes under bookorbit/, sort lexicographically
# (timestamps are ISO 8601 so lexicographic order = chronological), pick the last one
LATEST=$(aws s3 ls "s3://$BUCKET/bookorbit/" --profile "$PROFILE" \
  | awk '{print $2}' | tr -d '/' | sort | tail -1)

if [[ -z "$LATEST" ]]; then
  echo "No backups found in s3://$BUCKET/bookorbit/" >&2
  exit 1
fi

echo "Downloading from s3://$BUCKET/bookorbit/$LATEST/"

# Download all three archives (postgres.sql.gz, books.tar.gz, data.tar.gz)
# into a local directory named after the timestamp
aws s3 cp "s3://$BUCKET/bookorbit/$LATEST/" "$LATEST/" \
  --profile "$PROFILE" --recursive

echo "Done. Files downloaded to $LATEST/"
