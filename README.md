# msget

Setup and operator tools for [MSGET](https://hub.docker.com/r/msget/msget-app), self-hosted iMessage for AI agents and automations: an agent skill that runs guided onboarding, MacSpec (the macOS hardware-profile exporter onboarding sometimes needs), the release-image verification key, and operator how-to docs.

## Agent skill

`skills/msget` is an [Agent Skills](https://agentskills.io) package. It teaches a coding agent to deploy MSGET's two-service Docker Compose or rootless Podman topology and drive onboarding as a guided loop — account sign-in, the Apple verification challenge, interface setup — through `msgetctl`.

Install from this repo with any Agent Skills installer:

```sh
npx skills add msget-app/msget
```

or point the installer at `https://github.com/msget-app/msget/tree/main/skills/msget`. Without an installer, copy `skills/msget` into your agent's skills directory.

## MacSpec

Export your Mac's hardware identifiers as a Base64 configuration for MSGET — the `APPLE_HARDWARE_PROFILE` that onboarding asks for when no hardware configuration is ready.
The macOS product version and build are pinned to 26.5.1 (`25F80`).

Requires macOS 11+ (Apple Silicon or Intel). No developer tools needed — download the prebuilt universal binary from the latest release:

```sh
curl -fsSL https://github.com/msget-app/msget/releases/latest/download/macspec -o macspec && chmod +x macspec && ./macspec
```

Copy the single output line into MSGET's hardware configuration input. Keep it private: it contains device identifiers.

For diagnostics, run `HWINFO_DEBUG=1 ./macspec`. Errors go to stderr.

Alternatively, run from source without cloning. This requires Apple's Command Line Tools (`xcode-select --install` if missing), which include Swift and the macOS SDK:

```sh
curl -fsSL https://raw.githubusercontent.com/msget-app/msget/main/MacSpec.swift | xcrun swift -
```

## Verifying release images

`msget-image.pub` is the public key for MSGET's signed release indexes and SBOM attestations. The [Docker Hub guide](https://hub.docker.com/r/msget/msget-app) has the full procedure; fetch the key with:

```sh
curl -fsSLO https://raw.githubusercontent.com/msget-app/msget/main/msget-image.pub
```

The key lives in this repo so any rotation is visible in git history.

## Operator docs

- [Network isolation: Standard and Docker Strong](docs/network-isolation.md) — firewall the core away from MSGET's hosted services.
- [Capturing the broker's traffic](docs/traffic-capture.md) — watch hosted-service traffic yourself with your own CA.
- [Backup, restore, and deletion of local state](docs/backup-and-deletion.md) — what is on disk, and how to remove it.
