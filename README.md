# Otaku Prime Kodi Repository

This repository is the **distribution and update repository** for [Otaku Prime](https://github.com/Halfe85/Otaku-Prime).

It is intentionally separate from the source repository. Kodi installs versioned ZIP packages from here; development happens in `Halfe85/Otaku-Prime`.

## Update channels

| Kodi repository | Source branch | Purpose |
| --- | --- | --- |
| `repository.otaku-prime` | `main` | Stable releases only |
| `repository.otaku-prime.dev` | `Otaku-Prime` | Development/beta builds |

Feature branches are never published directly to Kodi.

## Version policy

- Stable: `MAJOR.MINOR.PATCH`, for example `0.2.0`
- Development: stable target plus beta build, for example `0.3.0~beta42`
- Published ZIPs are immutable. A released version is never silently overwritten.
- Git commit SHA and source branch are recorded by the build pipeline.

## Generated files

The repository workflow generates Kodi `addons.xml`, MD5 checksums, installer ZIPs, and versioned addon ZIPs. Generated packages should not be edited manually.
