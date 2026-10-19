#!/usr/bin/env bash
# ===========================================================================
#  t04-https: live checks of the Caddy TLS front end (self-signed cert,
#  HTTP/2, HTTP/3, compression, X-Forwarded-* handling) and of the plain HTTP
#  port. Non-disruptive: only GET/HEAD requests and read-only inspection.
# ===========================================================================
. "$(dirname "$0")/lib.sh"
t_begin t04-https "HTTPS front end (Caddy), certificate, HTTP/2+3, compression"

PORT="$(nc_https_port)"
HPORT="$(nc_http_port)"
CERT="$T_ROOT/tls/site.crt"
LAN="$(lan_ip)"
HOST="$(hostname)"
TMP="$(t_tmpdir)"

if [ -z "$PORT" ] || [ ! -r "$CERT" ]; then
    t_fail "prerequisites: NEXTCLOUD_HTTPS_PORT and tls/site.crt" "port='$PORT' cert readable: $([ -r "$CERT" ] && echo yes || echo no)"
    t_end; exit $?
fi

# ---- names the certificate must cover -----------------------------------
NAMES=(localhost 127.0.0.1 "$HOST" "$HOST.local")
[ -n "$LAN" ] && NAMES+=("$LAN")
for d in $(cfg NEXTCLOUD_TRUSTED_DOMAINS); do NAMES+=("${d%%:*}"); done
# de-duplicate, keep order
UNIQ=(); declare -A seen=()
for n in "${NAMES[@]}"; do [ -n "$n" ] && [ -z "${seen[$n]:-}" ] && { seen[$n]=1; UNIQ+=("$n"); }; done
NAMES=("${UNIQ[@]}")

is_ip() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# fetch NAME PATH [curl args...]  -> "verify code version size" on stdout.
# Connects to the local listener (or the LAN IP itself for the LAN-IP case).
fetch() {
    local name="$1" path="$2"; shift 2
    local target=(--resolve "$name:$PORT:127.0.0.1")
    if is_ip "$name"; then
        target=(--connect-to "$name:$PORT:$( [ "$name" = "$LAN" ] && echo "$LAN" || echo 127.0.0.1 ):$PORT")
    fi
    https_curl "${target[@]}" -L -o "$TMP/body" \
        -w '%{ssl_verify_result} %{http_code} %{http_version} %{size_download}' \
        "$@" "https://$name:$PORT$path"
}

# ---- per-name checks ------------------------------------------------------
for n in "${NAMES[@]}"; do
    out="$(fetch "$n" /login 2>&1)"; rc=$?
    read -r verify code ver size <<<"$out"
    if [ "$rc" -ne 0 ]; then
        t_fail "[$n] HTTPS /login reachable and certificate verifies" "curl rc=$rc: $out"
        continue
    fi
    t_eq    "[$n] TLS verification result is 0 (cert covers this name)" 0 "$verify"
    t_eq    "[$n] /login ends in HTTP 200" 200 "$code"
    t_eq    "[$n] negotiated HTTP version is 2" 2 "$ver"
    t_ge    "[$n] /login body is not empty/blank-page sized (>1000 bytes)" 1001 "${size:-0}"
done

# ---- negative control: a name that is NOT in the certificate must fail ------
nout="$(https_curl --resolve "no-such-host.invalid:$PORT:127.0.0.1" -o /dev/null \
        -w '%{ssl_verify_result}' "https://no-such-host.invalid:$PORT/login" 2>&1)"; nrc=$?
if [ "$nrc" -ne 0 ] && [ "$nrc" -eq 60 ]; then
    t_pass "negative control: name not in certificate is rejected (curl rc=60)" "$nout"
else
    t_fail "negative control: name not in certificate must fail verification" "rc=$nrc out=$nout"
fi

