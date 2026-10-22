# VPN-IT: Two-site interconnection (OPNsense, IPsec, HAProxy, Keepalived)


| Site | Student | LAN | Folder |
|---|---|---|---|
| A | Chakster | `10.0.2.0/24` | `site-a/` |
| B | Chammmeau | `10.15.15.0/24` | `site-b/` |

**Status:** Site A complete (parts 1 to 6). IPsec tunnel waits for Site B.

The config files (`Vagrantfile`, `ansible/group_vars/all.yml`, playbooks, roles, templates) are in the repo. This README only lists commands and remarks.

---

## 1. Architecture

```
Client -> OPNsense WAN (NAT 80) -> VIP 10.0.2.100 (Keepalived)
       -> HAProxy MASTER 10.0.2.5 / BACKUP 10.0.2.6
       -> Apache+PHP 10.0.2.7 -> MySQL 10.0.2.8
```

| Machine | IP | Role |
|---|---|---|
| OPNsense LAN | `10.0.2.1` | Gateway of the VMs |
| OPNsense WAN | `192.168.1.11` (DHCP, to be fixed) | NAT, IPsec |
| VIP | `10.0.2.100` | Moved by Keepalived |
| `sitea-haproxy-master` | `10.0.2.5` | Priority 110 |
| `sitea-haproxy-backup` | `10.0.2.6` | Priority 100 |
| `sitea-web` | `10.0.2.7` | Apache + PHP |
| `sitea-mysql` | `10.0.2.8` | Database |

Each VM has 2 cards: `enp0s3` (NAT, `192.168.250.15`, Vagrant SSH only) and `enp0s8` (internal network `siteA-lan`, the project LAN).

**Remarks**

- Only `ansible/group_vars/all.yml` differs between site-a and site-b.
- The NAT card was moved out of `10.0.2.0/24` with `--natnet1` to avoid overlap.

---

## 2. Prerequisites

```bash
ansible-galaxy collection install community.mysql
vagrant --version && VBoxManage --version && ansible --version
```

VirtualBox 7.x, Vagrant 2.4+, Ansible, OPNsense `dvd` amd64 ISO (26.7).

---

## 3. Create and verify the VMs (from `site-a/`)

```bash
vagrant validate
vagrant up --no-provision
vagrant status

for vm in sitea-mysql sitea-web sitea-haproxy-backup sitea-haproxy-master; do
  echo "== $vm"; vagrant ssh $vm -c "ip -br a"
done
vagrant ssh sitea-web -c "ping -c2 10.0.2.8"
VBoxManage showvminfo sitea-haproxy-master | grep -i "NIC 2"
```

---

## 4. OPNsense (manual VM)

| Setting | Value |
|---|---|
| Name / OS | `sitea-opnsense` / BSD, FreeBSD (64-bit) |
| RAM / CPU / Disk | 2048 MB / 2 / 15 GB dynamic |
| EFI / Unattended | Both unticked |
| Adapter 1 (WAN) | Bridged, Intel PRO/1000 MT Desktop, Promiscuous Allow All |
| Adapter 2 (LAN) | Internal Network exactly `siteA-lan`, same type, Allow All |

Logins: installer `installer` / `opnsense`; afterwards `root` / your password (lab `opn123`).

Console steps:
1. Option **1**: no LAGG, no VLAN, WAN = `em0`, LAN = `em1`.
2. Option **2**, LAN: DHCP `n`, `10.0.2.1` / `24`, no gateway, no DHCP server, GUI questions `n`.
3. WAN stays on DHCP (`192.168.1.11`, gateway `192.168.1.1`).
4. Option **7**: ping `192.168.1.1` and `1.1.1.1` must work.

GUI (reachable from the LAN only) and SSH:

```bash
vagrant ssh sitea-web -- -L 8443:10.0.2.1:443     # https://127.0.0.1:8443 (use the IP)
vagrant ssh sitea-web -- -L 8444:10.0.2.1:22      # ssh -p 2222 root@127.0.0.1 (then option 8)
vagrant ssh sitea-web -c "nc -zv 10.0.2.1 22"
```

**Remarks**
- Remove the ISO after install (Settings, Storage), otherwise it boots into the installer again.
- Interfaces, WAN: untick **Block private networks** and **Block bogon networks**, then Save and Apply.
- SSH is off by default: console option 14, or System, Settings, Administration. Keep it on the LAN only.
- After reinstalling OPNsense: `ssh-keygen -R 10.0.2.1`.

---

## 5. Ansible (from `site-a/`)

