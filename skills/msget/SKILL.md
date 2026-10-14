---
name: msget
description: Deploy and onboard MSGET, a self-hosted iMessage/Telegram bridge, with Docker Compose or the single-file Linux binary (server, desktop, or bot VM such as a Grok computer). Use when setting up MSGET, resuming unfinished onboarding, or driving account sign-in and the Apple activation challenge through msgetctl status and nextActions.
---

# MSGET onboarding for agents

Onboarding is guided, not autonomous. Several steps need the user in the loop — above all the Apple verification challenge: its code exists only after the challenge starts, and only the user can read it. You drive a loop: run the agent steps yourself, stop and ask the user at human steps. The service stores all progress server-side, so the loop can stop and resume at any point, including in a later session.

Two install forms share one onboarding CLI, `msgetctl` (run `msgetctl --help` for the command list). Pick the form in section 1; everything after it is shared. `msgetctl` in this guide means:

- Docker: `docker compose exec -T msget /usr/local/bin/msgetctl`
- Binary: `./msget ctl` in the install directory

## Rules

- Follow `awaiting` and `nextActions` from `status --json`. Do not invent steps.
- Never put secrets in command arguments. Never repeat codes, passwords, or tokens in reports.
- Pipe secrets on stdin only. Never write decoded secrets to disk.
- Do not retry a rejected code automatically. Ask the user for a new code.
- Do not reset ownership to bypass sign-in.
- Do not send a live message as a setup test.
- Use `msgetctl wait` for asynchronous steps. Do not write sleep loops.

## 1. Start or resume

### Docker Compose

1. Create `compose.yaml` from the Docker Hub overview (`docker.io/msget/msget-app`). Keep existing state volumes.
2. Run `docker compose up -d`.

### Single-file binary (no Docker)

1. Pick the install directory. On a Grok Bot computer, use `/workspace/msget` (the durable disk). Download the binary for the host architecture (`uname -m`: `x86_64` → `amd64`, `aarch64` → `arm64`) and `SHA256SUMS` for one pinned release version from `https://github.com/msget-app/msget-app/releases/download/msget%2Fv$VERSION/`, then verify:

   ```sh
   cd /workspace/msget
   sha256sum -c SHA256SUMS --ignore-missing
   mv msget-$VERSION-linux-amd64 msget
   chmod +x msget
   ```

2. Copy `start.sh` from this skill's directory beside the binary and run it. It starts the service headless with state in `./state`, or reports `already running`. Run it at the start of every session that needs messaging: the host may hibernate or be recreated between sessions, while `./state` on durable disk persists.

   ```sh
   ./start.sh
   ```

### Then, both forms

Run `msgetctl status --json`. If you are resuming earlier onboarding, starting the service plus this status is the whole restart: `status` reports where it stopped.

## 2. Run the loop

Repeat until `awaiting` is `done`:

| `awaiting` | You do |
| --- | --- |
| `agent` | Run the `agent` entries in `nextActions` yourself. |
| `human` | Stop. Ask the user (section 3), submit their input with the given command. |
| `operation` | Run `msgetctl wait --operation ID`. |

Each `nextActions` entry has `command`, `description`, `actor` (`agent` or `human`), and `needs` (`none`, `credentials`, `choice`, `code`, or `acknowledgement`). Run `status` again after every step. Exit code 3 means the loop continues; other codes are in the exit-code table.

For Apple recovery after setup, the same loop applies with the `apple recovery` commands.

## 3. Human moments

| `needs` | Ask the user for | Submit with |
| --- | --- | --- |
| `credentials` | Account or Apple credentials, through a credential channel below | the given `--env-file -` command |
| `code` | The code Apple or the account email just sent them | `--code-stdin` (below) |
| `choice` | A decision: `sms` or `trusted_device`; one of the redacted numbers in `operation.smsOptions`; or which interfaces to enable | the given command with the chosen option |
| `acknowledgement` | Confirmation that they saved the revealed BlueBubbles password | `interfaces acknowledge-password`, only after they confirm |

Submit a code like this (codes are short-lived; ask only when the stage asks):

