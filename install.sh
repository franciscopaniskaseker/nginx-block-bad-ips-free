#!/usr/bin/env bash
# install.sh - installs or upgrades nginx-block-bad-ips.
# https://github.com/franciscopaniskaseker/nginx-block-bad-ips-free  (MIT License)
set -uo pipefail
# shellcheck source-path=SCRIPTDIR

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "install.sh needs bash 4 or newer" >&2
    exit 1
fi

REPO=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
NBBI_LIB="$REPO/lib"
NBBI_SHARE="$REPO/share"
# shellcheck source=lib/common.sh
. "$NBBI_LIB/common.sh"
# shellcheck source=lib/lists.sh
. "$NBBI_LIB/lists.sh"
# shellcheck source=lib/render.sh
. "$NBBI_LIB/render.sh"

usage() {
    cat <<EOF
nginx-block-bad-ips $NBBI_VERSION installer

Blocks known-bad IP addresses in nginx using free, public blocklists.
Works with HestiaCP, Plesk and plain nginx on Rocky Linux 8/9/10 and
Ubuntu 22.04/24.04/26.04. Re-running it upgrades the installation and keeps
your configuration and whitelist (flags you pass override stored settings).

Usage: sudo ./install.sh [options]

General:
  -h, --help                 Show this help and exit
  -y, --yes                  Non-interactive: install missing packages without asking
      --dry-run              Download, validate and render everything into a temporary
                             directory and show what would change. Touches nothing.
      --force                Install on an operating system that is not supported

Blocklists (see README "Lists used and why"):
      --profile safe|aggressive
                             safe (default): Spamhaus DROP v4/v6, FireHOL level 1,
                             Emerging Threats compromised. aggressive adds blocklist.de,
                             CINS Army, IPsum level 3 and GreenSnow.
      --lists a,b,c          Enable exactly these catalog lists (overrides --profile)
      --custom-list NAME=URL Add your own list (http(s):// or file://). Repeatable.

Whitelist (always allowed, wins over every list):
      --whitelist IP[,CIDR]  Add addresses to $NBBI_WHITELIST. Repeatable.
                             Cloudflare, private ranges and this server are always allowed.

Real client IP (sites behind Cloudflare or another proxy):
      --realip auto|managed|off
                             auto (default): keep an existing real_ip_header config if
                             nginx has one, otherwise manage it here.
      --real-ip-header NAME  Header with the client IP (default: CF-Connecting-IP;
                             use X-Forwarded-For for other proxies/load balancers)
      --trusted-proxy CIDR   Trust this proxy/load balancer to send the header. Repeatable.

GeoIP (optional, disabled by default):
      --enable-geoip         Enable country blocking (needs --geoip-countries)
      --disable-geoip        Disable country blocking
      --geoip-countries CC,CC  Two-letter country codes, e.g. BR,US,PT
      --geoip-mode allow|deny  allow = only these countries pass (default);
                               deny = these countries are blocked
      --geoip-paths REGEX    Apply GeoIP only to matching URIs, e.g. '^/wp-login\.php\$'
                             (default: the whole site)
      --geoip-unknown allow|block
                             Addresses that belong to no country (default: allow)

Enforcement:
      --block-status CODE    Response for blocked clients: 403 (default) or 444 (close
                             the connection without answering)
      --panel auto|hestia|plesk|none
                             Control panel integration (default: auto-detect)
      --auto-inject          Plain nginx only: add the block include to every server {}
                             in sites-enabled/ and conf.d/ automatically
      --no-auto-inject       Stop auto-injecting (existing includes stay until uninstall)

Examples:
  sudo ./install.sh
  sudo ./install.sh --profile aggressive --whitelist 203.0.113.10
  sudo ./install.sh --enable-geoip --geoip-countries BR,PT --geoip-paths '^/wp-login\.php\$'
  sudo ./install.sh --dry-run

After installing: nginx-block-bad-ips --help   |   Uninstall: sudo ./uninstall.sh

nginx is only ever reloaded, never restarted. Every change is tested with
"nginx -t" and rolled back automatically when the test fails.
This software is provided "AS IS", without warranty of any kind (MIT License).
You are responsible for testing it before using it on production servers.
EOF
}

# ------------------------------------------------------------------- args ---

YES=0; DRY=0; FORCE=0
declare -A SET
WL_ADD=(); CUSTOM_ADD=(); PROXY_ADD=()

need_arg() { [ $# -ge 2 ] && [ -n "$2" ] || die "option $1 needs a value (see --help)"; }

while [ $# -gt 0 ]; do
    case $1 in
        -h|--help) usage; exit 0 ;;
        -y|--yes) YES=1 ;;
        --dry-run) DRY=1 ;;
        --force) FORCE=1 ;;
        --profile) need_arg "$@"; SET[PROFILE]=$2; shift ;;
        --lists) need_arg "$@"; SET[LISTS]=$2; shift ;;
        --custom-list) need_arg "$@"; CUSTOM_ADD+=("$2"); shift ;;
        --whitelist) need_arg "$@"; WL_ADD+=("$2"); shift ;;
        --realip) need_arg "$@"; SET[REALIP_MODE]=$2; shift ;;
        --real-ip-header) need_arg "$@"; SET[REAL_IP_HEADER]=$2; shift ;;
        --trusted-proxy) need_arg "$@"; PROXY_ADD+=("$2"); shift ;;
        --enable-geoip) SET[GEOIP_ENABLED]=yes ;;
        --disable-geoip) SET[GEOIP_ENABLED]=no ;;
        --geoip-countries) need_arg "$@"; SET[GEOIP_COUNTRIES]=$(echo "$2" | tr '[:lower:]' '[:upper:]' | tr -d ' '); shift ;;
        --geoip-mode) need_arg "$@"; SET[GEOIP_MODE]=$2; shift ;;
        --geoip-paths) need_arg "$@"; SET[GEOIP_PATHS]=$2; shift ;;
        --geoip-unknown) need_arg "$@"; SET[GEOIP_UNKNOWN]=$2; shift ;;
        --block-status) need_arg "$@"; SET[BLOCK_STATUS]=$2; shift ;;
        --panel) need_arg "$@"; SET[PANEL]=$2; shift ;;
        --auto-inject) SET[AUTO_INJECT]=yes ;;
        --no-auto-inject) SET[AUTO_INJECT]=no ;;
        *) die "unknown option '$1' (see --help)" ;;
    esac
    shift
