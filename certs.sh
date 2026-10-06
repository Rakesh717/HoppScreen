#!/bin/bash
# certs.sh — local HTTPS certificates for pad6display (called by run.sh).
#
#  certs/ca.crt / ca.key   a private CA, created ONCE. Install ca.crt on the Pad
#                          (./adb-launch.sh --install-ca) and https://<mac-ip>:8443
#                          is trusted with no warnings.
#                          The CA is NAME-CONSTRAINED: it can only vouch for private
#                          LAN IPs, localhost and *.local, so even a leaked ca.key can't
#                          impersonate real websites to the Pad. Keep ca.key private anyway.
#  certs/server.p12        leaf cert for this Mac's CURRENT private IPs. Re-issued
#                          automatically whenever the IP set changes (new Wi-Fi etc.).
set -e
cd "$(dirname "$0")"
mkdir -p certs
chmod 700 certs
D=certs
P12_PASS=pad6display

# private IPv4 addresses of this Mac (the constraints below only permit these ranges)
IPS=$(ifconfig | awk '/inet /{print $2}' | grep -E '^(10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' | sort -u)
HOST=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
WANT="$HOST $(echo $IPS)"

if [ ! -f $D/ca.key ] || [ ! -f $D/ca.crt ]; then
  echo "[certs] creating local CA (one-time)"
  cat > $D/ca.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
CN = pad6display local CA
O = pad6display
[v3_ca]
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
nameConstraints = critical, permitted;IP:10.0.0.0/255.0.0.0, permitted;IP:172.16.0.0/255.240.0.0, permitted;IP:192.168.0.0/255.255.0.0, permitted;IP:127.0.0.0/255.0.0.0, permitted;IP:169.254.0.0/255.255.0.0, permitted;IP:100.64.0.0/255.192.0.0, permitted;DNS:localhost, permitted;DNS:local
EOF
  openssl ecparam -name prime256v1 -genkey -noout -out $D/ca.key 2>/dev/null
  chmod 600 $D/ca.key
  openssl req -x509 -new -key $D/ca.key -sha256 -days 3650 -config $D/ca.cnf -out $D/ca.crt
  rm -f $D/server.p12 $D/server.ips
fi

# re-issue the leaf if missing, IPs changed, or expiring within 7 days
if [ -f $D/server.p12 ] && [ -f $D/server.crt ] && [ "$(cat $D/server.ips 2>/dev/null)" = "$WANT" ] \
   && openssl x509 -checkend 604800 -noout -in $D/server.crt >/dev/null 2>&1; then
  exit 0
fi

echo "[certs] issuing server certificate for: localhost $HOST.local $(echo $IPS)"
{
  echo "[req]"
  echo "distinguished_name = dn"
  echo "prompt = no"
  echo "[dn]"
  echo "CN = pad6display"
  echo "[ext]"
  echo "basicConstraints = critical, CA:false"
  echo "keyUsage = critical, digitalSignature"
  echo "extendedKeyUsage = serverAuth"
  echo "subjectKeyIdentifier = hash"
  echo "authorityKeyIdentifier = keyid"
  echo "subjectAltName = @san"
  echo "[san]"
  echo "DNS.1 = localhost"
  echo "DNS.2 = $HOST.local"
  i=1; for ip in $IPS; do echo "IP.$i = $ip"; i=$((i+1)); done
} > $D/server.cnf
openssl ecparam -name prime256v1 -genkey -noout -out $D/server.key 2>/dev/null
chmod 600 $D/server.key
openssl req -new -key $D/server.key -config $D/server.cnf -out $D/server.csr
openssl x509 -req -in $D/server.csr -CA $D/ca.crt -CAkey $D/ca.key -CAcreateserial \
  -days 397 -sha256 -extfile $D/server.cnf -extensions ext -out $D/server.crt 2>/dev/null
# 3DES/SHA1 PKCS#12 encoding: readable by every macOS SecPKCS12Import version
openssl pkcs12 -export -inkey $D/server.key -in $D/server.crt -certfile $D/ca.crt \
  -name pad6display -passout pass:$P12_PASS \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -out $D/server.p12
chmod 600 $D/server.p12
rm -f $D/server.csr
echo "$WANT" > $D/server.ips
