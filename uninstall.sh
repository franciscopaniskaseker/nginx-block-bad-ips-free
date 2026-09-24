#!/usr/bin/env bash
# uninstall.sh - removes nginx-block-bad-ips completely.
# https://github.com/franciscopaniskaseker/nginx-block-bad-ips-free  (MIT License)
set -uo pipefail
# shellcheck source-path=SCRIPTDIR

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "uninstall.sh needs bash 4 or newer" >&2
    exit 1
fi

# Works from the git checkout and from the installed copy.
BASE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
if [ ! -f "$BASE/lib/common.sh" ] && [ -f /usr/local/lib/nginx-block-bad-ips/lib/common.sh ]; then
    BASE=/usr/local/lib/nginx-block-bad-ips
fi
NBBI_LIB="$BASE/lib"
NBBI_SHARE="$BASE/share"
# shellcheck source=lib/common.sh
. "$NBBI_LIB/common.sh"
# shellcheck source=lib/lists.sh
. "$NBBI_LIB/lists.sh"
# shellcheck source=lib/render.sh
. "$NBBI_LIB/render.sh"
# shellcheck source=lib/panels.sh
. "$NBBI_LIB/panels.sh"

usage() {
    cat <<EOF
nginx-block-bad-ips $NBBI_VERSION uninstaller

Removes everything nginx-block-bad-ips installed:
  - the block include from every vhost (HestiaCP files, Plesk vhost_nginx.conf
    blocks, plain nginx server blocks)
  - $NBBI_NGINX_CONF_HINT and the generated files
  - the cron job, the CLI, the libraries, the cache and the state
Then it tests the configuration with "nginx -t" and reloads nginx (it never
restarts it). If the test fails, everything is restored and nothing is removed.

Before removing anything, your whitelist, custom lists, configuration and log
are copied to /root/nginx-block-bad-ips-backup-<date>/ - you will be reminded.

Usage: sudo ./uninstall.sh [options]
   or: sudo $NBBI_INSTALL_DIR/uninstall.sh [options]

Options:
  -y, --yes     Do not ask for confirmation
  -h, --help    Show this help and exit
EOF
}

YES=0
NBBI_NGINX_CONF_HINT="/etc/nginx/conf.d/nginx-block-bad-ips.conf"
while [ $# -gt 0 ]; do
    case $1 in
        -h|--help) usage; exit 0 ;;
        -y|--yes) YES=1 ;;
        *) die "unknown option '$1' (see --help)" ;;
    esac
    shift
done

require_root
cfg_load

if [ "$YES" != 1 ]; then
    if [ -t 0 ]; then
        printf 'Remove nginx-block-bad-ips from this server? Your whitelist will be backed up to /root/. [y/N] '
        read -r answer
        [[ $answer =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
    else
        die "not running interactively: re-run with --yes to confirm"
    fi
fi

nbbi_lock

# Real IP restoration written by this tool disappears with it.
REALIP_WARNING=""
if [ "$(cat "$NBBI_STATE/realip.effective" 2>/dev/null)" = managed ] && [ "${CFG[REALIP_MODE]}" != off ]; then
    REALIP_WARNING=1
fi

# 1. Back up what the user wrote, before touching anything.
BACKUP="/root/nginx-block-bad-ips-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP" || die "cannot create $BACKUP"
chmod 0700 "$BACKUP"
for f in "$NBBI_WHITELIST" "$NBBI_CUSTOM" "$NBBI_CONF"; do
    [ -f "$f" ] && cp -a -- "$f" "$BACKUP/"
done
[ -f "$NBBI_LOG" ] && cp -a -- "$NBBI_LOG" "$BACKUP/"
info "backup of your whitelist and settings: $BACKUP"

# 2. Remove the nginx side in one transaction (vhost references first, then
#    the definitions they use), test, reload or roll back.
mkdir -p "$NBBI_BACKUPS"
TXN_PREFLIGHT_STRICT=0
txn_begin
REMOVED_FILES=()
panel_remove_all
for f in "$NBBI_NGINX_CONF" "$NBBI_NGINX_DIR"/*; do
    [ -e "$f" ] || continue
    txn_track "$f"
    rm -rf -- "$f"
done
for f in "$NBBI_NGINX_DIR"/.stage.*; do
    [ -e "$f" ] && rm -rf -- "$f"
done

if [ "$TXN_COUNT" -gt 0 ]; then
    if ! txn_finish uninstall; then
        if [ "$TXN_PREFLIGHT" = ok ]; then
            die "uninstall aborted: nginx -t failed without the product, so everything was restored. Nothing else was removed. Backup: $BACKUP"
        fi
        warn "nginx -t was already failing before the uninstall; continuing the removal"
    fi
    info "removed the block from ${#REMOVED_FILES[@]} vhost file(s) and reloaded nginx"
else
    txn_discard
    info "no nginx files of nginx-block-bad-ips were found"
fi
rmdir -- "$NBBI_NGINX_DIR" 2>/dev/null || true

# 3. Everything else.
rm -f -- "$NBBI_CRON" "$NBBI_LOGROTATE" "$NBBI_BIN"
rm -rf -- "$NBBI_INSTALL_DIR" "$NBBI_VAR" "$NBBI_ETC"
rm -f -- "$NBBI_LOG" "$NBBI_LOG".[0-9]* "$NBBI_LOG".*.gz
rm -f -- "$NBBI_LOCK"

cat <<EOF

nginx-block-bad-ips was removed. Cron job, scripts, cache and nginx files are gone.

================================================================================
 WARNING: your whitelisted IPs were backed up before removal. They were NOT
 deleted and will NOT be restored automatically if you install again:

     $BACKUP/whitelist.txt

 The same folder holds custom-lists.conf, the configuration and the log.
 To reuse them after a reinstall:
     cp $BACKUP/whitelist.txt $NBBI_WHITELIST && nginx-block-bad-ips apply
================================================================================
EOF
if [ -n "$REALIP_WARNING" ]; then
    cat <<EOF

 WARNING: nginx-block-bad-ips was also restoring the real client IP behind
 Cloudflare/proxies (set_real_ip_from + real_ip_header). That configuration was
 removed too: nginx now sees the proxy address as the client, which affects
 access logs, rate limits and any IP-based rule. If your sites are behind a
 proxy, add your own real IP configuration and reload nginx.
EOF
fi
