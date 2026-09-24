# shellcheck shell=bash disable=SC2034  # globals are used by the scripts that source this file
# lists.sh - list catalog, downloads with a per-source last-good cache,
# Cloudflare ranges and GeoIP country data.

NBBI_MIN_RATIO=25          # a fresh download smaller than 25% of the cached copy is rejected
NBBI_BLOCK_MIN4=8          # blocklist entries broader than /8 (IPv4) are ignored
NBBI_BLOCK_MIN6=16         # ... or broader than /16 (IPv6)
NBBI_IPDENY_V4_ALL="https://www.ipdeny.com/ipblocks/data/countries/all-zones.tar.gz"
NBBI_IPDENY_V6_FMT="https://www.ipdeny.com/ipv6/ipaddresses/aggregated/%s-aggregated.zone"
NBBI_CF_V4="https://www.cloudflare.com/ips-v4"
NBBI_CF_V6="https://www.cloudflare.com/ips-v6"

# ---------------------------------------------------------------- catalog ---

catalog_file() { echo "$NBBI_SHARE/lists.catalog"; }

# Prints "name|profile|format|url|description" lines.
catalog_lines() { grep -v -e '^#' -e '^[[:space:]]*$' "$(catalog_file)"; }

# Sets C_NAME C_PROFILE C_FORMAT C_URL C_DESC for a catalog entry.
catalog_get() {
    local line
    line=$(catalog_lines | awk -F'|' -v n="$1" '$1 == n { print; exit }')
    [ -n "$line" ] || return 1
    IFS='|' read -r C_NAME C_PROFILE C_FORMAT C_URL C_DESC <<< "$line"
}

# Comma separated list names for a profile (aggressive includes safe).
profile_lists() {
    case $1 in
        safe)       catalog_lines | awk -F'|' '$2 == "safe" { print $1 }' | paste -sd, - ;;
        aggressive) catalog_lines | awk -F'|' '$2 == "safe" || $2 == "aggressive" { print $1 }' | paste -sd, - ;;
        *) return 1 ;;
    esac
}

# Prints "name url" for every custom list.
custom_lists() {
    [ -r "$NBBI_CUSTOM" ] || return 0
    awk '!/^[[:space:]]*(#|$)/ && NF >= 2 { print $1, $2 }' "$NBBI_CUSTOM"
}

valid_list_name() { [[ $1 =~ ^[a-z0-9][a-z0-9_-]{0,39}$ ]]; }

