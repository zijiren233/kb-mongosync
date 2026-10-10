#!/bin/sh
# Wait for the config Secret (created outside Helm by kb-mongosync.sh) to
# appear, then start mongosync. The HTTP API binds localhost only (mongosync
# restriction outside Atlas Live Migrate), so access goes through
# kubectl port-forward. Exec replaces this shell so signals reach mongosync.
CONF=/etc/mongosync/conf.json
while true; do
  if [ -f "$CONF" ]; then
    exec mongosync --config "$CONF" --acceptDisclaimer
  fi
  sleep 2
done
