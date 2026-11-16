#!/usr/bin/env bash
set -u
# Daily keep-alive for the Puzzle Pig Supabase project (Free plan pauses after
# inactivity). Calls the public keep_alive() function four times; every ping
# should print "ok" HTTP 200. Uses only the public (publishable) key.
KEY='sb_publishable_KEKSIwChDxC0pvL8WoWQhQ_Otvl7NL_'
BASE='https://qwnbycvkrxikgxsrncen.supabase.co/rest/v1'
for i in 1 2 3 4; do
  body=$(curl -s -w ' HTTP %{http_code}' --max-time 30 -X POST -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{}' "$BASE/rpc/keep_alive")
  echo "ping $i: $body"
  sleep 5
done
