#!/usr/bin/env bash
set -euo pipefail

# Starts the AWS X-Ray daemon locally using Docker.
# Uses temporary SSO credentials exported as environment variables
# to avoid profile-name parsing issues in the daemon binary.
#
# Usage:
#   ./scripts/run-daemon.sh                # uses AWS_PROFILE env or default profile
#   ./scripts/run-daemon.sh <profile-name>
#   ./scripts/run-daemon.sh my-profile us-east-2

PROFILE="${1:-${AWS_PROFILE:-default}}"
REGION="${2:-us-east-1}"

echo "→ Exporting credentials from profile '${PROFILE}' …"
eval "$(aws configure export-credentials --profile "${PROFILE}" --format env 2>/dev/null)" || {
  echo "✗ Failed to get credentials. Run 'aws sso login --profile ${PROFILE}' first."
  exit 1
}

echo "→ Starting X-Ray daemon (region: ${REGION}) …"
docker run --rm \
  -e AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY \
  -e AWS_SESSION_TOKEN \
  -e AWS_REGION="${REGION}" \
  -p 2000:2000/udp \
  amazon/aws-xray-daemon:3.x \
  -o -n "${REGION}"
