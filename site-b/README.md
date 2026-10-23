# Site B — Ansible provisioning (mirror of `site-a/`)

Same roles as Site A, Site B values. Only the variables differ.

| | Site A | Site B |
|---|---|---|
| Folder | `site-a/` | `site-b/` |
| LAN | `10.0.2.0/24` | `10.15.15.0/24` |
| Gateway | `10.0.2.1` | `10.15.15.1` |
| web / db | `.7` / `.8` | `10.15.15.7` / `10.15.15.8` |
| haproxy master / backup | `.5` / `.6` | `10.15.15.10` / `10.15.15.11` |
| VIP | `10.0.2.100` | `10.15.15.100` |
| vrid | 51 | 52 |
| vrrp pass | `Secret12` | `Lab12345` |
| priorities | 110 / 100 | 150 / 100 |
| DB | `appdb` / `app` / `app123` | same |
| HAProxy bind | VIP (`ip_nonlocal_bind`) | `*:80` (`haproxy_bind: "*"`) |

## Where the VMs come from

This folder has **no Vagrantfile on purpose**: the four VMs are created by
`../../vagrant/Vagrantfile` (repo root `infra/`), the same place as
`siteb-client` and `isp-router`.

```bash
cd /home/jmal/Desktop/infra/vagrant
vagrant up siteb-mysql siteb-web siteb-haproxy-master siteb-haproxy-backup
vagrant status
```

Vagrant assigns host SSH ports dynamically (2200, 2201, ...). `ansible/inventory.ini`
contains the current values; if a VM is destroyed/recreated, refresh them:

```bash
cd /home/jmal/Desktop/infra/vagrant
for v in siteb-mysql siteb-web siteb-haproxy-master siteb-haproxy-backup; do
  printf '%-24s ' "$v"; vagrant ssh-config $v | awk '/Port/{print $2}'
done
```

## Prerequisites

```bash
ansible --version                      # >= 2.14
ansible-galaxy collection install community.mysql
```

OPNsense B must be up with LAN `10.15.15.1` reachable from the VMs and WAN
Internet working — `network.yml` relies on it (`apt` through the firewall).

## Run

From `site-b/`:

```bash
ansible -i ansible/inventory.ini all -m ping          # connectivity
ansible-playbook ansible/network.yml                  # 1. default route via OPNsense
ansible-playbook ansible/site.yml                     # 2. mysql, web, haproxy, keepalived
ansible-playbook ansible/site.yml --tags mysql        # single role
```

Tags: `network`, `mysql`, `web`, `haproxy`, `keepalived`.

## Verification

```bash
# route
ansible -i ansible/inventory.ini all -m shell -a "ip route get 1.1.1.1"

# database, from the web node (needs a client: sudo apt install mysql-client-core-8.0)
cd /home/jmal/Desktop/infra/vagrant
vagrant ssh siteb-web -c "mysql -h 10.15.15.8 -u app -p'app123' -N -e 'SELECT id,name,job_title,email FROM appdb.employees;'"

# web page
vagrant ssh siteb-client -c "curl -s http://10.15.15.7 | grep -c 'Sarah Ben Ali'"

# HAProxy per node and through the VIP
vagrant ssh siteb-client -c "curl -sI -m5 http://10.15.15.10 | head -1"
vagrant ssh siteb-client -c "curl -sI -m5 http://10.15.15.11 | head -1"
vagrant ssh siteb-client -c "curl -sI -m5 http://10.15.15.100 | head -1"

# VIP only on the master
vagrant ssh siteb-haproxy-master -c "ip -br a show enp0s8 | grep 10.15.15.100"
vagrant ssh siteb-haproxy-backup -c "ip -br a show enp0s8 | grep 10.15.15.100 || echo absent"
```

## Failover (Test 2)

```bash
cd /home/jmal/Desktop/infra/vagrant
vagrant ssh siteb-haproxy-master -c "sudo systemctl stop keepalived"
sleep 5
vagrant ssh siteb-haproxy-backup -c "ip -br a show enp0s8 | grep 10.15.15.100"
vagrant ssh siteb-client -c "curl -sI -m5 http://10.15.15.100 | head -1"
vagrant ssh siteb-haproxy-master -c "sudo systemctl start keepalived"
```

`systemctl stop keepalived` releases the VIP at once; the backup promotes in
~1 s (measured, one 0.25 s probe sample lost).

A HAProxy crash (keepalived alive) is covered by `track_script chk_haproxy`
with `weight -60`: 150 − 60 = 90 < 100. Measured: VIP on the backup after 5 s,
VIP served `200` with the master's HAProxy dead, preempted back on restart.
Site A's template value `-20` would leave 130 > 100 and no failover, hence the
`vrrp_weight` variable below.

## Verified on the live VMs (2026-10-23)

