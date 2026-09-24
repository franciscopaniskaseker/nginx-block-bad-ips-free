# Changelog

## 1.0.0 - 2026-09-24

First public release.

- `install.sh` / `uninstall.sh` with `--help`, `--dry-run` (install) and `--yes`.
- Free blocklist catalog with a `safe` default profile (Spamhaus DROP v4/v6, FireHOL level 1,
  Emerging Threats compromised) and an `aggressive` profile (adds blocklist.de, CINS Army,
  IPsum level 3, GreenSnow); custom lists over http(s) or file://.
- Whitelist that always wins; Cloudflare, private/reserved ranges and the server's own addresses
  are always allowed.
- Real client IP behind Cloudflare and other proxies (`auto`, `managed`, `off`), with a warning
  when an existing configuration misses Cloudflare ranges.
- Optional module-free GeoIP (ipdeny.com data) in allow or deny mode, site-wide or on URI paths.
- HestiaCP, Plesk and plain nginx integration, with an hourly sync for new vhosts.
- Every change is tested with `nginx -t` and rolled back on failure; nginx is only reloaded.
- `nginx-block-bad-ips` CLI: update, apply, sync, status, check, whitelist, lists, geoip.