done

[ "$DRY" = 1 ] && NBBI_DRY_RUN=1

# ----------------------------------------------------------------- checks ---

require_root

if [ "$(os_supported)" != supported ]; then
    if [ "$FORCE" = 1 ]; then
        warn "operating system '$(os_id)' is not supported; continuing because of --force"
    else
        die "operating system '$(os_id)' is not supported (Rocky 8/9/10, Ubuntu 22.04/24.04/26.04). Use --force to try anyway."
    fi
fi

pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v yum >/dev/null 2>&1; then echo yum
    else echo none; fi
}

# Missing tools -> packages to install.
missing_packages() {
    local pm=$1 pkgs=()
    command -v curl >/dev/null 2>&1 || pkgs+=(curl)
    command -v flock >/dev/null 2>&1 || pkgs+=(util-linux)
    command -v tar >/dev/null 2>&1 || pkgs+=(tar)
    command -v gzip >/dev/null 2>&1 || pkgs+=(gzip)
    command -v cmp >/dev/null 2>&1 || pkgs+=(diffutils)
    command -v pgrep >/dev/null 2>&1 || { [ "$pm" = apt ] && pkgs+=(procps) || pkgs+=(procps-ng); }
    command -v ip >/dev/null 2>&1 || { [ "$pm" = apt ] && pkgs+=(iproute2) || pkgs+=(iproute); }
    command -v logrotate >/dev/null 2>&1 || pkgs+=(logrotate)
    if [ "$pm" = apt ]; then
        command -v cron >/dev/null 2>&1 || [ -x /usr/sbin/cron ] || pkgs+=(cron)
    else
        command -v awk >/dev/null 2>&1 || pkgs+=(gawk)
        command -v crond >/dev/null 2>&1 || [ -x /usr/sbin/crond ] || pkgs+=(cronie)
    fi
    printf '%s\n' "${pkgs[@]}"
}

