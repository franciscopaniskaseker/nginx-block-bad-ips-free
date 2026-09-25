# shellcheck shell=bash disable=SC2034,SC2153  # globals are used by the scripts that source this file
# common.sh - paths, logging, configuration, locking, nginx test/reload and
# the backup/rollback transaction used by every change nginx-block-bad-ips makes.

NBBI_NAME="nginx-block-bad-ips"
NBBI_VERSION="1.0.0"
NBBI_URL="https://github.com/franciscopaniskaseker/nginx-block-bad-ips-free"

# Every path can be overridden from the environment (used by --dry-run and tests).
NBBI_ETC="${NBBI_ETC:-/etc/nginx-block-bad-ips}"
NBBI_CONF="${NBBI_CONF:-$NBBI_ETC/nginx-block-bad-ips.conf}"
NBBI_WHITELIST="${NBBI_WHITELIST:-$NBBI_ETC/whitelist.txt}"
NBBI_CUSTOM="${NBBI_CUSTOM:-$NBBI_ETC/custom-lists.conf}"
NBBI_VAR="${NBBI_VAR:-/var/lib/nginx-block-bad-ips}"
NBBI_CACHE="$NBBI_VAR/cache"
NBBI_BACKUPS="$NBBI_VAR/backups"
NBBI_STATE="$NBBI_VAR/state"
NBBI_LOG="${NBBI_LOG:-/var/log/nginx-block-bad-ips.log}"
NBBI_LOCK="${NBBI_LOCK:-/run/nginx-block-bad-ips.lock}"
NBBI_CRON="${NBBI_CRON:-/etc/cron.d/nginx-block-bad-ips}"
NBBI_LOGROTATE="${NBBI_LOGROTATE:-/etc/logrotate.d/nginx-block-bad-ips}"
NBBI_BIN="${NBBI_BIN:-/usr/local/sbin/nginx-block-bad-ips}"
NBBI_INSTALL_DIR="${NBBI_INSTALL_DIR:-/usr/local/lib/nginx-block-bad-ips}"
NBBI_UA="$NBBI_NAME/$NBBI_VERSION (+$NBBI_URL)"

export LC_ALL=C
NBBI_QUIET="${NBBI_QUIET:-0}"
NBBI_DRY_RUN="${NBBI_DRY_RUN:-0}"

# ---------------------------------------------------------------- logging ---

_nbbi_log() {
    local level=$1; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    if [ "$NBBI_DRY_RUN" != 1 ] && { [ -w "$NBBI_LOG" ] || [ -w "$(dirname "$NBBI_LOG")" ]; }; then
        printf '%s\n' "$line" >> "$NBBI_LOG" 2>/dev/null || true
    fi
    if [ "$NBBI_QUIET" != 1 ] || [ "$level" = ERROR ]; then
        case $level in
            INFO) printf '%s\n' "$*" >&2 ;;
            *)    printf '%s: %s\n' "$level" "$*" >&2 ;;
        esac
    fi
}
info() { _nbbi_log INFO "$@"; }
warn() { _nbbi_log WARNING "$@"; }
err()  { _nbbi_log ERROR "$@"; }
die()  { err "$@"; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "this command must be run as root"
}

# ----------------------------------------------------------------- config ---

NBBI_CFG_KEYS="LISTS BLOCK_STATUS REALIP_MODE REAL_IP_HEADER TRUSTED_PROXIES GEOIP_ENABLED GEOIP_MODE GEOIP_COUNTRIES GEOIP_PATHS GEOIP_UNKNOWN PANEL AUTO_INJECT NGINX_DIR CRON_MINUTE CRON_HOUR"
declare -A CFG

cfg_defaults() {
    CFG[LISTS]="spamhaus_drop,spamhaus_drop_v6,firehol_level1,et_compromised"
    CFG[BLOCK_STATUS]="403"
    CFG[REALIP_MODE]="auto"
    CFG[REAL_IP_HEADER]="CF-Connecting-IP"
    CFG[TRUSTED_PROXIES]=""
    CFG[GEOIP_ENABLED]="no"
    CFG[GEOIP_MODE]="allow"
    CFG[GEOIP_COUNTRIES]=""
    CFG[GEOIP_PATHS]=""
    CFG[GEOIP_UNKNOWN]="allow"
    CFG[PANEL]="auto"
    CFG[AUTO_INJECT]="no"
    CFG[NGINX_DIR]="/etc/nginx"
    CFG[CRON_MINUTE]=""
    CFG[CRON_HOUR]=""
}

