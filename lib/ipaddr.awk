# ipaddr.awk - IPv4/IPv6 parsing helpers for nginx-block-bad-ips.
#
# Strictly POSIX awk: no interval expressions, no bitwise functions and no
# gawk extensions, so it behaves the same under mawk (Ubuntu), gawk (Rocky)
# and BWK awk. Integers stay below 2^53, so double arithmetic is exact.
#
# Select behaviour with -v MODE=...:
#   normalize  read blocklist text, print one canonical CIDR per line.
#              -v FORMAT=plain|json-cidr  -v MIN4=8 -v MIN6=16
#   zones4     read ipdeny *.zone files (country code = file name) and print
#              "start end flag" (S = selected country, K = any other country).
#              -v SEL="br us ..."
#   merge4     read sorted "start end flag" lines, print merged nginx
#              "a.b.c.d-e.f.g.h flag;" ranges. The rare overlapping range is
#              clipped so the output never overlaps (nginx "ranges" needs that).
#   contains   print every input CIDR (first field) that contains -v IP=...
#              (-v SHOWFILE=1 prefixes each match with the file name and a tab)

function is_dec(s) { return s ~ /^[0-9]+$/ }

function v4num(ip,    o, n, i) {
    n = split(ip, o, ".")
    if (n != 4) return -1
    for (i = 1; i <= 4; i++)
        if (!is_dec(o[i]) || length(o[i]) > 3 || o[i] + 0 > 255) return -1
    return ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
}

function v4str(n,    a, b, c, d) {
    d = n % 256; n = (n - d) / 256
    c = n % 256; n = (n - c) / 256
    b = n % 256; a = (n - b) / 256
    return a "." b "." c "." d
}

function hexval(h,    i, c, v) {
    v = 0
    for (i = 1; i <= length(h); i++) {
        c = index("0123456789abcdef", substr(h, i, 1))
        if (c == 0) return -1
        v = v * 16 + c - 1
    }
    return v
}

function hexstr(v,    s, d) {
    if (v == 0) return "0"
    s = ""
    while (v > 0) {
        d = v % 16
        s = substr("0123456789abcdef", d + 1, 1) s
        v = (v - d) / 16
    }
    return s
}

# Parses an IPv6 address into G6[1..8] and masks it to the prefix length.
# Embedded IPv4 notation and zone ids are rejected on purpose.
function parse6(ip, lenstr,    L, R, nl, nr, i, k, pos, left, right, miss, len, start, size) {
    ip = tolower(ip)
    if (ip ~ /[^0-9a-f:]/) return 0
    pos = index(ip, "::")
    if (pos > 0) {
        left = substr(ip, 1, pos - 1)
        right = substr(ip, pos + 2)
        if (index(right, "::") > 0) return 0
        nl = (left == "") ? 0 : split(left, L, ":")
        nr = (right == "") ? 0 : split(right, R, ":")
        miss = 8 - nl - nr
        if (miss < 1) return 0
    } else {
        nl = split(ip, L, ":")
        nr = 0; miss = 0
        if (nl != 8) return 0
    }
    k = 0
    for (i = 1; i <= nl; i++) {
        if (L[i] == "" || length(L[i]) > 4) return 0
        G6[++k] = hexval(L[i])
    }
    for (i = 1; i <= miss; i++) G6[++k] = 0
    for (i = 1; i <= nr; i++) {
        if (R[i] == "" || length(R[i]) > 4) return 0
        G6[++k] = hexval(R[i])
    }
    if (lenstr == "") len = 128
    else {
        if (!is_dec(lenstr) || length(lenstr) > 3) return 0
        len = lenstr + 0
        if (len > 128) return 0
    }
    for (i = 1; i <= 8; i++) {
        start = (i - 1) * 16
        if (start >= len) G6[i] = 0
        else if (start + 16 > len) {
            size = 2 ^ (16 - (len - start))
            G6[i] = G6[i] - (G6[i] % size)
        }
    }
    P_FAM = 6; P_LEN = len
    return 1
}

# RFC 5952 text form of G6[]: lowercase, no leading zeros, longest zero run as ::
function v6str(    i, best, bestlen, cur, curlen, s) {
    best = 0; bestlen = 0; cur = 0; curlen = 0
    for (i = 1; i <= 8; i++) {
        if (G6[i] == 0) {
            if (curlen == 0) cur = i
            curlen++
            if (curlen > bestlen) { best = cur; bestlen = curlen }
        } else curlen = 0
    }
    if (bestlen < 2) bestlen = 0
    s = ""
    for (i = 1; i <= 8; i++) {
        if (bestlen > 0 && i == best) { s = s "::"; i += bestlen - 1; continue }
        if (s != "" && substr(s, length(s)) != ":") s = s ":"
        s = s hexstr(G6[i])
    }
    return s
}

