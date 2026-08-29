#!/usr/bin/env bash
#
# make-signing-cert.sh — create the self-signed certificate zBezel is signed
# with, and import it into the login keychain. Run once per machine.
#
# WHY THIS EXISTS
#
# zBezel needs Accessibility permission: the KVM cannot capture or suppress
# input without it. macOS records that grant against the app's designated
# requirement, and what that requirement contains depends entirely on how the
# app is signed.
#
# Signed ad-hoc, there is no identity to name, so the requirement is the cdhash
# of the binary — and the cdhash changes with every code change. The failure is
# quiet and confusing: the entry stays in the Accessibility list, still switched
# on, but it now describes a build that no longer exists, so it matches nothing
# and the app asks for permission again. Toggling it off and on does not help,
# because the stale hash is what is stored; only removing and re-adding does.
#
# Signed with a certificate, the requirement becomes
#
#     identifier zBezel and certificate root = H"<this certificate>"
#
# which survives every rebuild. The grant is given once.
#
# This certificate is NOT trusted and is not meant to be. Trust governs
# Gatekeeper verification; TCC only needs a stable identity to name. `security
# find-identity -v -p codesigning` will keep reporting it as invalid
# (CSSMERR_TP_NOT_TRUSTED) and codesign will keep using it happily.
#
# Self-signed rather than an Apple Development certificate on purpose: those are
# issued to an employer, expire yearly, and can be revoked when the relationship
# ends. Any of those would silently break the grant again. This one is good for
# ten years and depends on nothing.
#
set -euo pipefail

NAME="zBezel Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "'$NAME' is already in the keychain — nothing to do."
    security find-certificate -c "$NAME" -p \
        | openssl x509 -noout -subject -enddate | sed 's/^/  /'
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM
umask 077

# A transient passphrase for the PKCS#12 only. It never leaves this script and
# the file it protects is deleted on exit.
PW="$(openssl rand -hex 16)"

echo "==> generating a 10-year self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME/O=$(id -un)" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

echo "==> packaging"
# macOS's Security framework cannot read OpenSSL 3's modern PKCS#12 defaults —
# the import fails with "MAC verification failed", which reads like a wrong
# password and is not. Pin the algorithms it understands.
if ! openssl pkcs12 -export -legacy -out "$WORK/cert.p12" \
        -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -name "$NAME" -passout "pass:$PW" >/dev/null 2>&1; then
    openssl pkcs12 -export -out "$WORK/cert.p12" \
        -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -passout "pass:$PW" >/dev/null 2>&1
fi

echo "==> importing into the login keychain"
# -T /usr/bin/codesign pre-authorises codesign to use the private key, so builds
# do not raise a keychain prompt each time.
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PW" \
    -T /usr/bin/codesign -T /usr/bin/security

echo
echo "Done. Scripts/build-app.sh will pick this up automatically."
security find-certificate -c "$NAME" -Z 2>/dev/null | grep 'SHA-1' | sed 's/^/  /'
cat <<'NOTE'

One thing still has to happen by hand, once: the Accessibility entry granted
against the OLD ad-hoc signature does not match the newly signed app. In
System Settings > Privacy & Security > Accessibility, select zBezel, remove it
with the minus button, then add it again. Removing matters — toggling it off
and on keeps the stale requirement.

After that it holds across rebuilds.
NOTE