# ---- certificate on the wire ------------------------------------------------
ssl_pem() { # name -> PEM of the cert actually served
    openssl s_client -connect "127.0.0.1:$PORT" -servername "$1" </dev/null 2>/dev/null |
        openssl x509 2>/dev/null
}
wire_fp="$(ssl_pem localhost | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
file_fp="$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
[ -n "$file_fp" ] && t_eq "served certificate fingerprint equals tls/site.crt (SHA-256)" "$file_fp" "$wire_fp" \
                  || t_fail "tls/site.crt is parseable" "no fingerprint"

sni_bad=""
for n in "${NAMES[@]}"; do
    [ "$(ssl_pem "$n" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)" = "$file_fp" ] || sni_bad+="$n "
done
t_eq "the same certificate is served for every SNI name (${#NAMES[@]} names)" "" "$sni_bad"

SANS="$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null)"
for n in "${NAMES[@]}"; do
    if is_ip "$n"; then t_match "cert SAN contains IP $n" "IP Address:$n([^0-9]|$)" "$SANS"
    else t_match "cert SAN contains DNS $n" "DNS:${n//./\\.}(,|$)" "$SANS"; fi
done
t_check "certificate is valid for more than 30 more days" openssl x509 -in "$CERT" -noout -checkend $((30 * 86400))
t_check "certificate has a not-yet-expired validity start" bash -c \
    'd=$(openssl x509 -in "$1" -noout -startdate | cut -d= -f2); [ "$(date -d "$d" +%s)" -le "$(date +%s)" ]' _ "$CERT"
keyinfo="$(openssl x509 -in "$CERT" -noout -text 2>/dev/null)"
if [[ "$keyinfo" =~ Public\ Key\ Algorithm:\ rsaEncryption ]]; then
    bits="$(sed -n 's/.*Public-Key: (\([0-9]*\) bit).*/\1/p' <<<"$keyinfo" | head -1)"
    t_ge "RSA key is at least 2048 bits" 2048 "${bits:-0}"
elif [[ "$keyinfo" =~ id-ecPublicKey ]]; then
    t_match "EC key uses a P-256 or stronger curve" 'prime256v1|secp384r1|secp521r1|P-256|P-384|P-521' "$keyinfo"
else
    t_fail "key type is RSA>=2048 or EC P-256+" "$(grep -m1 'Public Key Algorithm' <<<"$keyinfo")"
fi
t_match "certificate signature algorithm is not SHA-1/MD5" 'Signature Algorithm: (sha256|sha384|sha512|ecdsa-with-SHA(256|384|512)|ED25519)' "$keyinfo"

# ---- empty-body ("blank page") regression -----------------------------------
# A Caddyfile with directives outside a site block answered every real request
# with an EMPTY 200. A Host header that matches nothing must still be proxied.
out="$(https_curl -o "$TMP/odd" -w '%{http_code} %{size_download}' -H 'Host: whatever.example' "https://127.0.0.1:$PORT/" 2>&1)"
read -r code size <<<"$out"
t_ge "unknown Host header still reaches Nextcloud: body is non-empty" 1 "${size:-0}"
if [ "$code" = 200 ] && [ "${size:-0}" -eq 0 ]; then t_fail "regression: empty HTTP 200 (blank page)" "$out"
else t_pass "regression: no 0-byte HTTP 200 for an unmatched Host (got $code, ${size}B)"; fi
t_eq "unknown Host header is refused by Nextcloud as untrusted domain (400)" 400 "$code"
t_match "untrusted-domain page is rendered by Nextcloud" 'rusted' "$(cat "$TMP/odd" 2>/dev/null)"
out="$(https_curl -o "$TMP/root" -w '%{http_code} %{size_download} %{redirect_url}' "https://127.0.0.1:$PORT/" 2>&1)"
t_match "GET / is a redirect to /login (not an empty 200)" '^302 [0-9]* https://127\.0\.0\.1:'"$PORT"'/login$' "$out"
out="$(https_curl -o "$TMP/st" -w '%{size_download}' "https://127.0.0.1:$PORT/status.php" 2>&1)"
t_ge "status.php body is non-empty" 20 "$out"