# The file is parsed, never sourced: only known KEY="value" lines are read.
cfg_load() {
    local file=${1:-$NBBI_CONF} line key val
    cfg_defaults
    [ -r "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        [[ $line =~ ^[[:space:]]*([A-Z_]+)=(.*)$ ]] || continue
        key=${BASH_REMATCH[1]}
        val=${BASH_REMATCH[2]}
        val=${val%"${val##*[![:space:]]}"}
        if [[ $val =~ ^\"(.*)\"$ ]] || [[ $val =~ ^\'(.*)\'$ ]]; then
            val=${BASH_REMATCH[1]}
        fi
        case " $NBBI_CFG_KEYS " in
            *" $key "*) CFG[$key]=$val ;;
        esac
    done < "$file"
    nbbi_set_paths
}

cfg_save() {
    local file=${1:-$NBBI_CONF} tmp
    tmp=$(mktemp "$(dirname "$file")/.conf.XXXXXX")
    cat > "$tmp" <<EOF
# nginx-block-bad-ips configuration. Edit with care, or use the CLI:
#   nginx-block-bad-ips --help
# After editing by hand run: nginx-block-bad-ips update

# Blocklists to use, comma separated (see: nginx-block-bad-ips lists).
# Custom lists live in custom-lists.conf and are always active.
LISTS="${CFG[LISTS]}"

# Response for blocked clients: 403 (Forbidden) or 444 (close the connection).
BLOCK_STATUS="${CFG[BLOCK_STATUS]}"

# Real client IP behind proxies/CDNs: auto | managed | off
#   auto    = keep an existing real_ip_header config if nginx already has one,
#             otherwise behave as managed
#   managed = this product writes set_real_ip_from + real_ip_header
REALIP_MODE="${CFG[REALIP_MODE]}"
REAL_IP_HEADER="${CFG[REAL_IP_HEADER]}"
# Extra trusted proxies (comma separated CIDRs). Cloudflare is always trusted.
TRUSTED_PROXIES="${CFG[TRUSTED_PROXIES]}"

# Optional GeoIP (country) blocking. GEOIP_MODE: allow = only the listed
# countries pass, deny = the listed countries are blocked. GEOIP_PATHS is an
# optional case-insensitive regex on the URI (empty = the whole site).
# GEOIP_UNKNOWN: what to do with addresses that belong to no country.
GEOIP_ENABLED="${CFG[GEOIP_ENABLED]}"
GEOIP_MODE="${CFG[GEOIP_MODE]}"
GEOIP_COUNTRIES="${CFG[GEOIP_COUNTRIES]}"
GEOIP_PATHS="${CFG[GEOIP_PATHS]}"
GEOIP_UNKNOWN="${CFG[GEOIP_UNKNOWN]}"

# Panel integration: auto | hestia | plesk | none
PANEL="${CFG[PANEL]}"
# Plain nginx only: add the enforcement include to server blocks automatically.
AUTO_INJECT="${CFG[AUTO_INJECT]}"

# nginx configuration directory.
NGINX_DIR="${CFG[NGINX_DIR]}"

# Daily update time (chosen at random during install to spread load).
CRON_MINUTE="${CFG[CRON_MINUTE]}"
CRON_HOUR="${CFG[CRON_HOUR]}"
EOF
    chmod 0600 "$tmp"
    mv -f "$tmp" "$file"
}

# Validates CFG; prints the first problem and returns 1.
cfg_validate() {
    local v
    # 404/410 are cached by CDNs such as Cloudflare: a blocked client could make
    # the edge serve the error to everybody, so only 403 and 444 are allowed.
    case ${CFG[BLOCK_STATUS]} in 403|444) ;; *) echo "BLOCK_STATUS must be 403 or 444"; return 1 ;; esac
    case ${CFG[REALIP_MODE]} in auto|managed|off) ;; *) echo "REALIP_MODE must be auto, managed or off"; return 1 ;; esac
    [[ ${CFG[REAL_IP_HEADER]} =~ ^[A-Za-z0-9_-]+$ ]] || { echo "REAL_IP_HEADER must be a plain header name"; return 1; }
    case ${CFG[GEOIP_ENABLED]} in yes|no) ;; *) echo "GEOIP_ENABLED must be yes or no"; return 1 ;; esac
    case ${CFG[GEOIP_MODE]} in allow|deny) ;; *) echo "GEOIP_MODE must be allow or deny"; return 1 ;; esac
    case ${CFG[GEOIP_UNKNOWN]} in allow|block) ;; *) echo "GEOIP_UNKNOWN must be allow or block"; return 1 ;; esac
    case ${CFG[PANEL]} in auto|hestia|plesk|none) ;; *) echo "PANEL must be auto, hestia, plesk or none"; return 1 ;; esac
    case ${CFG[AUTO_INJECT]} in yes|no) ;; *) echo "AUTO_INJECT must be yes or no"; return 1 ;; esac
    if [ -n "${CFG[GEOIP_COUNTRIES]}" ]; then
        [[ ${CFG[GEOIP_COUNTRIES]} =~ ^[A-Za-z]{2}(,[A-Za-z]{2})*$ ]] || { echo "GEOIP_COUNTRIES must be two-letter codes separated by commas (e.g. BR,US)"; return 1; }
    fi
    if [ "${CFG[GEOIP_ENABLED]}" = yes ] && [ -z "${CFG[GEOIP_COUNTRIES]}" ]; then
        echo "GeoIP is enabled but GEOIP_COUNTRIES is empty"; return 1
    fi
    v=${CFG[GEOIP_PATHS]}
    if [[ $v == *'"'* || $v == *"'"* || $v =~ [[:cntrl:]] ]]; then
        echo "GEOIP_PATHS must not contain quotes or control characters"; return 1
    fi
    [[ ${CFG[LISTS]} =~ ^[a-z0-9_,-]*$ ]] || { echo "LISTS contains invalid characters"; return 1; }
    [[ ${CFG[TRUSTED_PROXIES]} =~ ^[0-9A-Fa-f.:/,]*$ ]] || { echo "TRUSTED_PROXIES must be CIDRs separated by commas"; return 1; }
    [[ ${CFG[NGINX_DIR]} =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "NGINX_DIR must be an absolute path"; return 1; }
    [[ ${CFG[CRON_MINUTE]} =~ ^([0-9]|[1-5][0-9])?$ ]] || { echo "CRON_MINUTE must be 0-59"; return 1; }
    [[ ${CFG[CRON_HOUR]} =~ ^([0-9]|1[0-9]|2[0-3])?$ ]] || { echo "CRON_HOUR must be 0-23"; return 1; }
    return 0
}

