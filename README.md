# nginx-block-bad-ips-free

Block known-bad IP addresses in **nginx** using **free, public blocklists**. It works with
**HestiaCP**, **Plesk** and plain nginx, and checks the **real client IP** even when your
sites sit behind Cloudflare or another proxy.

- One-command install and uninstall (`install.sh` / `uninstall.sh`, both with `--help`).
- A **safe** set of lists by default. You can add an **aggressive** set, single lists or
  **your own lists**.
- A **whitelist** that always wins. Cloudflare, private ranges and the server itself are always allowed.
- Optional **GeoIP** (country) blocking, for the whole site or only for paths such as `/wp-login.php`.
- Every change runs through `nginx -t` first and is **rolled back automatically** if the test fails.
  nginx is only ever **reloaded, never restarted**.
- Lists are refreshed daily by cron. New vhosts are protected within an hour.

---

## Contents

1. [How it works](#how-it-works)
2. [Supported systems](#supported-systems)
3. [Install](#install)
4. [Lists used and why](#lists-used-and-why)
5. [Safe vs aggressive](#safe-vs-aggressive)
6. [Custom lists](#custom-lists)
7. [Whitelist](#whitelist)
8. [Proxies, Cloudflare and the real client IP](#proxies-cloudflare-and-the-real-client-ip)
9. [GeoIP (optional)](#geoip-optional)
10. [Updates, testing and rollback](#updates-testing-and-rollback)
11. [Command reference](#command-reference)
12. [Files](#files)
13. [Troubleshooting](#troubleshooting)
14. [Uninstall](#uninstall)
15. [License](#license)
16. [Legal notice](#legal-notice)

---

## How it works

```
            request
               |
   [realip]    |  behind Cloudflare/proxy? take the client IP from the header,
               |  but only when the connection comes from a trusted proxy
               v
          $remote_addr  (the real client IP)
               |
   +-----------+-------------+------------------------+
   |                         |                        |
geo $nbbi_whitelisted   geo $nbbi_listed        geo $nbbi_geo4/6 (optional)
(built-in + Cloudflare  (all enabled lists)     (country of the IP)
 + this server +                                  + map on $uri (optional paths)
 whitelist.txt)
   |                         |                        |
   +-----------+-------------+------------------------+
               v
   map -> $nbbi_block = 1 when NOT whitelisted AND (listed OR GeoIP-denied on a protected path)
               |
   every protected vhost:  if ($nbbi_block) { return 403; }
```

- The lookups use nginx's built-in `geo` module, a radix tree or sorted ranges, so they add
  practically no latency even with tens of thousands of entries. No extra nginx module is needed.
- The whitelist, the blocklist and GeoIP live in **separate** variables and are combined in a
  `map`. That is why a whitelisted network always wins, even when a list contains a more specific
  address inside it.
- The block include is added to each vhost using the control panel's own customisation hooks, so
  panel rebuilds keep it:

| Environment | Where the include goes |
|---|---|
| HestiaCP | `/home/<user>/conf/web/<domain>/nginx.conf_nginx-block-bad-ips` and `nginx.ssl.conf_nginx-block-bad-ips` (also webmail) |
| Plesk | A marked block in `/var/www/vhosts/system/<domain>/conf/vhost_nginx.conf` (the panel's "Additional nginx directives"). If the file did not exist, it is created and Plesk regenerates that domain with `httpdmng --reconfigure-domains … -no-restart` |
| Plain nginx | You add `include /etc/nginx/nginx-block-bad-ips/enforce.conf;` to each `server {}`, or use `--auto-inject` |

An hourly `sync` adds the include to domains created after the install.

## Supported systems

| OS | Mode | Status |
|---|---|---|
| Ubuntu 26.04 | HestiaCP 1.10 (nginx + PHP-FPM) | Field-tested |
| Ubuntu 24.04 | HestiaCP 1.9 (nginx + Apache) | Field-tested |
| Ubuntu 22.04, 26.04 | Plesk Obsidian 18.0 | Field-tested |
| Rocky Linux 8 | Plesk Obsidian 18.0 | Field-tested |
| AlmaLinux 10 | Plesk Obsidian 18.0 | Field-tested |
| Ubuntu 24.04, 26.04 | plain nginx (distro package, `sites-enabled` symlinks, `--auto-inject`; mawk and gawk) | Field-tested |
| Rocky Linux 8, 9, 10 | plain nginx (distro package 1.14 / 1.20 / 1.26, `--auto-inject`, SELinux enforcing) | Field-tested |
| Ubuntu 22.04 | plain nginx | Supported, not yet field-tested |
| AlmaLinux 8, 9 | Plesk or plain nginx | Supported, not yet field-tested |
| AlmaLinux 10 | plain nginx | Supported, not yet field-tested |

On Rocky Linux and AlmaLinux, SELinux labels of the generated files are restored with
`restorecon`.

Panel support also depends on the panel vendor supporting that OS: HestiaCP runs on
Debian/Ubuntu only, and Plesk supports Rocky Linux 8 but not Rocky Linux 9 or 10 (on EL9/EL10
Plesk runs on AlmaLinux, RHEL or CloudLinux).

Requirements:
- nginx with the realip module. It is included in the nginx builds of Ubuntu, Rocky Linux, AlmaLinux,
  nginx.org, HestiaCP and Plesk.
- bash 4+, curl, cron and logrotate. Missing packages are installed with your confirmation, or
  automatically with `--yes`.

Other distributions may work with `--force`, but they are not supported.

## Install

```bash
git clone https://github.com/franciscopaniskaseker/nginx-block-bad-ips-free.git
cd nginx-block-bad-ips-free

sudo ./install.sh --help      # all options
sudo ./install.sh --dry-run   # download, validate and show what would change; touches nothing
sudo ./install.sh             # install with the safe lists
```

The installer:

1. Checks the OS and nginx. It refuses to continue if `nginx -t` already fails.
2. Installs the CLI to `/usr/local/sbin/nginx-block-bad-ips` and writes `/etc/nginx-block-bad-ips/`.
3. Downloads the lists, generates the nginx files and adds the include to every vhost. It then runs
   `nginx -t` and a reload, or rolls back.
4. Adds a cron job and a logrotate rule, then prints `nginx-block-bad-ips status`.

Re-running `install.sh` upgrades the code and keeps your configuration and whitelist. Any flag you
pass changes the stored setting.

### Installer options

| Option | Meaning |
|---|---|
| `-h`, `--help` | Show help |
| `-y`, `--yes` | Non-interactive; install missing packages |
| `--dry-run` | Render everything into a temporary directory and report. Nothing is changed |
| `--force` | Allow an unsupported OS |
| `--profile safe\|aggressive` | Choose a list profile (default: safe) |
| `--lists a,b,c` | Enable exactly these catalog lists |
| `--custom-list NAME=URL` | Add your own list (repeatable) |
| `--whitelist IP[,CIDR]` | Add addresses to the whitelist (repeatable) |
| `--realip auto\|managed\|off` | Real client IP handling (default: auto) |
| `--real-ip-header NAME` | Header with the client IP (default: `CF-Connecting-IP`) |
| `--trusted-proxy CIDR` | Trust a proxy or load balancer to send that header (repeatable) |
| `--enable-geoip` / `--disable-geoip` | Turn GeoIP on or off |
| `--geoip-countries CC,CC` | Two-letter country codes |
| `--geoip-mode allow\|deny` | `allow`: only these countries pass (default); `deny`: these countries are blocked |
| `--geoip-paths REGEX` | Apply GeoIP only to matching URIs (default: whole site) |
| `--geoip-unknown allow\|block` | Addresses that belong to no country (default: allow) |
| `--block-status 403\|444` | Response for blocked clients. 444 closes the connection |
| `--panel auto\|hestia\|plesk\|none` | Panel integration (default: auto-detect) |
| `--auto-inject` / `--no-auto-inject` | Plain nginx: add or stop adding the include to server blocks automatically |

Examples:

```bash
# more coverage, and never block the office
sudo ./install.sh --profile aggressive --whitelist 203.0.113.10,198.51.100.0/24

# WordPress: only Brazil and Portugal may open wp-login.php
sudo ./install.sh --enable-geoip --geoip-countries BR,PT --geoip-paths '^/wp-login\.php$'

# behind a load balancer (10.0.0.5) that sends X-Forwarded-For
sudo ./install.sh --realip managed --real-ip-header X-Forwarded-For --trusted-proxy 10.0.0.5
```

## Lists used and why

All lists are free and public. They are downloaded once a day, at a random time chosen at install
so the providers don't all get hit at the same moment. Each entry is validated strictly, and a
failed or suspiciously small download keeps the previous good copy.

| Name | Profile | What it contains | Why it is used |
|---|---|---|---|
| `spamhaus_drop` | safe | [Spamhaus DROP](https://www.spamhaus.org/blocklists/do-not-route-or-peer/): netblocks hijacked or leased by spammers and cybercriminals (the former EDROP was merged into it) | These networks carry no legitimate traffic. Almost zero false positives |
| `spamhaus_drop_v6` | safe | Spamhaus DROP for IPv6 | Same as above, for IPv6 |
| `firehol_level1` | safe | [FireHOL level 1](https://iplists.firehol.org/?ipset=firehol_level1): a conservative aggregate of DROP, DShield top attackers, Feodo botnet C2 servers and bogons | Designed by FireHOL for every internet-facing server, with minimum false positives. The bogon/private ranges it contains are neutralised by the built-in whitelist |
| `et_compromised` | safe | [Emerging Threats](https://rules.emergingthreats.net/blockrules/) compromised hosts | Small, curated list of machines actively used in attacks |
| `blocklist_de` | aggressive | [blocklist.de](https://www.blocklist.de/): IPs reported by fail2ban servers worldwide in the last 48 h (SSH, WordPress and mail brute force) | Very effective against brute force. Reported IPs can be dynamic or shared (mobile CGNAT), so false positives are possible |
| `cins_army` | aggressive | [CINS Army](https://cinsscore.com/#list): active scanners and attackers seen by the Sentinel IPS network | Catches scanning and intrusion attempts early |
| `ipsum_3` | aggressive | [IPsum](https://github.com/stamparm/ipsum) level 3: IPs that appear on 3 or more public blacklists | Consensus of many feeds: broad, but each IP is confirmed by several sources |
| `greensnow` | aggressive | [GreenSnow](https://greensnow.co/): brute force and port scanning sources | Complements blocklist.de |
| `firehol_level2` | extra | FireHOL level 2: attacks in the last 48 h | Broader. Enable by name only if you accept more false positives |
| `firehol_level3` | extra | FireHOL level 3: attacks, spyware and viruses in the last 30 days | Broadest. Enable by name only if you accept more false positives |

Other data sources:
- **Cloudflare ranges** come from [cloudflare.com/ips](https://www.cloudflare.com/ips/), with a
  bundled fallback.
- **Country data** comes from [ipdeny.com](https://www.ipdeny.com/), derived from the regional
  internet registries.

Each provider has its own terms of use, especially for commercial use or frequent downloads. Check
them before relying on a list. Run `nginx-block-bad-ips lists` to see every list, whether it is
enabled and how many entries it has.

## Safe vs aggressive

- **safe** (default): `spamhaus_drop`, `spamhaus_drop_v6`, `firehol_level1`, `et_compromised`.
  About 7,000 entries, focused on networks and hosts that are malicious beyond reasonable doubt.
- **aggressive**: safe + `blocklist_de`, `cins_army`, `ipsum_3`, `greensnow`. Several tens of
  thousands of entries. Better against brute force and scanners, with a small chance of blocking a
  real visitor who shares an IP with an attacker.

```bash
nginx-block-bad-ips lists profile aggressive      # switch profile
nginx-block-bad-ips lists enable blocklist_de     # or pick single lists
nginx-block-bad-ips lists disable cins_army
```

## Custom lists

A custom list is any URL (`http://`, `https://` or `file://`) with one IPv4 or IPv6 address or
CIDR per line.
- Only the first word of each line is used; comments starting with `#` or `;` are ignored.
- Entries broader than /8 (IPv4) or /16 (IPv6) are ignored for safety.

```bash
nginx-block-bad-ips lists add-custom my_company https://example.com/blocklist.txt
nginx-block-bad-ips lists add-custom local_bans file:///etc/nginx-block-bad-ips/local-bans.txt
nginx-block-bad-ips lists remove-custom my_company
```

Custom lists are stored in `/etc/nginx-block-bad-ips/custom-lists.conf` and are always active.

## Whitelist

`/etc/nginx-block-bad-ips/whitelist.txt` holds one address or CIDR per line. **The whitelist always
wins**: over every list and over GeoIP.

```bash
nginx-block-bad-ips whitelist add 203.0.113.10 2001:db8:1234::/48
nginx-block-bad-ips whitelist remove 203.0.113.10
nginx-block-bad-ips whitelist list
```

If you edit the file by hand, run `nginx-block-bad-ips apply` afterwards.

These are **always allowed** without being listed:
- **Cloudflare** ranges.
- Loopback, RFC1918 private ranges, carrier-grade NAT (100.64/10), link-local and IPv6 ULA.
- Every address of the server itself.
- The trusted proxies you configured.

`uninstall.sh` copies the whitelist to `/root/` before removing anything.

## Proxies, Cloudflare and the real client IP

Behind Cloudflare or a load balancer, the TCP connection comes from the proxy, not from the
visitor. The real IP is in a header. nginx's realip module replaces `$remote_addr` with that header
value, but **only for connections from trusted proxies**. Other clients can't forge it, and every
check here uses the result.

| `--realip` | Behaviour |
|---|---|
| `auto` (default) | If nginx already has a `real_ip_header` (for example HestiaCP's own `conf.d/cloudflare.inc`), it is kept and nothing is added. Otherwise the `managed` behaviour below applies |
| `managed` | Writes `set_real_ip_from` for every Cloudflare range (refreshed daily) and for your `--trusted-proxy` addresses, plus `real_ip_header` (default `CF-Connecting-IP`; with `X-Forwarded-For` it also turns on `real_ip_recursive`). Refuses to install if another file already sets `real_ip_header` |
| `off` | No realip configuration |

In `auto` mode, `status` and the daily update warn when the existing configuration is missing
current Cloudflare ranges. Without those ranges, visitors reaching you through the missing edges
would not be checked.

## GeoIP (optional)

GeoIP is **off by default**. Enable it at install time or later:

```bash
nginx-block-bad-ips geoip enable --countries BR,PT --mode allow --paths '^/wp-login\.php$'
nginx-block-bad-ips geoip enable --countries XX,YY --mode deny      # block these countries site-wide
nginx-block-bad-ips geoip show
nginx-block-bad-ips geoip disable
```

- **Modes:**
  - `allow`: only the listed countries pass.
  - `deny`: the listed countries are blocked.
- **`--paths`:** a case-insensitive regular expression on the URI. It limits GeoIP to sensitive
  paths such as the WordPress login. Without it, GeoIP applies to the whole site.
- **`--unknown`:** addresses that belong to no country are allowed by default. Use `block` to deny
  them.
- **Data:** free per-country data from ipdeny.com, based on the regional internet registries. No
  nginx module, account or licence key is needed.
  - IPv4 uses every country, merged into about 70,000 ranges in nginx's fast `ranges` mode.
  - IPv6 uses the selected countries; any other global IPv6 address counts as "another country".
- **Accuracy:** registry data places an IP where the network is registered, which is usually but
  not always where it is used (VPNs, multinational networks). The blocklists and the whitelist
  always apply as well.

## Updates, testing and rollback

Every change goes through the same transaction: install, the daily `update`, the hourly `sync`, a
whitelist edit and uninstall.

1. Take a lock, so two runs never overlap.
2. Run `nginx -t` on the **untouched** configuration. If it already fails, nothing is changed.
3. Render the new files in a staging directory next to their destination, so SELinux labels are
   correct. Compare them with the current files. If nothing changed, stop without reloading.
4. **Back up** every file that will change, including vhost files, under
   `/var/lib/nginx-block-bad-ips/backups/`.
5. Put the new files in place and run `nginx -t`:
   - **OK:** `systemctl reload nginx` (or `nginx -s reload`), then delete the backup.
   - **Failed:** restore every file from the backup. nginx keeps running the previous rules, the
     error is logged in `/var/log/nginx-block-bad-ips.log` and the backup is kept for inspection.

nginx is **never restarted** and **never started** by this tool. If nginx is not running, the files
are updated and a warning is logged.

## Command reference

```
nginx-block-bad-ips update                  download lists and apply (daily cron)
nginx-block-bad-ips apply                   rebuild from cache and configuration
nginx-block-bad-ips sync                    same as apply; protects new vhosts (hourly cron)
nginx-block-bad-ips status                  lists, counts, GeoIP, real IP mode, vhost coverage
nginx-block-bad-ips check <ip>              is this IP blocked? by which list or rule?
nginx-block-bad-ips whitelist list|add|remove ...
nginx-block-bad-ips lists [show|enable|disable|profile|add-custom|remove-custom] ...
nginx-block-bad-ips geoip show|enable|disable ...
nginx-block-bad-ips --help | <command> --help | version
```

Example:

```
$ nginx-block-bad-ips check 1.10.16.5
Checking 1.10.16.5
  listed:   spamhaus_drop (1.10.16.0/20)
  listed:   firehol_level1 (1.10.16.0/20)
Verdict: BLOCKED with HTTP 403 on every protected site
```

## Files

| Path | Purpose |
|---|---|
| `/etc/nginx-block-bad-ips/nginx-block-bad-ips.conf` | Settings (see `conf/nginx-block-bad-ips.conf.example`) |
| `/etc/nginx-block-bad-ips/whitelist.txt` | Your whitelist |
| `/etc/nginx-block-bad-ips/custom-lists.conf` | Your custom lists |
| `/etc/nginx/conf.d/nginx-block-bad-ips.conf` | Generated http-level config (realip, geo, map) |
| `/etc/nginx/nginx-block-bad-ips/` | Generated data and `enforce.conf` |
| `/usr/local/sbin/nginx-block-bad-ips`, `/usr/local/lib/nginx-block-bad-ips/` | CLI, libraries and a copy of `uninstall.sh` |
| `/var/lib/nginx-block-bad-ips/` | Download cache, state and transaction backups |
| `/etc/cron.d/nginx-block-bad-ips` | Daily update and hourly sync |
| `/var/log/nginx-block-bad-ips.log` | Log (rotated weekly) |

## Troubleshooting

- **A visitor says they are blocked.** Ask for their IP, run `nginx-block-bad-ips check <ip>`, and
  if needed `nginx-block-bad-ips whitelist add <ip>`.
- **What happened last night?** Run `nginx-block-bad-ips status` and read
  `/var/log/nginx-block-bad-ips.log`.
- **An update failed.** The log shows the `nginx -t` output. The previous rules stay active and the
  failed attempt's backup is under `/var/lib/nginx-block-bad-ips/backups/`.
- **Plain nginx does not block anything.** Add
  `include /etc/nginx/nginx-block-bad-ips/enforce.conf;` inside each `server {}`, or re-run
  `install.sh --auto-inject`. `status` shows how many server blocks carry the include.
- **Testing the rollback.** `NBBI_TEST_BREAK=1 nginx-block-bad-ips apply` deliberately renders an
  invalid file. You should see `nginx -t` fail and everything restored.

## Uninstall

```bash
sudo ./uninstall.sh            # from the git checkout, or:
sudo /usr/local/lib/nginx-block-bad-ips/uninstall.sh
```

The uninstaller runs in this order:

1. **Backs up** your whitelist, custom lists, settings and log to
   `/root/nginx-block-bad-ips-backup-<date>/`. You are warned where they are; they are not restored
   automatically on a reinstall.
2. Removes the include from every vhost. For Plesk this includes the `vhost_nginx.conf` files it
   created.
3. Removes the generated nginx files, then runs `nginx -t` and a reload. If the test fails,
   everything is restored and the uninstall stops.
4. Removes the cron job, the CLI, the libraries, the cache and the state.

Use `--yes` to skip the confirmation.

If the tool was managing the real client IP (`--realip managed`, or `auto` on a server without its
own configuration), that configuration is removed too, and the uninstaller warns you. Add your own
`set_real_ip_from` / `real_ip_header` configuration if your sites are behind a proxy.

## License

[MIT](LICENSE) © 2026 Francisco Panis Kaseker

## Legal notice

nginx is a trademark of F5, Inc. This project is independent and is not affiliated with, endorsed
by or sponsored by F5, Inc., NGINX, HestiaCP, Plesk (WebPros), Cloudflare, or any blocklist
provider. The software is provided "AS IS", without warranty of any kind, express or implied, as
stated in the MIT License. Blocklists are third-party data that can contain false positives and are
subject to their providers' terms. You are solely responsible for reviewing, testing and validating
this software and its configuration before using it on production servers, and for any
consequences of its use, including blocked legitimate traffic or service disruption.