# ---- content -----------------------------------------------------------------
https_curl "https://127.0.0.1:$PORT/login" -o "$TMP/login.html"
t_match "/login page identifies as Nextcloud" '[Nn]extcloud' "$(cat "$TMP/login.html")"
t_match "/login page contains a login form/markers" 'name="user"|id="user"|login' "$(cat "$TMP/login.html")"
asset="$(grep -oE 'src="/dist/[^"]+\.js[^"]*"' "$TMP/login.html" | head -1 | sed 's/^src="//; s/"$//; s/&amp;/\&/g')"
if [ -z "$asset" ]; then
    t_fail "found a /dist/*.js asset URL in the login HTML"
else
    t_pass "found a /dist/*.js asset URL in the login HTML" "$asset"
    A="https://127.0.0.1:$PORT$asset"
    id_size="$(https_curl -H 'Accept-Encoding: identity' -o /dev/null -w '%{size_download}' "$A")"
    hdr() { https_curl -D - -o /dev/null -H "Accept-Encoding: $1" "$A" | tr -d '\r' | tr 'A-Z' 'a-z'; }
    sz()  { https_curl -H "Accept-Encoding: $1" -o /dev/null -w '%{size_download}' "$A"; }
    t_ge "asset (identity) is a real file (>1000 bytes)" 1001 "$id_size"
    h="$(hdr identity)"; t_nomatch "identity request is served uncompressed" 'content-encoding:' "$h"
    h="$(hdr br)";   t_match "Accept-Encoding: br -> content-encoding: br" 'content-encoding: br' "$h"
    b="$(sz br)";    [ "$b" -lt "$id_size" ] && t_pass "brotli body ($b B) smaller than identity ($id_size B)" || t_fail "brotli body smaller than identity" "br=$b id=$id_size"
    h="$(hdr gzip)"; t_match "Accept-Encoding: gzip -> content-encoding: gzip" 'content-encoding: gzip' "$h"
    g="$(sz gzip)";  [ "$g" -lt "$id_size" ] && t_pass "gzip body ($g B) smaller than identity ($id_size B)" || t_fail "gzip body smaller than identity" "gzip=$g id=$id_size"
    h="$(hdr zstd)"; t_match "Accept-Encoding: zstd -> content-encoding: zstd" 'content-encoding: zstd' "$h"
    # decoded content must equal the identity content (compression is lossless)
    https_curl -H 'Accept-Encoding: identity' -o "$TMP/a.id" "$A"
    https_curl --compressed -H 'Accept-Encoding: br' -o "$TMP/a.br" "$A"
    t_eq "brotli-decoded asset equals the identity asset" "$(sha256sum <"$TMP/a.id")" "$(sha256sum <"$TMP/a.br")"
fi

# ---- HTTP/3 --------------------------------------------------------------------
if curl --version | grep -q HTTP3 || curl --help all 2>/dev/null | grep -q -- --http3-only; then
    out="$(https_curl --http3-only -o "$TMP/h3" -w '%{http_code} %{http_version} %{size_download}' "https://127.0.0.1:$PORT/status.php" 2>&1)"
    read -r code ver size <<<"$out"
    t_eq "HTTP/3: status 200 over QUIC" 200 "$code"
    t_eq "HTTP/3: negotiated HTTP version is 3" 3 "$ver"
    t_match "HTTP/3: status.php reports installed" '"installed":true' "$(cat "$TMP/h3")"
else
    t_skip "HTTP/3 request" "this curl has no HTTP/3 support"
fi
t_match "UDP listener for HTTP/3 exists on the HTTPS port" ":${PORT}[[:space:]]" "$(ss -lunH 2>/dev/null)"
t_match "TCP listener exists on the HTTPS port" ":${PORT}[[:space:]]" "$(ss -ltnH 2>/dev/null)"
h="$(https_curl -D - -o /dev/null "https://127.0.0.1:$PORT/login" | tr -d '\r' | tr 'A-Z' 'a-z')"
t_match "alt-svc header advertises h3" 'alt-svc: *h3=' "$h"
t_match "response passed through Caddy (Via header)" 'via: .*caddy' "$h"

