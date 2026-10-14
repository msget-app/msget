#!/bin/sh
# Start msget headless beside this script, unless it already runs.
# Exit 7 from `msget ctl status` means the service is not reachable.
set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$DIR"

./msget ctl status >/dev/null 2>&1
if [ "$?" -ne 7 ]; then
    echo "already running"
    exit 0
fi

nohup ./msget --no-dashboard --state-dir "$DIR/state" --web-bind 127.0.0.1:8739 >>"$DIR/msget.log" 2>&1 &
attempts=0
while [ "$attempts" -lt 30 ]; do
    sleep 1
    attempts=$((attempts + 1))
    ./msget ctl status >/dev/null 2>&1
    if [ "$?" -ne 7 ]; then
        ./msget ctl status --json
        exit 0
    fi
done
echo "msget did not become reachable within 30 seconds; see $DIR/msget.log" >&2
exit 1
