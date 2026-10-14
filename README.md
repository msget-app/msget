# msget

Setup tools for [MSGET](https://hub.docker.com/r/msget/msget-app), a self-hosted iMessage/Telegram bridge: an agent skill that runs guided onboarding, and MacSpec, the macOS hardware-profile exporter that onboarding sometimes needs.

## Agent skill

`skills/msget` is an [Agent Skills](https://agentskills.io) package. It teaches a coding agent to deploy MSGET (Docker Compose or the single-file Linux binary) and drive onboarding as a guided loop — account sign-in, the Apple verification challenge, interface setup — through `msgetctl`.

Install from this repo with any Agent Skills installer:

```sh
npx skills add msget-app/msget
```

or point the installer at `https://github.com/msget-app/msget/tree/main/skills/msget`. Without an installer, copy `skills/msget` into your agent's skills directory.

## MacSpec

Export your Mac's hardware identifiers as a Base64 configuration for MSGET — the `APPLE_HARDWARE_PROFILE` that onboarding asks for when no hardware configuration is ready.
The macOS product version and build are pinned to 26.5.1 (`25F80`).

Requires macOS 11+ and Apple's Command Line Tools, which include Swift and the macOS SDK. Full Xcode and Homebrew are unnecessary.

If the tools are missing, run the following built-in macOS command and complete the installation dialog:

```sh
xcode-select --install
```

Run in Bash, Zsh, or Fish without cloning:

```sh
curl -fsSL https://raw.githubusercontent.com/msget-app/MacSpec/main/MacSpec.swift | xcrun swift -
```

Copy the single output line into MSGET's hardware configuration input. Keep it private: it contains device identifiers.

For diagnostics, replace `xcrun swift -` with `env HWINFO_DEBUG=1 xcrun swift -`. Errors go to stderr.