# Paths that depend on the nginx directory.
nbbi_set_paths() {
    NGINX_DIR=${CFG[NGINX_DIR]:-/etc/nginx}
    NBBI_NGINX_DIR="${NBBI_NGINX_DIR_OVERRIDE:-$NGINX_DIR/nginx-block-bad-ips}"
    NBBI_NGINX_CONF="${NBBI_NGINX_CONF_OVERRIDE:-$NGINX_DIR/conf.d/nginx-block-bad-ips.conf}"
    NBBI_ENFORCE="$NGINX_DIR/nginx-block-bad-ips/enforce.conf"
}

# Splits a comma/space separated string into lines.
split_list() { printf '%s\n' "$1" | tr ',' '\n' | tr -d ' \t' | sed '/^$/d'; }

# ---------------------------------------------------------------- helpers ---

# Remembers the outcome of the last run for `status`: record_last_run OK|FAILED message
record_last_run() {
    [ "$NBBI_DRY_RUN" = 1 ] && return 0
    mkdir -p "$NBBI_STATE" 2>/dev/null || return 0
    printf '%s|%s|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" > "$NBBI_STATE/last-run"
}

# awk with ipaddr.awk loaded: nbbi_awk [-v VAR=value]... [file]...
nbbi_awk() {
    local opts=()
    while [ "${1:-}" = -v ]; do opts+=("-v" "$2"); shift 2; done
    awk "${opts[@]}" -f "$NBBI_LIB/ipaddr.awk" "$@"
}

# Reads blocklist text on stdin, prints canonical CIDRs (unsorted).
normalize_stream() {
    local format=${1:-plain} min4=${2:-0} min6=${3:-0}
    nbbi_awk -v MODE=normalize -v FORMAT="$format" -v MIN4="$min4" -v MIN6="$min6"
}

