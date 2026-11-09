# CI Signing with a Persistent Certificate

macOS ties Full Disk Access to an app's signing identity.
Ad-hoc CI builds get a new identity every time, so each update loses the grant.
Signing every CI build with one long-lived certificate keeps the identity stable.

## Workflow Behavior

- Every PR runs the localization check, `xcodegen generate` and `xcodebuild test`.
- Packaging runs only when `signing/BookmarkSync-Signing.crt` exists, for same-repo PRs and manual runs.
- `scripts/sign_app.sh` imports the P12 from secrets into a throwaway keychain, signs the app and checks it is anchored to the committed certificate.
- `scripts/check_signing_identity.sh` re-signs a modified copy and checks the designated requirement is unchanged.
- Fork PRs never receive the secrets.

This is not a Developer ID certificate, so Gatekeeper still warns on first launch.

## One-Time Setup

Generate the key and certificate outside the repository:

```zsh
dir="$HOME/Library/Application Support/BookmarkSync-Signing"
mkdir -p "$dir" && chmod 700 "$dir" && cd "$dir"
openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
  -keyout signing.key -out BookmarkSync-Signing.crt \
  -subj "/CN=BookmarkSync CI Signing/O=BookmarkSync" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
openssl rand -hex 24 > p12-password.txt
openssl pkcs12 -export -inkey signing.key -in BookmarkSync-Signing.crt \
  -out BookmarkSync-Signing.p12 -passout file:p12-password.txt \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
rm signing.key
```

The legacy PBE flags keep the P12 importable by macOS `security`.
Back up this directory; the private key cannot be recovered from GitHub.

Upload the secrets and commit only the public certificate:

```zsh
dir="$HOME/Library/Application Support/BookmarkSync-Signing"
base64 -i "$dir/BookmarkSync-Signing.p12" | gh secret set MACOS_SIGNING_P12_BASE64
gh secret set MACOS_SIGNING_P12_PASSWORD < "$dir/p12-password.txt"
mkdir -p signing && cp "$dir/BookmarkSync-Signing.crt" signing/
```

## Switching from Ad-hoc Builds

The first certificate-signed build has a new identity, so grant access once more:

1. Quit BookmarkSync and replace `/Applications/BookmarkSync.app`.
2. In **System Settings → Privacy & Security → Full Disk Access**, remove the old entry and add the new app.
3. Relaunch and confirm Safari bookmarks are readable.

Later builds signed with the same certificate should keep the grant.
Replacing the certificate changes the identity and requires granting access again.