```bash
ansible-playbook ansible/network.yml               # 1. gateway = OPNsense (OPNsense must be up)
ansible-playbook ansible/site.yml                  # 2. mysql, web, haproxy, keepalived
ansible-playbook ansible/site.yml --tags mysql     # one role only (mysql, web, haproxy, keepalived)
```

Checks per role:

```bash
vagrant ssh sitea-web -c "ip route get 1.1.1.1"                          # via 10.0.2.1
vagrant ssh sitea-mysql -c "sudo ss -tlnp | grep 3306"                   # 10.0.2.8:3306
vagrant ssh sitea-web -c "nc -zv -w3 10.0.2.8 3306"                      # succeeded
vagrant ssh sitea-web -c "curl -s http://localhost | grep -c 'Sarah Ben Ali'"   # 1
```

Manual gateway equivalent: `sudo ip route replace default via 10.0.2.1 dev enp0s8`

**Remarks**
- Run `network.yml` first: `apt` needs Internet through OPNsense.
- The default route is lost after `vagrant reload`: rerun `network.yml`.
- HAProxy must be deployed before Keepalived (its health script watches HAProxy).
- MySQL config is `zz-lan.cnf` (not `99-lan.cnf`): it must sort after Ubuntu's `mysqld.cnf` to win.
- HAProxy binds `*:80`, not the VIP, so the BACKUP can start.
- If HAProxy stops, MASTER priority drops 110 to 90 (below 100) and the VIP moves in 3 to 4 s.
- `vrid` and `vrrp_pass` must be identical on both HAProxy nodes.

---

## 6. Tests inside the LAN

```bash
# HAProxy nodes answer
vagrant ssh sitea-web -c "curl -sI -m 5 http://10.0.2.5 | head -1; curl -sI -m 5 http://10.0.2.6 | head -1"

# VIP only on the master
vagrant ssh sitea-haproxy-master -c "ip a show enp0s8 | grep 10.0.2.100"      # present
vagrant ssh sitea-haproxy-backup -c "ip a show enp0s8 | grep 10.0.2.100"      # nothing

# Site through the VIP, services
vagrant ssh sitea-web -c "curl -sI -m 5 http://10.0.2.100 | head -1"          # 200 OK
vagrant ssh sitea-haproxy-master -c "systemctl is-active haproxy keepalived"

# Failover (Keepalived)
vagrant ssh sitea-haproxy-master -c "sudo systemctl stop keepalived"
sleep 5
vagrant ssh sitea-haproxy-backup -c "ip a show enp0s8 | grep 10.0.2.100"      # VIP here
vagrant ssh sitea-web -c "curl -sI -m 5 http://10.0.2.100 | head -1"          # still 200
vagrant ssh sitea-haproxy-master -c "sudo systemctl start keepalived"

# Failover (HAProxy crash, tests the tracking script)
vagrant ssh sitea-haproxy-master -c "sudo systemctl stop haproxy"
sleep 6
vagrant ssh sitea-haproxy-backup -c "ip a show enp0s8 | grep 10.0.2.100"
vagrant ssh sitea-haproxy-master -c "sudo systemctl start haproxy"
```

---

## 7. Publish the site (NAT)

`<WAN IP>` is the WAN address of **your own** OPNsense (`em0`), here `192.168.1.11`.

**Firewall, NAT, Destination NAT, Add:**

| Field | Value |
|---|---|
| Interface / Version / Protocol | WAN / IPv4 / TCP |
| Destination | WAN address |
| Destination port | HTTP (80) |
| Redirect target IP / port | `10.0.2.100` (the VIP) / HTTP (80) |
| Filter rule association | **Pass** |

Fallback if the test times out: Firewall, Rules, WAN, Add: Pass, in, TCP, source any, destination `10.0.2.100/32`, port 80. The destination is the VIP, not the WAN address, because the redirect is applied before the filter.

Tests from the PC:

```bash
curl -I -m 5 http://192.168.1.11                        # 200 OK
curl -s http://192.168.1.11 | grep -c "Sarah Ben Ali"   # 1
nc -zv -w3 192.168.1.11 3306                            # must time out (isolation)

# failover from the PC
while true; do curl -s -o /dev/null -m 2 -w "%{http_code}\n" http://192.168.1.11; sleep 1; done
vagrant ssh sitea-haproxy-master -c "sudo systemctl stop keepalived"     # other terminal
vagrant ssh sitea-haproxy-master -c "sudo systemctl start keepalived"
```