install_dependencies() {
    local pm pkgs=() answer
    pm=$(pkg_manager)
    mapfile -t pkgs < <(missing_packages "$pm" | sed '/^$/d')
    [ "${#pkgs[@]}" -eq 0 ] && return 0
    if [ "$DRY" = 1 ]; then
        warn "[dry-run] missing packages that the real install would add: ${pkgs[*]}"
        return 0
    fi
    if [ "$YES" != 1 ]; then
        if [ -t 0 ]; then
            printf 'Missing packages: %s. Install them now? [y/N] ' "${pkgs[*]}"
            read -r answer
            [[ $answer =~ ^[Yy] ]] || die "cannot continue without: ${pkgs[*]}"
        else
            die "missing packages: ${pkgs[*]} (install them or re-run with --yes)"
        fi
    fi
    info "installing packages: ${pkgs[*]}"
    case $pm in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${pkgs[@]}" ;;
        dnf) dnf install -y -q "${pkgs[@]}" ;;
        yum) yum install -y -q "${pkgs[@]}" ;;
        *) die "no supported package manager found; install manually: ${pkgs[*]}" ;;
    esac || die "package installation failed"
}

ensure_cron_running() {
    local svc
    command -v systemctl >/dev/null 2>&1 || return 0
    for svc in cron crond; do
        if systemctl list-unit-files "$svc.service" >/dev/null 2>&1 && systemctl cat "$svc.service" >/dev/null 2>&1; then
            if ! systemctl is-active --quiet "$svc"; then
                info "enabling and starting the $svc service"
                systemctl enable --now "$svc" >/dev/null 2>&1 || warn "could not start $svc; the daily update will not run"
            fi
            return 0
        fi
    done
    warn "no cron service found; the daily update will not run automatically"
}

install_dependencies

NGINX=$(nginx_bin) || die "nginx is not installed (install nginx or your control panel first)"
CONF_PATH=$("$NGINX" -V 2>&1 | sed -n 's/.*--conf-path=\([^ ]*\).*/\1/p')
DETECTED_NGINX_DIR=$(dirname "${CONF_PATH:-/etc/nginx/nginx.conf}")
[ -d "$DETECTED_NGINX_DIR/conf.d" ] || die "$DETECTED_NGINX_DIR/conf.d does not exist; this nginx layout is not supported"

# ----------------------------------------------------------------- config ---

cfg_load   # existing configuration (or defaults)
FIRST_INSTALL=0
[ -f "$NBBI_CONF" ] || FIRST_INSTALL=1
CFG[NGINX_DIR]=$DETECTED_NGINX_DIR

if [ -n "${SET[PROFILE]:-}" ]; then
    CFG[LISTS]=$(profile_lists "${SET[PROFILE]}") || die "--profile must be safe or aggressive"
fi
for k in LISTS REALIP_MODE REAL_IP_HEADER GEOIP_ENABLED GEOIP_COUNTRIES GEOIP_MODE GEOIP_PATHS GEOIP_UNKNOWN BLOCK_STATUS PANEL AUTO_INJECT; do
    [ -n "${SET[$k]+x}" ] && CFG[$k]=${SET[$k]}
done
for p in "${PROXY_ADD[@]}"; do
    for e in $(split_list "$p"); do
        c=$(normalize_one "$e")
        [ -n "$c" ] || die "--trusted-proxy '$e' is not a valid IP/CIDR"
        [[ ",${CFG[TRUSTED_PROXIES]}," == *",$c,"* ]] || CFG[TRUSTED_PROXIES]="${CFG[TRUSTED_PROXIES]:+${CFG[TRUSTED_PROXIES]},}$c"
    done
done
[ -n "${CFG[CRON_MINUTE]}" ] || CFG[CRON_MINUTE]=$((RANDOM % 60))
[ -n "${CFG[CRON_HOUR]}" ] || CFG[CRON_HOUR]=$((2 + RANDOM % 4))
nbbi_set_paths

if ! msg=$(cfg_validate); then die "$msg"; fi
while IFS= read -r name; do
    catalog_get "$name" || die "unknown list '$name' (valid: $(catalog_lines | cut -d'|' -f1 | paste -sd' ' -))"
done < <(split_list "${CFG[LISTS]}")