# Parses "addr" or "addr/len". Sets P_FAM, P_LEN and, for IPv4, P_NUM/P_END
# (network and broadcast as numbers); for IPv6 the masked groups are in G6[].
function parse_cidr(s,    parts, n, num, len, size) {
    n = split(s, parts, "/")
    if (n < 1 || n > 2 || parts[1] == "") return 0
    if (index(parts[1], ":") > 0) return parse6(parts[1], (n == 2) ? parts[2] : "")
    num = v4num(parts[1])
    if (num < 0) return 0
    if (n == 2) {
        if (!is_dec(parts[2]) || length(parts[2]) > 2) return 0
        len = parts[2] + 0
        if (len > 32) return 0
    } else len = 32
    size = 2 ^ (32 - len)
    P_FAM = 4; P_LEN = len
    P_NUM = num - (num % size)
    P_END = P_NUM + size - 1
    return 1
}

function cidr_str() {
    if (P_FAM == 4) return v4str(P_NUM) ((P_LEN < 32) ? "/" P_LEN : "")
    return v6str() ((P_LEN < 128) ? "/" P_LEN : "")
}

function token(    t) {
    t = $0
    sub(/\r$/, "", t)
    if (FORMAT == "json-cidr") {
        if (!match(t, /"cidr"[ ]*:[ ]*"[^"]*"/)) return ""
        t = substr(t, RSTART, RLENGTH)
        sub(/^"cidr"[ ]*:[ ]*"/, "", t)
        sub(/"$/, "", t)
        return t
    }
    sub(/[#;].*/, "", t)
    sub(/^[ \t]+/, "", t)
    sub(/[ \t].*/, "", t)
    return t
}

BEGIN {
    if (MIN4 == "") MIN4 = 0
    if (MIN6 == "") MIN6 = 0
    MIN4 += 0; MIN6 += 0
    if (MODE == "zones4") {
        n = split(SEL, sel, " ")
        for (i = 1; i <= n; i++) SELECTED[tolower(sel[i])] = 1
    }
    if (MODE == "contains") {
        if (!parse_cidr(IP)) { print "invalid address: " IP > "/dev/stderr"; BAD_TARGET = 1; exit 2 }
        T_FAM = P_FAM
        if (T_FAM == 4) T_NUM = P_NUM
        else for (i = 1; i <= 8; i++) TG[i] = G6[i]
    }
}

MODE == "normalize" {
    t = token()
    if (t == "" || !parse_cidr(t)) next
    if (P_FAM == 4 && P_LEN < MIN4) next
    if (P_FAM == 6 && P_LEN < MIN6) next
    print cidr_str()
    next
}

MODE == "zones4" {
    t = token()
    if (t == "" || !parse_cidr(t) || P_FAM != 4) next
    cc = FILENAME
    sub(/.*\//, "", cc)
    sub(/\..*$/, "", cc)
    cc = tolower(cc)
    # "zz" holds reserved/undelegated blocks: that is "no country", not a country
    if (cc == "zz") next
    printf "%.0f %.0f %s\n", P_NUM, P_END, ((cc in SELECTED) ? "S" : "K")
    next
}

MODE == "merge4" {
    s = $1 + 0; e = $2 + 0; f = $3
    if (have && s <= ce + 1) {
        if (f == cf) { if (e > ce) ce = e; next }
        if (s <= ce) {
            s = ce + 1
            if (s > e) next
        }
    }
    if (have) printf "    %s-%s %s;\n", v4str(cs), v4str(ce), cf
    cs = s; ce = e; cf = f; have = 1
    next
}

MODE == "contains" {
    t = $1
    if (t == "" || t ~ /^#/ || !parse_cidr(t) || P_FAM != T_FAM) next
    if (P_FAM == 4) {
        if (T_NUM >= P_NUM && T_NUM <= P_END) print (SHOWFILE ? FILENAME "\t" : "") t
        next
    }
    for (i = 1; i <= 8; i++) {
        st = (i - 1) * 16
        if (st >= P_LEN) break
        g = TG[i]
        if (st + 16 > P_LEN) { sz = 2 ^ (16 - (P_LEN - st)); g = g - (g % sz) }
        if (g != G6[i]) next
    }
    print (SHOWFILE ? FILENAME "\t" : "") t
    next
}

END {
    if (MODE == "merge4" && have) printf "    %s-%s %s;\n", v4str(cs), v4str(ce), cf
    if (BAD_TARGET) exit 2
}