**Remarks**
- A timeout on 3306 is the pass: no rule exists, OPNsense drops silently.
- Save System, Configuration, Backups, Download to `opnsense/config.xml`. Do not publish it (password hashes).

```bash
git add -A && git commit -m "part 6: nat destination redirect done" && git push
```

---

## 8. Before meeting Site B

**Fix the WAN address** (it is the tunnel identity), one of:
- **A: router reservation.** Get the MAC (`ifconfig em0 | grep ether`, expected `08:00:27:7d:d6:55`), bind it to `192.168.1.11` at `http://192.168.1.1`, reboot the router, check the address stays.
- **B: static in OPNsense.** Pick a free IP outside the DHCP range (e.g. `192.168.1.200`, check `ping` and `arp -n`). Console option **2**, then **2** (WAN): DHCP `n`, address, `24`, gateway `192.168.1.1`. Then System, Settings, General: DNS `1.1.1.1`, `8.8.8.8`, untick "Allow DNS server list to be overridden". Retest with `curl -I -m 5 http://192.168.1.200`.

**Save deliverables:**

```bash
mkdir -p configs opnsense docs tests/captures
vagrant ssh sitea-haproxy-master -c "cat /etc/haproxy/haproxy.cfg" > configs/haproxy.cfg
vagrant ssh sitea-haproxy-master -c "sudo cat /etc/keepalived/keepalived.conf" > configs/keepalived.conf
```

**Exchange sheet:**

| Item | Site A | Site B |
|---|---|---|
| WAN IP | `192.168.1.11` (or fixed one) | `192.168.1.___` |
| LAN | `10.0.2.0/24` | must be `10.15.15.0/24` |
| PSK | `ipsec123`, identical both sides | |

Both WANs must reach each other (same network, or UDP 500 and 4500 forwarded).

---

## 11. Troubleshooting

`curl http://<WAN IP>` hangs: test from inside out, with `-m 5`.

| Step | Command | Meaning |
|---|---|---|
| 1 | `vagrant ssh sitea-web -c "curl -sI -m 5 http://10.0.2.100 \| head -1"` | 200: site and VIP fine, look at OPNsense |
| 2 | `vagrant ssh sitea-haproxy-master -c "ip route \| grep default"` | Lowest metric must be `via 10.0.2.1 dev enp0s8` |
| 3 | OPNsense, Firewall, Log Files, Live View, port 80 | Nothing: no arrival. Red: blocked. Green: return path |
| 4 | OPNsense shell: `tcpdump -ni em0 tcp port 80`, then `-ni em1` | Shows WAN arrival and LAN exit |

If nothing arrives on `em0`: `arp -n | grep <WAN IP>` on the PC, check Adapter 1 is bridged on the card the PC really uses (Wi-Fi bridging is unreliable, try Ethernet or a phone), check Block private/bogon are off and the Pass rule to `10.0.2.100:80` exists.

| Symptom | Fix |
|---|---|
| VMs cannot ping `10.0.2.1` | Adapter 2 must be named exactly `siteA-lan`; check LAN IP |
| `em0` and `em1` swapped | Redo console option 1, compare MACs |
| OPNsense boots into installer | Remove the ISO |
| `apt` fails in Ansible | Redo OPNsense, run `network.yml` |
| MySQL on `127.0.0.1` / page DB error | `ansible-playbook ansible/site.yml --tags mysql` |
| Both HAProxy nodes show the VIP | Check `vrid`/password; `sudo tcpdump -i enp0s8 vrrp` |
| No Internet after `vagrant reload` | Rerun `network.yml` |
| `NO_PROPOSAL_CHOSEN` | Algorithms or DH differ |
| `AUTHENTICATION_FAILED` | Re-paste PSK, check swapped IDs |
| `TS_UNACCEPTABLE` | Swap local/remote networks on one side |
| Tunnel up, ping fails | Missing rule on the IPsec tab (step 6) |

---

## 12. Command cheat sheet

```bash
# Vagrant (from site-a/)
vagrant up --no-provision | status | halt | reload | destroy -f
vagrant ssh sitea-web

# Ansible
ansible-playbook ansible/network.yml
ansible-playbook ansible/site.yml [--tags mysql]

# Tests
curl -I -m 5 http://<WAN IP>
nc -zv -w3 <WAN IP> 3306            # must fail

# OPNsense tunnels
vagrant ssh sitea-web -- -L 8443:10.0.2.1:443     # GUI
vagrant ssh sitea-web -- -L 8444:10.0.2.1:22      # SSH
```