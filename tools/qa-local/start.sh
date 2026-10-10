#!/bin/bash
# (re)start the local stack: postgres + shim
su pguser -c "/usr/lib/postgresql/16/bin/pg_ctl -D /home/pguser/pg/data -o '-p 55432 -k /tmp' -l /home/pguser/pg/log status" >/dev/null 2>&1 || su pguser -c "/usr/lib/postgresql/16/bin/pg_ctl -D /home/pguser/pg/data -o '-p 55432 -k /tmp' -l /home/pguser/pg/log start" >/dev/null 2>&1
sleep 1
if ! curl -s -o /dev/null http://127.0.0.1:54321/; then
  cd $(dirname "$0")
  setsid nohup node shim.mjs >> shim.log 2>&1 < /dev/null &
  disown
  sleep 2
fi
curl -s -o /dev/null -w "shim http %{http_code}\n" http://127.0.0.1:54321/