# ---- X-Forwarded-Proto is honoured ---------------------------------------------------
t_nomatch "HTTPS login page contains no http:// link to its own host" "http://(127\.0\.0\.1|localhost|$HOST)[:/\"]" "$(cat "$TMP/login.html")"
loc="$(https_curl -o /dev/null -w '%{redirect_url}' "https://127.0.0.1:$PORT/")"
t_match "HTTPS redirect from / stays on https://" '^https://' "$loc"
loc="$(https_curl -o /dev/null -w '%{redirect_url}' "https://127.0.0.1:$PORT/.well-known/caldav")"
t_nomatch "HTTPS /.well-known/caldav redirect does not downgrade to http:// (CalDAV discovery)" '^http://' "$loc"
loc="$(https_curl -o /dev/null -w '%{redirect_url}' "https://127.0.0.1:$PORT/.well-known/carddav")"
t_nomatch "HTTPS /.well-known/carddav redirect does not downgrade to http:// (CardDAV discovery)" '^http://' "$loc"

subnet="$(podman network inspect nextcloud-net --format '{{range .Subnets}}{{.Subnet}}{{end}}' 2>/dev/null)"
tp="$(./setup.sh occ config:system:get trusted_proxies 0 </dev/null 2>&1)"
t_match "podman network nextcloud-net has a subnet" '^[0-9.]+/[0-9]+$' "$subnet"
t_eq    "occ trusted_proxies[0] equals the nextcloud-net subnet" "$subnet" "$tp"
op="$(./setup.sh occ config:system:get overwriteprotocol </dev/null 2>&1)"; oprc=$?
if [ "$oprc" -ne 0 ] || [ -z "$op" ]; then t_pass "overwriteprotocol is NOT set (plain HTTP keeps working)"
else t_fail "overwriteprotocol must be unset" "value=$op"; fi

# ---- plain HTTP port ---------------------------------------------------------------------
if [ -n "$HPORT" ]; then
    out="$(curl -sS --max-time 20 "http://127.0.0.1:$HPORT/status.php")"
    t_match "plain HTTP status.php: installed:true" '"installed":true' "$out"
    t_match "plain HTTP status.php: maintenance:false" '"maintenance":false' "$out"
    curl -sS --max-time 20 "http://127.0.0.1:$HPORT/login" -o "$TMP/plain.html"
    t_match "plain HTTP /login is a real Nextcloud page" '[Nn]extcloud' "$(cat "$TMP/plain.html")"
    t_nomatch "plain HTTP page does not force https:// links to its own host" "https://(127\.0\.0\.1|localhost|$HOST)[:/\"]" "$(cat "$TMP/plain.html")"
    loc="$(curl -sS --max-time 20 -o /dev/null -w '%{redirect_url}' "http://127.0.0.1:$HPORT/")"
    t_match "plain HTTP redirect from / stays on http://" '^http://' "$loc"
fi

# ---- Caddy listens only on :443 --------------------------------------------------------------
t_nomatch "no plaintext HTTP is served on the TLS port (client sees no Nextcloud over http://)" '"installed"' \
    "$(curl -sS --max-time 10 "http://127.0.0.1:$PORT/status.php" 2>&1)"
pm="$(podman port nextcloud-caddy 2>/dev/null)"
t_match "caddy publishes 443/tcp" "443/tcp -> [0-9.]+:$PORT" "$pm"
t_match "caddy publishes 443/udp (HTTP/3)" "443/udp -> [0-9.]+:$PORT" "$pm"
t_nomatch "caddy publishes nothing for port 80" '(^|\n)80/' "$pm"
t_check_not "port 80 on loopback does not answer" curl -sS --max-time 3 -o /dev/null "http://127.0.0.1:80/"

# ---- robustness: 20 sequential requests ---------------------------------------------------------
bad=0; codes=""
for i in $(seq 1 20); do
    c="$(https_curl -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/status.php" 2>&1)"
    codes+="$c "; [ "$c" = 200 ] || bad=$((bad + 1))
done
t_eq "20 sequential HTTPS /status.php requests are all 200" 0 "$bad"

t_end