# Prints the canonical form of one address/CIDR or nothing if invalid.
normalize_one() { printf '%s\n' "$1" | normalize_stream plain 0 0; }

count_lines() { if [ -s "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

has_selinux() { command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; }

fix_selinux() {
    has_selinux || return 0
    command -v restorecon >/dev/null 2>&1 || return 0
    restorecon -R "$@" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ nginx ---

nginx_bin() {
    command -v nginx 2>/dev/null || { [ -x /usr/sbin/nginx ] && echo /usr/sbin/nginx; } || return 1
}

NGINX_TEST_OUTPUT=""
nginx_test() {
    local bin
    bin=$(nginx_bin) || { NGINX_TEST_OUTPUT="nginx binary not found"; return 1; }
    NGINX_TEST_OUTPUT=$("$bin" -t 2>&1)
}

nginx_running() {
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
        return 0
    fi
    pgrep -x nginx >/dev/null 2>&1
}

# Reloads nginx. It never starts or restarts it.
nginx_reload() {
    local bin
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl reload nginx || return 1
    elif pgrep -x nginx >/dev/null 2>&1; then
        bin=$(nginx_bin) || return 1
        "$bin" -s reload || return 1
    else
        warn "nginx is not running: the new configuration is in place but was not loaded (nginx is never started by this tool)"
        return 0
    fi
    return 0
}

nginx_master_pid() {
    pgrep -o -x nginx 2>/dev/null || true
}

# --------------------------------------------------------------- locking ---

nbbi_lock() {
    [ "$NBBI_DRY_RUN" = 1 ] && return 0
    exec 9>"$NBBI_LOCK" || die "cannot open lock file $NBBI_LOCK"
    flock -w 900 9 || die "another nginx-block-bad-ips run is still active (lock $NBBI_LOCK)"
}

# ------------------------------------------------------------ transaction ---
#
# txn_begin; txn_track FILE...; <modify files>; then txn_finish:
#   nginx -t passes -> reload, delete the snapshot
#   nginx -t fails  -> restore every tracked file, keep the snapshot, return 1

TXN_DIR=""
TXN_COUNT=0
TXN_PREFLIGHT=""        # "", ok or failed
TXN_PREFLIGHT_STRICT=1  # 1 = refuse to change anything when nginx -t already fails
declare -A TXN_SEEN

txn_begin() {
    TXN_DIR="$NBBI_BACKUPS/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$TXN_DIR/files" || die "cannot create backup directory $TXN_DIR"
    chmod 0700 "$NBBI_BACKUPS" "$TXN_DIR"
    : > "$TXN_DIR/manifest"
    TXN_COUNT=0
    TXN_PREFLIGHT=""
    TXN_SEEN=()
}

# nginx -t on the untouched configuration, run right before the first change.
txn_preflight() {
    [ -n "$TXN_PREFLIGHT" ] && return 0
    if nginx_test; then
        TXN_PREFLIGHT=ok
        return 0
    fi
    TXN_PREFLIGHT=failed
    if [ "$TXN_PREFLIGHT_STRICT" = 1 ]; then
        record_last_run FAILED "nginx -t already failing before any change; nothing modified"
        err "nginx -t already fails BEFORE any change; nothing was modified. nginx said:"
        printf '%s\n' "$NGINX_TEST_OUTPUT" | sed 's/^/    /' >&2
        txn_discard
        exit 1
    fi
    warn "nginx -t already fails before any change; continuing because this is a removal"
}

# Snapshots a file before it is modified, created or removed.
# Mode "keep-empty": on rollback a newly created file is emptied instead of
# deleted (Plesk: its generated vhost config may already include it).
txn_track() {
    local f=$1 mode=${2:-normal}
    [ -n "$TXN_DIR" ] || die "internal error: txn_track outside a transaction"
    [ -n "${TXN_SEEN[$f]:-}" ] && return 0
    txn_preflight
    TXN_SEEN[$f]=1
    TXN_COUNT=$((TXN_COUNT + 1))
    if [ -e "$f" ] || [ -L "$f" ]; then
        cp -a -- "$f" "$TXN_DIR/files/$TXN_COUNT"
        printf '%s|existing|%s|%s\n' "$TXN_COUNT" "$mode" "$f" >> "$TXN_DIR/manifest"
    else
        printf '%s|new|%s|%s\n' "$TXN_COUNT" "$mode" "$f" >> "$TXN_DIR/manifest"
    fi
}

txn_rollback() {
    local id kind mode f
    [ -n "$TXN_DIR" ] && [ -f "$TXN_DIR/manifest" ] || return 0
    while IFS='|' read -r id kind mode f; do
        [ -n "$f" ] || continue
        if [ "$kind" = existing ]; then
            rm -rf -- "$f"
            cp -a -- "$TXN_DIR/files/$id" "$f"
        elif [ "$mode" = keep-empty ] && [ -e "$f" ]; then
            : > "$f"
        else
            rm -f -- "$f"
        fi
    done < "$TXN_DIR/manifest"
}

txn_discard() {
    [ -n "$TXN_DIR" ] && rm -rf -- "$TXN_DIR"
    TXN_DIR=""
}

# Keeps only the newest failed snapshots.
txn_prune() {
    local keep=5 old
    [ -d "$NBBI_BACKUPS" ] || return 0
    # shellcheck disable=SC2012
    ls -1dt "$NBBI_BACKUPS"/*/ 2>/dev/null | tail -n +$((keep + 1)) | while IFS= read -r old; do
        rm -rf -- "$old"
    done
}

# Tests the new configuration, reloads it or rolls everything back.
txn_finish() {
    local what=${1:-update}
    fix_selinux "$NBBI_NGINX_DIR" "$NBBI_NGINX_CONF"
    if nginx_test; then
        if ! nginx_reload; then
            err "nginx -t passed but the reload failed; restoring the previous configuration"
            txn_rollback
            nginx_test || true
            txn_prune
            return 1
        fi
        txn_discard
        return 0
    fi
    if [ "$TXN_PREFLIGHT" = failed ]; then
        err "nginx -t still fails after $what, but it was already failing before; changes kept (snapshot in $TXN_DIR). nginx said:"
        printf '%s\n' "$NGINX_TEST_OUTPUT" | sed 's/^/    /' | while IFS= read -r l; do err "$l"; done
        TXN_DIR=""
        return 1
    fi
    err "nginx -t failed after $what; restoring the previous configuration. nginx said:"
    printf '%s\n' "$NGINX_TEST_OUTPUT" | sed 's/^/    /' | while IFS= read -r l; do err "$l"; done
    txn_rollback
    if nginx_test; then
        err "previous configuration restored; nginx keeps running the old rules (snapshot kept in $TXN_DIR)"
    else
        err "nginx -t still fails after the restore; check the configuration manually (snapshot in $TXN_DIR)"
    fi
    TXN_DIR=""
    txn_prune
    return 1
}

# Replaces $2 with $1 when their contents differ. Tracks the target first.
# Returns 0 when the target changed.
install_if_changed() {
    local src=$1 dst=$2 mode=${3:-0644}
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        rm -f -- "$src"
        return 1
    fi
    txn_track "$dst"
    chmod "$mode" "$src"
    mv -f -- "$src" "$dst"
    return 0
}

# -------------------------------------------------------------- detection ---

os_id() {
    local id="" ver=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        id=$(. /etc/os-release && echo "${ID:-}")
        # shellcheck disable=SC1091
        ver=$(. /etc/os-release && echo "${VERSION_ID:-}")
    fi
    printf '%s %s\n' "$id" "$ver"
}

# Prints "supported" or "unsupported".
os_supported() {
    local id ver major
    read -r id ver < <(os_id)
    major=${ver%%.*}
    case "$id:$major" in
        rocky:8|rocky:9|rocky:10) echo supported ;;
        almalinux:8|almalinux:9|almalinux:10) echo supported ;;
        ubuntu:22|ubuntu:24|ubuntu:26) echo supported ;;
        *) echo unsupported ;;
    esac
}

detect_panel() {
    if [ -f /usr/local/hestia/conf/hestia.conf ] || [ -x /usr/local/hestia/bin/v-list-sys-info ]; then
        echo hestia
    elif [ -f /usr/local/psa/version ]; then
        echo plesk
    else
        echo none
    fi
}

effective_panel() {
    if [ "${CFG[PANEL]}" = auto ]; then detect_panel; else echo "${CFG[PANEL]}"; fi
}