```sh
printf '%s\n' "$CODE" | msgetctl apple verify --operation "$OP" --code-stdin --json
```

If `operation.failureCode` is `apple_code_rejected`, Apple did not accept the code. Ask the user for the code again, or run `apple resend` for a new code.

**Before `apple start`, confirm the user is present now**, with their trusted device or phone reachable, and able to reply promptly. Keep the service running until the challenge completes — on a bot VM, do not let the host hibernate mid-challenge. Restarting the service interrupts the operation (stage `interrupted`), and Apple activation must start over; progress before `apple start` is preserved.

**Dashboard-only steps** appear as a `dashboard` action with `actor: human`, `needs: none`: Telegram sign-in and adding activation quota. With Docker, the user does these in the web dashboard and you resume the loop. A headless binary install serves no dashboard, so they are unavailable there — tell the user plainly instead of working around them.

### Credential channels

Use the strongest channel the situation allows:

1. **User terminal (strongest):** the user runs the prompt-driven onboarding themselves and it completes setup; you then resume at section 5.
   - Docker: `docker compose exec msget /usr/local/bin/msgetctl onboard --interactive`
   - Binary: `./msget ctl onboard --interactive` in the install directory
2. **Credential file:** the user writes a file with mode `0600` outside source control. You run the step command with stdin from it:

   ```sh
   msgetctl account sign-in --env-file - --json < ./onboarding.env
   ```

3. **Chat, base64-encoded (last resort):** only when neither a user terminal nor a file is possible (the usual situation on a bot computer). Warn the user first: base64 is encoding, not encryption — it hides the password from casual view, but the chat transcript and you can decode it. The user encodes the credential file on their own machine (`base64 < onboarding.env`) and pastes the text. You decode it only inside a pipe, never to disk or output, and never echo it back:

   ```sh
   printf %s '<pasted text>' | base64 -d | msgetctl account sign-in --env-file - --json
   ```

   Collect only the fields the current step needs (account fields first, Apple fields at `apple start`). Never ask for `APPLE_2FA_CODE` in a credential file or blob; the code is a separate, later `code` moment.

An agent with host access can read these secrets in channels 2 and 3. Tell the user, and offer channel 1 when they want stronger isolation.

Credential file fields:

| Field | Use |
| --- | --- |
| `MSGET_ACCOUNT_EMAIL` | MSGET account email |
| `MSGET_ACCOUNT_PASSWORD` | MSGET account password |
| `MSGET_ACCOUNT_NAME` | Optional display name for a new account. Omitted or blank names use `MSGET owner`. |
| `MSGET_EMAIL_CODE` | Email verification or sign-in code |
| `APPLE_ID` | Apple Account |
| `APPLE_PASSWORD` | Apple Account password |
| `APPLE_HARDWARE_PROFILE` | Base64 hardware profile, when `status` asks for it |

## 4. Enable interfaces

1. When the loop reaches the interfaces step, run `interfaces set --enable LIST` with the user's choice. Use `--mcp-policy` to limit MCP permissions.
2. If the output shows `blueBubblesPasswordPending`, treat it as the `acknowledgement` moment in section 3: reveal once with `--reveal-password`, give the password to the user once (never in a report), then acknowledge after they confirm saving it.
3. Expose only what the install form needs: with Docker, publish only the ports of the enabled interfaces in `compose.yaml`; with the binary, interfaces listen on loopback ports on this host — connect clients locally and do not expose them beyond the host without the user's explicit instruction.

## 5. Check completion

1. Run `status`. Make sure `awaiting` is `done`, `setupComplete` is `true`, and each enabled interface is `ready`.
2. Send a harmless status or capability request from the client to the enabled endpoint.
3. Report the stage, the ready interfaces, and the client result. Do not include secrets.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 2 | Usage or input error |
| 3 | Loop continues. Read `awaiting` and `nextActions`. |
| 4 | Rejected: wrong credentials, wrong code, or stale revision |
| 5 | Sign-in required |
| 6 | `wait` timeout |
| 7 | Deployment unavailable or connection ended |
