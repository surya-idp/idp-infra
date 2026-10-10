#!/usr/bin/env bash
# load-local-secrets.sh - copy credentials that must survive `make down` from the
# operator's laptop into Secrets Manager. Called by `make up` right after 20-data.
#
# Why: under the destroy-every-session lifecycle, 20-data recreates every secret with
# placeholders. A permanent secret would cost $0.40/month and break "$0 idle", so the
# source of truth for these few values is ~/.idp (mode 700/600), never Git or TF state.
#
#   idp/backstage-github-app   (Backstage: catalog, scaffolder, sign-in)
#     ~/.idp/backstage-app.env         APP_ID=..., CLIENT_ID=...  (not secret)
#     ~/.idp/backstage-app.pem         GitHub App private key
#     ~/.idp/backstage-client-secret   GitHub App client secret
#
#   idp/ci-bot-github-app      (Argo CD Image Updater: image tag commits to idp-gitops)
#     ~/.idp/ci-bot-app.env            APP_ID=..., INSTALLATION_ID=...  (not secret)
#     ~/.idp/ci-bot-app.pem            GitHub App private key
#
# Values travel via stdin only; nothing is printed or written to disk.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-idp}" AWS_PAGER=""
D="$HOME/.idp"

# have <secret-id> <consequence> <file>...  -> 0 if every file exists and is non-empty
have() {
  local id="$1" consequence="$2" missing=() f
  shift 2
  for f in "$@"; do
    [ -s "$D/$f" ] || missing+=("$f")
  done
  [ ${#missing[@]} -eq 0 ] && return 0
  echo "WARN: skipping $id - missing in $D: ${missing[*]}"
  echo "      $consequence"
  return 1
}

# put <secret-id>  (JSON on stdin)
put() {
  aws secretsmanager put-secret-value --region ap-south-1 \
    --secret-id "$1" --secret-string file:///dev/stdin --query 'Name' --output text
  echo "Loaded $1 from $D"
}

if have idp/backstage-github-app \
     "Backstage starts, but GitHub reads/writes and templates will fail." \
     backstage-app.env backstage-app.pem backstage-client-secret; then
  python3 - "$D" <<'PY' | put idp/backstage-github-app
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
env = dict(l.split("=", 1) for l in (d / "backstage-app.env").read_text().split() if "=" in l)
print(json.dumps({
    "appId": env["APP_ID"],
    "clientId": env["CLIENT_ID"],
    "clientSecret": (d / "backstage-client-secret").read_text().strip(),
    "privateKey": (d / "backstage-app.pem").read_text(),
}))
PY
fi

if have idp/ci-bot-github-app \
     "Services still deploy the first time, but later pushes are not rolled out (Image Updater cannot commit)." \
     ci-bot-app.env ci-bot-app.pem; then
  python3 - "$D" <<'PY' | put idp/ci-bot-github-app
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
env = dict(l.split("=", 1) for l in (d / "ci-bot-app.env").read_text().split() if "=" in l)
print(json.dumps({
    "appId": env["APP_ID"],
    "installationId": env["INSTALLATION_ID"],
    "privateKey": (d / "ci-bot-app.pem").read_text(),
}))
PY
fi
