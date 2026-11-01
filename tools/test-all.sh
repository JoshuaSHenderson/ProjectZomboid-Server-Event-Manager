#!/usr/bin/env bash
# Starts the isolated test server with A-Life, waits for it, then opens both clients. Run from repo root: bash tools/test-all.sh
# A server already on the port is kept. Stop it first after any Lua change: clients must match its files.
[ -d ServerEventManager/Contents ] || { echo "run from repo root" >&2; exit 1; }
if netstat -ano | grep -q ':16261'; then
    echo "Server already running"
else
    rm -f .testserver.out
    SEM_ALIFE=1 timeout 10800 bash tools/test-server.sh > .testserver.out 2>&1 &
    echo "Starting server, about 75 seconds..."
    for _ in $(seq 1 60); do
        grep -q '\[SEM\] server loaded' .testserver.out 2>/dev/null && break
        ping -n 4 127.0.0.1 > /dev/null
    done
    grep -q '\[SEM\] server loaded' .testserver.out || { echo "Server did not load, see .testserver.out" >&2; exit 1; }
    echo "Server ready"
fi
bash tools/test-client.sh 1 > .testclient1.out 2>&1 &
bash tools/test-client.sh 2 > .testclient2.out 2>&1 &
echo "Client 1: 127.0.0.1 port 16261, user admin, password semtest"
echo "Client 2: 127.0.0.1 port 16261, any other username and password"
wait