WL_CANON=()
for w in "${WL_ADD[@]}"; do
    for e in $(split_list "$w"); do
        c=$(normalize_one "$e")
        [ -n "$c" ] || die "--whitelist '$e' is not a valid IP/CIDR"
        WL_CANON+=("$c")
    done
done
for c in "${CUSTOM_ADD[@]}"; do
    name=${c%%=*}; url=${c#*=}
    valid_list_name "$name" || die "--custom-list: invalid name '$name' (a-z 0-9 _ -)"
    valid_url "$url" || die "--custom-list $name: URL must start with http://, https:// or file://"
done

# Real IP checks.
if ! "$NGINX" -V 2>&1 | grep -q -- '--with-http_realip_module'; then
    case ${CFG[REALIP_MODE]} in
        managed) die "this nginx has no realip module; use --realip off" ;;
        auto) warn "this nginx has no realip module: real client IPs behind proxies cannot be restored"; CFG[REALIP_MODE]=off ;;
    esac
fi
if [ "${CFG[REALIP_MODE]}" = managed ]; then
    ext=$(external_realip_files)
    if [ -n "$ext" ]; then
        die "real_ip_header is already configured in: $(echo "$ext" | paste -sd' ' -). Remove it there to let this tool manage it, or use --realip auto."
    fi
fi

