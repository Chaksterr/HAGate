#!/bin/bash
# Site B HA cluster test through the existing CRUD app (index.php on employees).
#
#   ./scripts/cluster-crud-test.sh              # run, clean up afterwards
#   ./scripts/cluster-crud-test.sh --keep       # leave the zz- rows for inspection
#
# Requires: OPNsense B up, the four service VMs up, ansible reachable
# (see ../ansible/inventory.ini). Restores every service it stops and deletes
# every row it creates; the graded "Sarah Ben Ali" row is never modified.

set -u
cd "$(dirname "$0")/.." || exit 1

INV=(ansible -i ansible/inventory.ini)
VIP=10.15.15.100
MASTER=siteb-haproxy-master
BACKUP=siteb-haproxy-backup
WEB=siteb-web
DB=siteb-mysql
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

remote() { local h="$1"; shift; "${INV[@]}" "$h" -b -m shell -a "$*" 2>&1 | sed -n '2,$p'; }
owner()  { remote "$1" "ip -o a show enp0s8 | grep -c 'inet $VIP' || true"; }
dbq()    { remote "$DB" "mysql -N -e \"$1\""; }
vipcode(){ remote "$WEB" "curl -s -o /dev/null -m5 -w '%{http_code}' $1"; }

PASS=0; FAIL=0
ok()  { printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 (got '$2', want '$3')"; fi; }

restore() {
  [ "$KEEP" = "1" ] && { echo "--keep: leaving services as they are, rows in place"; return; }
  remote "$MASTER" "systemctl start keepalived; systemctl start haproxy" >/dev/null
  remote "$WEB"    "systemctl start apache2" >/dev/null
  remote "$DB"     "mysql -e \"DELETE FROM appdb.employees WHERE name LIKE 'zz-%'\"" >/dev/null
}
trap restore EXIT

TS=$(date +%s)
M="zz-cluster-$TS"

echo "== T0 baseline =="
chk "master owns the VIP"  "$(owner "$MASTER")" "1"
chk "backup does not"      "$(owner "$BACKUP")" "0"
chk "VIP answers 200"      "$(vipcode "http://$VIP/")" "200"

echo
echo "== T1 create via VIP, read from all three addresses =="
code=$(vipcode "-X POST -d action=create --data-urlencode name=$M -d job_title=Tester --data-urlencode email=$M@lab.lab http://$VIP/")
case "$code" in 302|200) ok "create via VIP (http $code)";; *) bad "create via VIP (http $code)";; esac
for u in 10.15.15.10 10.15.15.11 "$VIP"; do
  chk "row visible via $u" "$(remote "$WEB" "curl -s -m5 http://$u/ | grep -c 'value=\"$M\"'")" "1"
done
sizes=$(remote "$WEB" "for u in 10.15.15.10 10.15.15.11 $VIP; do curl -s -m5 http://\$u/ | wc -c; done | sort -u | wc -l")
chk "all three pages identical" "$sizes" "1"

echo
echo "== T2 data survives failover; writes work on the new master =="
ID=$(dbq "SELECT id FROM appdb.employees WHERE name='$M'")
echo "row id = $ID"
remote "$MASTER" "systemctl stop keepalived" >/dev/null
for i in $(seq 1 15); do [ "$(owner "$BACKUP")" = "1" ] && break; sleep 1; done
chk "backup took the VIP"   "$(owner "$BACKUP")" "1"
chk "master released it"    "$(owner "$MASTER")" "0"
chk "row survived failover" "$(remote "$WEB" "curl -s -m5 http://$VIP/ | grep -c 'value=\"$M\"'")" "1"
code=$(vipcode "-X POST -d action=update -d id=$ID --data-urlencode name=$M-upd -d job_title=Tester2 --data-urlencode email=$M@lab.lab http://$VIP/")
case "$code" in 302|200) ok "update via new master (http $code)";; *) bad "update via new master (http $code)";; esac
chk "update persisted in DB" "$(dbq "SELECT COUNT(*) FROM appdb.employees WHERE name='$M-upd' AND job_title='Tester2'")" "1"

echo
echo "== T3 20 concurrent writes across a failover =="
remote "$WEB" "rm -f /tmp/load.log; nohup bash -c 'for i in \$(seq 1 20); do c=\$(curl -s -o /dev/null -m 3 -w %{http_code} -X POST -d action=create --data-urlencode name=zz-load-$TS-\$i -d job_title=Load --data-urlencode email=load$TS\$i@lab.lab http://$VIP/); echo \"\$i \$c\" >> /tmp/load.log; sleep 0.2; done' >/dev/null 2>&1 & echo started" >/dev/null
sleep 3
remote "$MASTER" "systemctl start keepalived" >/dev/null
sleep 10
remote "$MASTER" "systemctl stop keepalived" >/dev/null
for i in $(seq 1 15); do [ "$(owner "$BACKUP")" = "1" ] && break; sleep 1; done
sleep 4
log=$(remote "$WEB" "cat /tmp/load.log")
sent=$(printf '%s\n' "$log" | wc -l | tr -d ' ')
wrote=$(printf '%s\n' "$log" | awk '$2==302 || $2==200' | wc -l | tr -d ' ')
rows=$(dbq "SELECT COUNT(*) FROM appdb.employees WHERE name LIKE 'zz-load-$TS-%'")
distinct=$(dbq "SELECT COUNT(DISTINCT name) FROM appdb.employees WHERE name LIKE 'zz-load-$TS-%'")
echo "responses=$sent successful=$wrote rows=$rows distinct=$distinct"
chk "every successful write has a row" "$rows" "$wrote"
chk "no duplicated rows" "$distinct" "$rows"

echo
echo "== T4 HAProxy health check vs a dead backend =="
remote "$MASTER" "systemctl start keepalived" >/dev/null; sleep 6
remote "$WEB" "systemctl stop apache2" >/dev/null; sleep 8
chk "VIP 503 with backend down"  "$(remote "$MASTER" "curl -s -o /dev/null -m5 -w '%{http_code}' http://$VIP/")" "503"
chk ".10 503 with backend down"  "$(remote "$MASTER" "curl -s -o /dev/null -m5 -w '%{http_code}' http://10.15.15.10/")" "503"
remote "$WEB" "systemctl start apache2" >/dev/null; sleep 8
chk "VIP recovers to 200"        "$(remote "$MASTER" "curl -s -o /dev/null -m5 -w '%{http_code}' http://$VIP/")" "200"

echo
echo "== T5 restore and integrity of the graded data =="
for i in $(seq 1 15); do [ "$(owner "$MASTER")" = "1" ] && break; sleep 1; done
chk "master preempted the VIP back" "$(owner "$MASTER")" "1"
restore
trap - EXIT
chk "test rows removed"   "$(dbq "SELECT COUNT(*) FROM appdb.employees WHERE name LIKE 'zz-%'")" "0"
chk "Sarah row intact"    "$(dbq "SELECT COUNT(*) FROM appdb.employees WHERE name='Sarah Ben Ali' AND job_title='Developer'")" "1"
chk "final VIP serves 200" "$(vipcode "http://$VIP/")" "200"
chk "keepalived active on master" "$(remote "$MASTER" 'systemctl is-active keepalived')" "active"
chk "keepalived active on backup" "$(remote "$BACKUP" 'systemctl is-active keepalived')" "active"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" = "0" ]
