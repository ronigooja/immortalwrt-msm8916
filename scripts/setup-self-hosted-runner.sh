#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-ronigooja/immortalwrt-msm8916}"
RUNNER_VERSION="${RUNNER_VERSION:-2.337.0}"
RUNNER_SHA256="${RUNNER_SHA256:-70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613}"
RUNNER_USER="${RUNNER_USER:-github}"
RUNNER_NAME="${RUNNER_NAME:-vultr}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,Linux,X64}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEQ5mVzKrBj//Ml/Pm3CAH5ed9DZ/j2i6RHcD9r1fK9J root@debian}"

usage() {
  cat <<EOF
Usage: $0 <runner-ip-or-host>

Environment overrides:
  REPO=owner/repo
  RUNNER_VERSION=2.337.0
  RUNNER_USER=github
  RUNNER_NAME=vultr
  RUNNER_LABELS=self-hosted,Linux,X64
  SSH_PUBLIC_KEY='ssh-ed25519 ...'
  RUNNER_ADMIN_TOKEN=<GitHub token with repo/admin access>

The script also tries GH_TOKEN, GITHUB_TOKEN, and local git credentials.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

RUNNER_HOST="${1:-}"
if [ -z "$RUNNER_HOST" ]; then
  usage >&2
  exit 2
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing local command: $1" >&2
    exit 1
  fi
}

need_cmd curl
need_cmd ssh
need_cmd python3

get_github_token() {
  if [ -n "${RUNNER_ADMIN_TOKEN:-}" ]; then
    printf '%s' "$RUNNER_ADMIN_TOKEN"
    return
  fi
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN"
    return
  fi
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    printf '%s' "$GITHUB_TOKEN"
    return
  fi
  if command -v git >/dev/null 2>&1; then
    git credential fill <<EOF 2>/dev/null | awk -F= '$1 == "password" {print $2; exit}'
protocol=https
host=github.com

EOF
  fi
}

ADMIN_TOKEN="$(get_github_token)"
if [ -z "$ADMIN_TOKEN" ]; then
  echo "No GitHub token found. Export RUNNER_ADMIN_TOKEN, GH_TOKEN, or GITHUB_TOKEN." >&2
  exit 1
fi

REGISTRATION_TOKEN="$(
  python3 - "$REPO" "$ADMIN_TOKEN" <<'PY'
import json
import sys
import urllib.error
import urllib.request

repo, admin_token = sys.argv[1], sys.argv[2]
url = f"https://api.github.com/repos/{repo}/actions/runners/registration-token"
req = urllib.request.Request(
    url,
    method="POST",
    headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {admin_token}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "setup-self-hosted-runner",
    },
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.load(resp)
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8", "replace")
    raise SystemExit(f"GitHub API failed: HTTP {exc.code}\n{body}")

token = data.get("token")
if not token:
    raise SystemExit(f"GitHub API response did not include a token: {data}")
print(token)
PY
)"

echo "Bootstrapping runner ${RUNNER_NAME} on root@${RUNNER_HOST} for ${REPO}"

ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 "root@${RUNNER_HOST}" \
  "REPO='${REPO}' RUNNER_VERSION='${RUNNER_VERSION}' RUNNER_SHA256='${RUNNER_SHA256}' RUNNER_USER='${RUNNER_USER}' RUNNER_NAME='${RUNNER_NAME}' RUNNER_LABELS='${RUNNER_LABELS}' SSH_PUBLIC_KEY='${SSH_PUBLIC_KEY}' REGISTRATION_TOKEN='${REGISTRATION_TOKEN}' bash -s" <<'REMOTE'
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Remote script must run as root." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git gzip jq sudo tar

if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$RUNNER_USER"
fi

install -d -m 700 -o "$RUNNER_USER" -g "$RUNNER_USER" "/home/${RUNNER_USER}/.ssh"
touch "/home/${RUNNER_USER}/.ssh/authorized_keys"
if ! grep -qxF "$SSH_PUBLIC_KEY" "/home/${RUNNER_USER}/.ssh/authorized_keys"; then
  printf '%s\n' "$SSH_PUBLIC_KEY" >> "/home/${RUNNER_USER}/.ssh/authorized_keys"
fi
chown "$RUNNER_USER:$RUNNER_USER" "/home/${RUNNER_USER}/.ssh/authorized_keys"
chmod 600 "/home/${RUNNER_USER}/.ssh/authorized_keys"

printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$RUNNER_USER" > "/etc/sudoers.d/github-actions"
chmod 440 "/etc/sudoers.d/github-actions"
visudo -cf "/etc/sudoers.d/github-actions"

RUNNER_DIR="/home/${RUNNER_USER}/actions-runner"
RUNNER_TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TARBALL}"
SERVICE_PATTERN="actions.runner.${REPO//\//-}.*.service"

existing_services="$(systemctl list-units --all --type=service --no-legend "$SERVICE_PATTERN" 2>/dev/null | awk '{print $1}' || true)"
for service in $existing_services; do
  systemctl stop "$service" || true
  systemctl disable "$service" || true
done

install -d -m 755 -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_DIR"
cd "$RUNNER_DIR"

if [ ! -x ./config.sh ]; then
  rm -f "$RUNNER_TARBALL"
  curl -fL -o "$RUNNER_TARBALL" "$RUNNER_URL"
  printf '%s  %s\n' "$RUNNER_SHA256" "$RUNNER_TARBALL" | sha256sum -c -
  tar xzf "$RUNNER_TARBALL"
  chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"
fi

if [ -f .runner ]; then
  ./svc.sh uninstall || true
  sudo -u "$RUNNER_USER" ./config.sh remove --unattended --token "$REGISTRATION_TOKEN" || true
fi

sudo -u "$RUNNER_USER" ./config.sh \
  --url "https://github.com/${REPO}" \
  --token "$REGISTRATION_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --work "_work" \
  --replace \
  --unattended

./svc.sh install "$RUNNER_USER"
./svc.sh start

systemctl --no-pager --full status "$SERVICE_PATTERN" || true
sudo -u "$RUNNER_USER" sudo -n true
echo "Runner setup complete."
REMOTE

echo "Done. Check it with: ssh root@${RUNNER_HOST} 'systemctl status actions.runner.${REPO//\//-}.${RUNNER_NAME}.service --no-pager'"