write_etc() {  # write_etc DIR  (config, whitelist and custom lists)
    local dir=$1 c name url
    mkdir -p "$dir"
    chmod 0755 "$dir"
    NBBI_CONF="$dir/nginx-block-bad-ips.conf"
    cfg_save "$NBBI_CONF"
    [ -f "$dir/whitelist.txt" ] || install -m 0644 "$REPO/conf/whitelist.txt.example" "$dir/whitelist.txt"
    [ -f "$dir/custom-lists.conf" ] || install -m 0644 "$REPO/conf/custom-lists.conf.example" "$dir/custom-lists.conf"
    for c in "${WL_CANON[@]}"; do
        normalize_stream plain 0 0 < "$dir/whitelist.txt" | grep -qxF -- "$c" || printf '%s\n' "$c" >> "$dir/whitelist.txt"
    done
    for c in "${CUSTOM_ADD[@]}"; do
        name=${c%%=*}; url=${c#*=}
        if awk -v n="$name" '!/^[[:space:]]*#/ && $1 == n { f = 1 } END { exit !f }' "$dir/custom-lists.conf"; then
            awk -v n="$name" -v u="$url" '!/^[[:space:]]*#/ && $1 == n { print n, u; next } { print }' "$dir/custom-lists.conf" > "$dir/.cl.tmp" \
                && mv -f "$dir/.cl.tmp" "$dir/custom-lists.conf"
        else
            printf '%s %s\n' "$name" "$url" >> "$dir/custom-lists.conf"
        fi
    done
}

# ---------------------------------------------------------------- dry-run ---

if [ "$DRY" = 1 ]; then
    DRYDIR=$(mktemp -d /tmp/nginx-block-bad-ips-dry-run.XXXXXX)
    mkdir -p "$DRYDIR/etc"
    for f in "$NBBI_WHITELIST" "$NBBI_CUSTOM"; do
        [ -f "$f" ] && cp -a "$f" "$DRYDIR/etc/"
    done
    write_etc "$DRYDIR/etc"
    info "[dry-run] panel: $(effective_panel), nginx: $NGINX ($DETECTED_NGINX_DIR), OS: $(os_id)"
    info "[dry-run] lists: ${CFG[LISTS]}"
    mkdir -p "$DRYDIR/nginx/conf.d"
    NBBI_ETC="$DRYDIR/etc" NBBI_VAR="$DRYDIR/var" NBBI_DRY_RUN=1 \
        NBBI_NGINX_DIR_OVERRIDE="$DRYDIR/nginx/nginx-block-bad-ips" \
        NBBI_NGINX_CONF_OVERRIDE="$DRYDIR/nginx/conf.d/nginx-block-bad-ips.conf" \
        "$REPO/bin/nginx-block-bad-ips" update --dry-run
    rc=$?
    info "[dry-run] configuration preview: $DRYDIR/etc/nginx-block-bad-ips.conf"
    info "[dry-run] generated nginx files: $DRYDIR/nginx/ (delete $DRYDIR when done)"
    exit "$rc"
fi

# ---------------------------------------------------------------- install ---

nginx_test || { printf '%s\n' "$NGINX_TEST_OUTPUT" >&2; die "nginx -t fails before installing; fix nginx first (nothing was changed)"; }

info "installing nginx-block-bad-ips $NBBI_VERSION ($([ "$FIRST_INSTALL" = 1 ] && echo "new install" || echo "upgrade"))"
tmpd=$(mktemp -d "$(dirname "$NBBI_INSTALL_DIR")/.nbbi-install.XXXXXX") || die "cannot write to $(dirname "$NBBI_INSTALL_DIR")"
mkdir -p "$tmpd/bin" "$tmpd/lib" "$tmpd/share"
install -m 0755 "$REPO/bin/nginx-block-bad-ips" "$tmpd/bin/"
install -m 0644 "$REPO"/lib/*.sh "$REPO"/lib/*.awk "$tmpd/lib/"
install -m 0644 "$REPO"/share/* "$tmpd/share/"
install -m 0755 "$REPO/uninstall.sh" "$tmpd/uninstall.sh"
install -m 0644 "$REPO/README.md" "$REPO/LICENSE" "$tmpd/" 2>/dev/null || true
rm -rf -- "$NBBI_INSTALL_DIR.old"
[ -d "$NBBI_INSTALL_DIR" ] && mv -- "$NBBI_INSTALL_DIR" "$NBBI_INSTALL_DIR.old"
mv -- "$tmpd" "$NBBI_INSTALL_DIR"
chmod 0755 "$NBBI_INSTALL_DIR"
rm -rf -- "$NBBI_INSTALL_DIR.old"
ln -sfn "$NBBI_INSTALL_DIR/bin/nginx-block-bad-ips" "$NBBI_BIN"

write_etc "$NBBI_ETC"
chmod 0600 "$NBBI_CONF"
mkdir -p "$NBBI_VAR"; chmod 0700 "$NBBI_VAR"
touch "$NBBI_LOG"; chmod 0640 "$NBBI_LOG"

info "downloading the lists and applying them (this can take a minute)"
if ! "$NBBI_BIN" update; then
    err "the first update failed; nginx keeps its previous configuration."
    err "Check $NBBI_LOG, fix the problem and run install.sh again, or remove everything with uninstall.sh."
    exit 1
fi

# grep -c reads everything: an early exit would SIGPIPE nginx -T under pipefail.
if ! "$NGINX" -T 2>/dev/null | grep -cF "# configuration file $NBBI_NGINX_CONF:" >/dev/null; then
    warn "nginx does not load $NBBI_NGINX_CONF: add 'include $NGINX_DIR/conf.d/*.conf;' inside http {} in $CONF_PATH"
fi

# Cron: daily update at a random time, hourly sync for new vhosts.
minute=${CFG[CRON_MINUTE]}
sync_minute=$(( (minute + 30) % 60 ))
cat > "$NBBI_CRON.tmp" <<EOF
# nginx-block-bad-ips: installed by install.sh, removed by uninstall.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${CFG[CRON_MINUTE]} ${CFG[CRON_HOUR]} * * * root $NBBI_BIN update --quiet
$sync_minute * * * * root $NBBI_BIN sync --quiet
EOF
chmod 0644 "$NBBI_CRON.tmp"
mv -f "$NBBI_CRON.tmp" "$NBBI_CRON"
fix_selinux "$NBBI_CRON"
ensure_cron_running

cat > "$NBBI_LOGROTATE" <<EOF
$NBBI_LOG {
    su root root
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
chmod 0644 "$NBBI_LOGROTATE"

echo
"$NBBI_BIN" status
echo
if [ "$(effective_panel)" = none ] && [ "${CFG[AUTO_INJECT]}" != yes ]; then
    cat <<EOF
IMPORTANT (plain nginx): the blocking rule is not active until you add this line
inside every server { } block you want to protect, then run: nginx -t && systemctl reload nginx

    include $NBBI_ENFORCE;

Or re-run the installer with --auto-inject to do it automatically.
EOF
    echo
fi
info "done. Whitelist: $NBBI_WHITELIST   Help: nginx-block-bad-ips --help   Log: $NBBI_LOG"
