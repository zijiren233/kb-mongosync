#!/bin/sh
# Wait for the config Secret (created outside Helm by kb-mongosync.sh) to
# appear, then start mongosync. Exec replaces this shell so signals reach
# mongosync directly.
CONF=/etc/mongosync/conf.json
while true; do
  if [ -f "$CONF" ]; then
    exec mongosync --config "$CONF" --acceptDisclaimer --acceptRemoteAPIRequest
  fi
  sleep 2
done