valid_url() { [[ $1 =~ ^(https?|file)://[^[:space:]\"\'\;]+$ ]]; }

# Cache file for a list: catalog lists and custom lists live side by side.
list_cache() { echo "$NBBI_CACHE/lists/$1.txt"; }
custom_cache() { echo "$NBBI_CACHE/lists/custom-$1.txt"; }

# -------------------------------------------------------------- downloads ---

# Downloads $url (http(s) or file://) into $out. Returns curl's status.
fetch_raw() {
    local url=$1 out=$2
    case $url in
        file://*) cp -- "${url#file://}" "$out" 2>/dev/null ;;
        *) curl -fsSL --connect-timeout 15 --max-time 180 --retry 2 --retry-delay 5 \
                -A "$NBBI_UA" -o "$out" "$url" 2>/dev/null ;;
    esac
}

SOURCES_STATUS_TMP=""

# Records "name|count|fresh|cache|none|epoch" for `status`.
record_source() {
    [ -n "$SOURCES_STATUS_TMP" ] || return 0
    printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$(date +%s)" >> "$SOURCES_STATUS_TMP"
}

# fetch_source NAME URL FORMAT DEST MIN4 MIN6
# Keeps DEST (the last good copy) when the download fails, yields nothing,
# or shrinks below NBBI_MIN_RATIO percent of the cached copy.
fetch_source() {
    local name=$1 url=$2 format=$3 dest=$4 min4=${5:-0} min6=${6:-0}
    local raw norm new old
    mkdir -p "$(dirname "$dest")"
    raw=$(mktemp "$NBBI_CACHE/.raw.XXXXXX")
    norm=$(mktemp "$NBBI_CACHE/.norm.XXXXXX")
    old=$(count_lines "$dest")
    if ! fetch_raw "$url" "$raw"; then
        rm -f -- "$raw" "$norm"
        if [ "$old" -gt 0 ]; then
            warn "$name: download failed, keeping the cached copy ($old entries)"
            record_source "$name" "$old" cache
            return 1
        fi
        warn "$name: download failed and there is no cached copy"
        record_source "$name" 0 none
        return 2
    fi
    normalize_stream "$format" "$min4" "$min6" < "$raw" | sort -u > "$norm"
    rm -f -- "$raw"
    new=$(count_lines "$norm")
    if [ "$new" -eq 0 ] || { [ "$old" -gt 0 ] && [ $((new * 100)) -lt $((old * NBBI_MIN_RATIO)) ]; }; then
        rm -f -- "$norm"
        if [ "$old" -gt 0 ]; then
            warn "$name: new copy has $new valid entries (cached: $old), keeping the cached copy"
            record_source "$name" "$old" cache
            return 1
        fi
        warn "$name: no valid entries downloaded"
        record_source "$name" 0 none
        return 2
    fi
    chmod 0644 "$norm"
    mv -f -- "$norm" "$dest"
    record_source "$name" "$new" fresh
    return 0
}

download_blocklists() {
    local name url
    while IFS= read -r name; do
        if catalog_get "$name"; then
            fetch_source "$name" "$C_URL" "$C_FORMAT" "$(list_cache "$name")" "$NBBI_BLOCK_MIN4" "$NBBI_BLOCK_MIN6" || true
        else
            warn "unknown list '$name' in LISTS (see: nginx-block-bad-ips lists)"
        fi
    done < <(split_list "${CFG[LISTS]}")
    while read -r name url; do
        valid_list_name "$name" || { warn "custom list '$name': invalid name, skipped"; continue; }
        valid_url "$url" || { warn "custom list '$name': invalid URL, skipped"; continue; }
        fetch_source "custom:$name" "$url" plain "$(custom_cache "$name")" "$NBBI_BLOCK_MIN4" "$NBBI_BLOCK_MIN6" || true
    done < <(custom_lists)
}

download_cloudflare() {
    local t4 t6 dest="$NBBI_CACHE/cloudflare.txt" norm
    mkdir -p "$NBBI_CACHE"
    t4=$(mktemp "$NBBI_CACHE/.cf4.XXXXXX")
    t6=$(mktemp "$NBBI_CACHE/.cf6.XXXXXX")
    norm=$(mktemp "$NBBI_CACHE/.cfn.XXXXXX")
    if fetch_raw "$NBBI_CF_V4" "$t4" && fetch_raw "$NBBI_CF_V6" "$t6"; then
        { cat "$t4"; echo; cat "$t6"; } | normalize_stream plain 0 0 | sort -u > "$norm"
    fi
    if [ "$(count_lines "$norm")" -ge 10 ]; then
        chmod 0644 "$norm"
        mv -f -- "$norm" "$dest"
        record_source cloudflare "$(count_lines "$dest")" fresh
    else
        warn "cloudflare: could not refresh the IP ranges, using the cached/bundled copy"
        record_source cloudflare "$(count_lines "$dest")" cache
    fi
    rm -f -- "$t4" "$t6" "$norm"
}

# Cloudflare ranges: cached copy if present, otherwise the bundled one.
cloudflare_ranges() {
    if [ -s "$NBBI_CACHE/cloudflare.txt" ]; then
        cat "$NBBI_CACHE/cloudflare.txt"
    else
        normalize_stream plain 0 0 < "$NBBI_SHARE/cloudflare.txt"
    fi
}

geoip_countries() { split_list "${CFG[GEOIP_COUNTRIES]}" | tr '[:upper:]' '[:lower:]' | sort -u; }

download_geoip() {
    local gdir="$NBBI_CACHE/geoip" tgz tmpd cc url
    [ "${CFG[GEOIP_ENABLED]}" = yes ] || return 0
    mkdir -p "$gdir/v6"
    # IPv4: every country, so that "other country" and "no country" differ.
    tgz=$(mktemp "$NBBI_CACHE/.geo.XXXXXX")
    tmpd=$(mktemp -d "$gdir/.v4.XXXXXX")
    if fetch_raw "$NBBI_IPDENY_V4_ALL" "$tgz" && tar --no-same-owner -xzf "$tgz" -C "$tmpd" 2>/dev/null \
        && [ "$(find "$tmpd" -name '*.zone' | wc -l)" -ge 100 ]; then
        find "$tmpd" -name '*.zone' -exec chmod 0644 {} +
        rm -rf -- "$gdir/v4.old"
        [ -d "$gdir/v4" ] && mv -- "$gdir/v4" "$gdir/v4.old"
        mv -- "$tmpd" "$gdir/v4"
        rm -rf -- "$gdir/v4.old"
        chmod 0755 "$gdir/v4"
        record_source geoip-v4 "$(find "$gdir/v4" -name '*.zone' | wc -l | tr -d ' ') countries" fresh
    else
        rm -rf -- "$tmpd"
        if [ -d "$gdir/v4" ]; then
            warn "geoip: IPv4 country data download failed, keeping the cached copy"
            record_source geoip-v4 "cached" cache
        else
            warn "geoip: IPv4 country data download failed and there is no cached copy"
            record_source geoip-v4 0 none
        fi
    fi
    rm -f -- "$tgz"
    # IPv6: only the selected countries (the rest of 2000::/3 counts as "other").
    while IFS= read -r cc; do
        # shellcheck disable=SC2059
        url=$(printf "$NBBI_IPDENY_V6_FMT" "$cc")
        fetch_source "geoip-v6:$cc" "$url" plain "$gdir/v6/$cc.txt" 0 0 || true
    done < <(geoip_countries)
}

# Downloads everything the current configuration needs.
download_all() {
    mkdir -p "$NBBI_CACHE/lists" "$NBBI_STATE"
    SOURCES_STATUS_TMP=$(mktemp "$NBBI_STATE/.sources.XXXXXX")
    download_blocklists
    download_cloudflare
    download_geoip
    sort -t'|' -k1,1 "$SOURCES_STATUS_TMP" > "$NBBI_STATE/sources.status"
    rm -f -- "$SOURCES_STATUS_TMP"
    SOURCES_STATUS_TMP=""
}
