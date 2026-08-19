# zone-out

Windows-only D CLI. Writes WinINet **Trusted Sites** (`ZoneId=2`) into the Internet Settings Zone Map so Chromium downloads from first-party origins skip Mark of the Web preview blocks in Explorer.

## Facts

- Hive: default writes go to `HKCU`. `--hive hklm|hkcu` forces one, and `HKLM` requires elevation.
- Seed: [`data/seed.sdl`](data/seed.sdl) (compile-time import). First-party SaaS exports and vendor docs — not UGC hosts.
- Deny: [`data/denylist.sdl`](data/denylist.sdl). Exact host or suffix (`foo.s3.amazonaws.com` matches `s3.amazonaws.com`). Always wins over seed/`add`.
- Public Suffix List snapshot: [`data/public-suffix-list.dat`](data/public-suffix-list.dat). Refresh with [`scripts/update-psl.ps1`](scripts/update-psl.ps1).
- Zone Map keys: `Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\<registrable>[\<leftover>]`, DWORD `https` (or `--protocol`) = `2`.
- Firefox has its own zone story; this tool targets Edge/Chrome Attachment Manager / WinINet.
- No LLM in v0.1 — curated lists only. Classifier hook is future work, not a generator for the allowlist.
- Windows-only; do not add a polyglot release matrix for Zone Map writes.

## Build

```powershell
dub build --compiler=ldc2
dub test --compiler=ldc2
```
