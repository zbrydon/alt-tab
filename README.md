# AltTab

Option+Tab window switcher for macOS. Single Swift file, ~120KB binary, no dependencies, Command Line Tools only. Requires the Accessibility permission. Screen Recording is optional: with it, tiles show live window previews; without it, app icons.

## Build and run

```sh
make run        # build AltTab.app and launch it
make install    # copy to ~/Applications and launch
```

On first launch, grant Accessibility (and optionally Screen Recording) in System Settings > Privacy & Security, then relaunch (`make run`).

Launch at login: System Settings > General > Login Items > add `~/Applications/AltTab.app`.

Quit: `killall AltTab`.

## Keys

| Keys              | Action                                              |
| ----------------- | --------------------------------------------------- |
| Option+Tab        | next window (quick tap toggles the two most recent) |
| Option+Shift+Tab  | previous window                                     |
| Option+Arrow keys | move selection (wraps at the edges)                 |
| Option+Esc        | cancel                                              |
| release Option    | switch to selection                                 |

## Keeping the permission across rebuilds

macOS ties the Accessibility grant to the code signature. The default ad-hoc signature changes every build, so the grant is lost. Fix it once with a self-signed certificate:

1. Create the identity from the CLI (Keychain Access's Certificate Assistant may not be available):
   ```sh
   printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=AltTab Local\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > /tmp/c.cnf
   /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config /tmp/c.cnf -keyout /tmp/k.pem -out /tmp/c.pem
   /usr/bin/openssl pkcs12 -export -inkey /tmp/k.pem -in /tmp/c.pem -out /tmp/id.p12 -passout pass:x
   security import /tmp/id.p12 -k ~/Library/Keychains/login.keychain-db -P x -T /usr/bin/codesign
   rm /tmp/c.cnf /tmp/k.pem /tmp/c.pem /tmp/id.p12
   ```
   `security find-identity -p codesigning` shows it as `CSSMERR_TP_NOT_TRUSTED`; that is fine for local signing.
2. `make` (the Makefile signs with `AltTab Local` by default; override with `make SIGN_ID="..."`, or `SIGN_ID=-` for ad-hoc). On the first build, approve codesign's keychain prompt with Always Allow.
3. Re-grant Accessibility and Screen Recording once. Later rebuilds keep them.

If the permission gets stuck, `make reset` clears it.

Set `ALTTAB_DEBUG=1` and run `AltTab.app/Contents/MacOS/AltTab` to log enumeration timings.