Full run log, findings and evidence: `../../knowledge/site-b-ansible-verification.md`.

`network.yml` and `site.yml` both ran green (`failed=0` on all four hosts), then:

| Check | Command | Result |
|---|---|---|
| LAN address written | `ip -br a show enp0s8` | `10.15.15.7/.8/.10/.11` UP |
| Route via OPNsense | `ip route get 1.1.1.1` | `via 10.15.15.1 dev enp0s8` |
| Internet through OPNsense | `getent ahostsv4 archive.ubuntu.com`, `curl -I http://archive.ubuntu.com` | resolves, `200` |
| DB row exists | `mysql -N -e 'SELECT id,name,job_title,email FROM appdb.employees;'` | `1  Sarah Ben Ali  Developer  sarah@olive.lab` |
| DB listening on the LAN | `ss -lntp \| grep 3306` | `10.15.15.8:3306` |
| **Test 3** — DB from the web host | `mysql -h 10.15.15.8 -u app -p'app123' …` (run on `siteb-web`) | row returned |
| Web page from the DB | `curl -s http://10.15.15.7 \| grep -c 'Sarah Ben Ali'` | page renders `Employees (1)` |
| HAProxy per node + VIP | `curl -o /dev/null -w '%{http_code}'` on `.10`, `.11`, `.100` | `200` / `200` / `200` |
| VIP ownership | `ip -o a show enp0s8 \| grep 10.15.15.100` | master `1`, backup `0` |

Actual column names are `id, name, job_title, email` (no `role` column).

### Failover result

Probe from `siteb-web` (neutral host) hitting the VIP every 0.25 s while
`systemctl stop keepalived` ran on the master:

* VIP left the master immediately, appeared on the backup in ~1 s
* exactly one probe sample was non-`200` (a single ~0.25 s gap)
* `curl http://10.15.15.100/` returned `200` after the move
* restarting keepalived on the master preempts the VIP back (backup releases it)
* HAProxy killed on the master instead (keepalived alive): VIP moved in ~5 s,
  18 probe samples lost (~4.5 s), then `200` through the VIP; preempted back
  when HAProxy restarted

## Cluster test (existing CRUD app)

`scripts/cluster-crud-test.sh` drives the deployed `index.php` instead of
inspecting config, and asserts cluster behaviour: the same page via `.10`,
`.11` and the VIP; a row written before failover is still readable and
updatable through the VIP afterwards; 20 concurrent writes across a failover
produce no lost or duplicated rows; a dead Apache turns the VIP into `503` and
back to `200`.

```bash
cd /home/jmal/Desktop/infra/vagrant/site-b     # or VPN-IT/site-b
./scripts/cluster-crud-test.sh          # 24 checks; restores services, deletes zz- rows
./scripts/cluster-crud-test.sh --keep   # keep the test rows for inspection
```

Latest run: **24 passed, 0 failed** (2026-10-23). The graded
`Sarah Ben Ali` row is never written to.

## Deviations from `site-a/`

| Role | Change | Reason |
|---|---|---|
| `network` | writes `/etc/netplan/01-lab.yaml` (NAT nic + static LAN address) and drops `50-cloud-init.yaml`/`99-default-route.yaml`; `lan_ip` comes from the inventory | our `Vagrantfile` creates the LAN nic with `auto_config: false`, so nothing assigns `10.15.15.x` — site-a's Vagrant does it for them. Without this the role's checks fail with the interface DOWN |
| `mysql` | `ALTER USER ... IDENTIFIED BY` added | an existing user created by hand keeps its old password; keeps the play idempotent |
| `web` | removes a previous Nginx install | the web VM may have been built by hand with Nginx first; Apache must own port 80 |
| `haproxy` | `bind {{ haproxy_bind }}:80` | Site A binds the VIP, Site B binds `*:80` so each node is testable directly |
| `keepalived` | `weight {{ vrrp_weight }}` instead of a hard-coded `-20`; `vrrp_weight: -60` in `group_vars/all.yml` | 150 + (−60) = 90 < 100, so a **dead HAProxy** also moves the VIP; Site A's 110/100 works with `-20` |
| `inventory` | absolute key paths, dynamic ports, `lan_ip` per host | the VMs are Vagrant-managed from `infra/vagrant`, not from this folder |

`site.yml`, `network.yml`, `ansible.cfg` are byte-identical to Site A. The
structural changes are `network` (netplan for `auto_config: false`),
`keepalived` (`vrrp_weight` variable) and the values in `group_vars/all.yml`.

## Next

WAN publish (Test 1): OPNsense Destination NAT TCP 80 → `10.15.15.100` + Pass rule
to the VIP (GUI, manual — see `SiteB_Manual_Runbook.md` §12). IPsec (Tests 5–6)
waits for the meeting with Site A — see `../../knowledge/site-a-integration.md`
in the `infra` repo.
