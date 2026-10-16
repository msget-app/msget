---
name: msget
description: Deploy and onboard MSGET, a self-hosted iMessage/Telegram bridge, with the two-service Docker Compose or rootless Podman topology on an ordinary Linux host. Use when setting up MSGET, resuming unfinished onboarding, or driving account sign-in and the Apple activation challenge through msgetctl status and nextActions.
---

# MSGET onboarding for agents

Onboarding is guided, not autonomous. Several steps need the user in the loop — above all the Apple verification challenge: its code exists only after the challenge starts, and only the user can read it. You drive a loop: run the agent steps yourself, stop and ask the user at human steps. The service stores all progress server-side, so the loop can stop and resume at any point, including in a later session.

MSGET ships only as a container image. The deployment is two services from that image: `msget` (core) owns state and talks to Apple; `msget-broker` is stateless and makes the fixed MSGET account/relay calls. `msgetctl` in this guide means:

- Docker: `docker compose exec -T msget /usr/local/bin/msgetctl`
- Podman: `podman compose -f compose.yaml -f compose.podman.yaml exec -T msget /usr/local/bin/msgetctl`

**Ask** in this guide means: prompt the user with your harness's structured question tool (`ask`) when it has one — one question, with the real options when the step offers a choice. On a bare chat surface with no such tool, ask directly in conversation, one question at a time, and wait for the reply. Either way, you run every `msgetctl` command yourself with the answers; handing the user a command to run is the opt-in exception in section 3, never the default.

## Rules

- Follow `awaiting` and `nextActions` from `status --json`. Do not invent steps.
- Keep secrets out of command arguments except for the explicitly chosen dangerous Apple option in section 3.
- Use the credential routes in section 3. Never repeat codes, passwords, or tokens in reports.
- Do not retry a rejected code automatically. Ask the user for a new code.
- Do not reset ownership to bypass sign-in.
- Do not send a live message as a setup test.
- Use `msgetctl wait` for asynchronous steps. Do not write sleep loops.
- Keep only one active MSGET service for each Apple ID. Do not run a copied installation or copied state while the original service is active.

## 1. Start or resume

First check the supported-host gate. MSGET needs an ordinary Linux host with Docker Engine + Compose or rootless Podman, system DNS returning real answers, and outbound TCP 80 to Apple, TCP 5223 to Apple, and TCP 443 to Apple/MSGET services. Agent/bot VMs and other mediated-egress environments — fake-IP DNS, 443-only transparent proxies, allowlist proxies, hibernating/ephemeral hosts — are unsupported. If the host matches one, stop and tell the user plainly; do not add DoH, IP pinning, or proxy workarounds.

If a deployment is already running, resume it from its `compose.yaml`: identify whether Docker or Podman owns the `msget` and `msget-broker` containers, start both services if needed, and try `status`. If `status` answers, skip installation and go to section 2.

Otherwise choose the runtime. Detect `docker` and `podman`; if both are usable and the user has not already chosen, ask which one to use. Then follow that runtime's steps.

### Docker Compose

1. Create the two-service `compose.yaml` from the Docker Hub overview (`docker.io/msget/msget-app`), including both `msget` and `msget-broker`, the `msget-state` and `msget-ipc` volumes, and separate core/broker networks. Keep existing state volumes.
2. Run `docker compose up -d`.
3. Completion: both services are running and `msgetctl status --json` answers.

### Rootless Podman

1. Confirm the runtime user has subuid and subgid ranges of at least 65536 IDs each. Keep the shipped container `user:` and `group_add:` values exactly.
2. Create the same `compose.yaml`, plus this Podman-only `compose.podman.yaml`. Separate network names alone do not guarantee isolation on rootless Podman:

   ```yaml
   networks:
     msget-core:
       driver_opts:
         isolate: "strict"
     msget-broker:
       driver_opts:
         isolate: "strict"
   ```
3. Prefer the named volumes. With bind mounts, use Podman's `:U` ownership handling or a compatible `keep-id` mapping so `65532:65532` can write `/state` and `65533:65534` can write `/run/msget-ipc`.
4. Run `podman compose -f compose.yaml -f compose.podman.yaml up -d`.
5. Verify isolation before onboarding: inspect both containers from the host (same image, expected users, broker has only `/run/msget-ipc`, no shared network), then run the broker-namespace probes from `apps/deployment/docs/network-isolation.md` in `msget-app/msget-app`. If podman-compose placed the broker in a pod, join that pod for the probe. Completion: every core-listener probe is refused or times out and `msgetctl status --json` answers. If a probe connects, stop and report that this Podman/Netavark release is not enforcing isolation; do not proceed as a Standard deployment.
6. For autostart when the user asks: enable `loginctl enable-linger "$USER"` and run the project from a user systemd service, translate both services to Quadlet units, or use rootful Podman under systemd. Report the chosen method and how to stop it.

> **Warning — copied state is the same service identity:** A copy of the state volume on another machine has the same saved Apple and device state. The state lock cannot detect that copy. Do not run the original and the copy at the same time. Concurrent use can disrupt the iMessage registration. To move an installation, stop the old stack first, then start the copied state. Services that run at the same time need separate state and different Apple IDs.

Run `msgetctl status --json`. If you are resuming earlier onboarding, starting both services plus this status is the whole restart: `status` reports where it stopped.

## 2. Run the loop

Repeat until `awaiting` is `done`:

| `awaiting` | You do |
| --- | --- |
| `agent` | Run the `agent` entries in `nextActions` yourself. |
| `human` | Stop. Ask the user (section 3), submit their input with the given command. |
| `operation` | Run `msgetctl wait --operation ID`. |

Each `nextActions` entry has `command`, `description`, `actor` (`agent` or `human`), and `needs` (`none`, `identifier`, `credentials`, `choice`, `code`, or `acknowledgement`). Account-entry actions also have `account` (`existing_account`, `new_account`, or `just_created_account`). Run `status` again after every step. Exit code 3 means the loop continues; other codes are in the exit-code table.

For Apple recovery after setup, the same loop applies with the `apple recovery` commands.

### Account gate

When `stage` is `sign_in_required`, resolve the user's account situation before asking for an email, password, code, or sign-in method. Unless the user's request already chooses one branch unambiguously, ask: **“Which describes your MSGET account in this deployment's environment?”**

- **I already have an account** (`existing_account`) — use email OTP: ask for the account email in plaintext, run `account send-sign-in-code`, ask for the emailed code, then run `account sign-in-code`. If the user already has a current code, do not request another one. `account send-sign-in-code` belongs only inside this branch and never creates an account.
- **I need to create a new account** (`new_account`) — use email OTP: ask for the new account email in plaintext, run `account send-sign-up-code`, ask for the emailed code, then run `account sign-up-with-code`. Ask for a display name in plaintext only if the user wants to set one; otherwise omit `MSGET_ACCOUNT_NAME`.
- **I just created a password account and have its email verification code** (`just_created_account`) — run `account verify-email`.

Keep the branching visible in the prompt: emailed-code sign-in and emailed-code account creation are not interchangeable choices. The first signs in to an **existing** account; the second creates a **new** account. In agent-guided onboarding, do not ask for an MSGET account password. The password commands are fallbacks for a user who explicitly chooses them or cannot use email OTP; Apple activation still needs the Apple Account password later.

## 3. Human moments

| `needs` | Ask the user for | Submit with |
| --- | --- | --- |
| `identifier` | A non-secret identifier, in plaintext | `--apple-id EMAIL` for Apple identity, or `--env-file -` for MSGET identifiers |
| `credentials` | For Apple, ask for the Apple ID first, then a password file path. Use the separate MSGET fallback when chosen. | the credential route below, after all required fields are available |
| `code` | The code Apple or the account email just sent them | `--code-stdin` (below) |
| `choice` | A decision: `sms` or `trusted_device`; one of the redacted numbers in `operation.smsOptions`; or which interfaces to enable | the given command with the chosen option |
| `acknowledgement` | Confirmation that they saved the revealed BlueBubbles password | `interfaces acknowledge-password`, only after they confirm |

Submit a code like this (codes are short-lived; ask only when the stage asks):

```sh
printf '%s\n' "$CODE" | msgetctl apple verify --operation "$OP" --code-stdin --json
```

If `operation.failureCode` is `apple_code_rejected`, Apple did not accept the code. Ask the user for the code again, or run `apple resend` for a new code.

For either MSGET email-code request, a successful response is deliberately generic: it does not prove an email was sent. Sign-in codes are sent only to an **existing** account; account-creation codes are sent only when the email can create a **new** account in this deployment's environment. If no code arrives, confirm the selected branch and environment before resending; repeated requests can be rate-limited.

**Before `apple start`, confirm the user is present now**, with their trusted device or phone reachable, and able to reply promptly. Keep both services running until the challenge completes. Restarting the core interrupts the operation (stage `interrupted`), and Apple activation must start over; progress before `apple start` is preserved.

**Dashboard-only steps** appear as a `dashboard` action with `actor: human`, `needs: none`: Telegram sign-in and adding activation quota. The user does these in the web dashboard and you resume the loop.

### How credentials reach you

**Default — agent-guided.** You ask, the user answers, you run the command:

- **Identifiers, choices, and codes:** ask for one field at a time in plaintext. Email addresses and display names are identifiers, not secrets. Ask for the Apple ID separately and supply it with `--apple-id EMAIL`. For MSGET account entry, request the branch's emailed code after collecting the email. Then collect and submit that code. Add the MSGET field name when constructing stdin:

  ```sh
  printf 'MSGET_ACCOUNT_EMAIL=%s\n' '<email>' | msgetctl account send-sign-in-code --env-file - --json
  printf 'MSGET_ACCOUNT_EMAIL=%s\n' '<email>' | msgetctl account send-sign-up-code --env-file - --json
  ```

  Submit the code with the email address in the same stdin input:

  ```sh
  printf 'MSGET_ACCOUNT_EMAIL=%s\nMSGET_EMAIL_CODE=%s\n' '<email>' '<code>' | msgetctl account sign-in-code --env-file - --json
  printf 'MSGET_ACCOUNT_EMAIL=%s\nMSGET_EMAIL_CODE=%s\n' '<email>' '<code>' | msgetctl account sign-up-with-code --env-file - --json
  ```

  For a new account, add `MSGET_ACCOUNT_NAME=<name>` to the same input if the user wants a display name.
  Do not combine `--env-file -` with `--code-stdin`. The CLI rejects that combination.
  Use `--code-stdin` only when the command needs no other stdin input, as in `apple verify`. Never repeat codes in reports.
- **Apple passwords:** use the private-file choices below after the separate Apple ID prompt.
- **Apple challenge data:** collect `APPLE_2FA_CODE` only after the challenge starts. Keep `APPLE_HARDWARE_PROFILE` in its existing sensitive base64 form. Submit hardware through the generic `--env-file -` route when required. Do not decode it, repeat it, or write it to disk.

### Apple password choices

Ask: **“How would you like to provide your Apple Account password?”**
Present these choices in order. Use `ask` when available. Otherwise, ask directly in chat.
Omit the upload choice only when the interface cannot receive attachments.

| Choice | What to request next |
| --- | --- |
| **Provide a private file path — default** | An absolute path outside source control, accessible to the CLI, with mode `0600`. |
| **Upload credential file** | An opaque file attachment. Request the upload, not a path on the user's separate computer. |
| **DANGEROUS — paste plaintext password** | The literal password alone, after explicit consent to the exposure described below. Never preselect or recommend this choice. |

Warn before requesting either file:

> **Warning:** Base64 is encoding, not encryption. Anyone who can read the file can recover your password.
> An agent with host access can read a local file. Upload providers may retain attachments.
> Some platforms expand attachments into chat, which exposes their contents to the agent and transcript.

Disclose automatic attachment expansion before requesting an upload if the platform does this.
Do not offer pasted base64 as a normal choice.

For either file choice, ask the user to supply exactly one of these records:

```text
APPLE_PASSWORD=BASE64_OF_PASSWORD_ONLY
```

```text
UNSAFE_APPLE_PASSWORD=LITERAL_PASSWORD
```

The first record contains standard base64 of the password's exact characters, without the field prefix.
The CLI decodes it once to UTF-8. Base64 does not protect the file from readers.
The second record explicitly selects plaintext file input and causes a sanitized stderr warning.
The dedicated parser preserves whitespace, equals signs, quotes, and shell metacharacters literally.
It does not evaluate shell syntax or remove quotes. A final newline or CRLF ends the record.
The file must be a real private regular file, at most 1 MiB, with no group or other permissions.
The CLI rejects empty passwords, invalid base64 or UTF-8, multiple records, duplicate fields, both fields, and unknown fields.
It never falls back to another format.

For a file:

1. Check the path and permissions without inspecting, displaying, or decoding its contents.
2. Keep any local upload copy outside source control with mode `0600`.
3. For Docker, transfer the opaque file to a private path inside the container.
4. Pass only that path to `--apple-password-file`. Never embed file contents in a command.

Do not manufacture credential files from pasted passwords.
Do not source the file or supply it to generic `--env-file`.
Use the path as the CLI sees it:

```sh
msgetctl apple start --apple-id 'owner@example.com' --apple-password-file /private/apple-password --json
```

For Docker, `msgetctl` expands to the container command in this skill's introduction.
The host path alone is insufficient unless the file is also accessible at the specified container path.
The CLI rejects `--apple-password-file -`. Password files do not use stdin.
If the deployment needs hardware input, add `--env-file -` for `APPLE_HARDWARE_PROFILE`, not for the Apple ID or password.

For the dangerous chat choice, display this warning before requesting the value:

> **DANGER — plaintext password:** Your password will appear in this chat and as a literal CLI process argument.
> Chat history, tool-call transcripts, shell history, and provider logs may retain it. Process inspection may reveal it.
> Send it only if you accept this exposure.

Use the supplied password unchanged as the value of `--plaintext-password-DANGEROUSLY`.
Shell-quote it correctly as one argument. This example contains a placeholder, not a real password:

```sh
msgetctl apple start --apple-id 'owner@example.com' --plaintext-password-DANGEROUSLY '<literal-password>' --json
```

The option requires a nonempty value and preserves whitespace. It cannot accompany `--apple-password-file`.
The CLI emits a sanitized stderr warning and does not echo the value in output or errors.
This does not hide the value from process arguments or transcripts. Never repeat it in reports.

Both password options apply only to `apple start` and `apple recovery start`.
For recovery, replace `apple start` with `apple recovery start` in either example.
Use `apple recovery verify-identity --apple-id EMAIL` when recovery needs only the identifier.
These flags are not global options and are not accepted by `onboard`.
With no new credentials, `apple start` can resume saved Apple state. `apple recovery start` always requires new credentials.
Supplying only the Apple ID or only a password source fails.

### MSGET password fallback

Keep email OTP as the default account flow.
If the user explicitly chooses a password fallback, use the existing private `--env-file`, stdin, or interactive route.
`MSGET_ACCOUNT_PASSWORD` remains a literal generic env value, not a base64 Apple password record.
The generic env parser permits an `export ` prefix and removes one pair of outer quotes.
It does not evaluate shell syntax. Preserve the password's exact characters through those rules.
The Apple password flags do not apply to MSGET account commands.

### Opt-in user terminal

Use this route only when the user asks for terminal isolation or declines agent-guided credential handling.
The user runs onboarding locally. Resume at section 5 when the user finishes.

- Docker: `docker compose exec msget /usr/local/bin/msgetctl onboard --interactive`
- Podman: `podman compose -f compose.yaml -f compose.podman.yaml exec msget /usr/local/bin/msgetctl onboard --interactive`

Apple onboarding prompts for the Apple ID and a password **file path**, not a plaintext Apple password.
Individual Apple steps with `--interactive` also request a file path when credentials are needed.
MSGET account password prompts retain hidden input. Do not pass the Apple step flags to `onboard`.

Input fields:

| Field or option | Handling | Use |
| --- | --- | --- |
| `MSGET_ACCOUNT_EMAIL` | plaintext generic env input | MSGET account email |
| `MSGET_ACCOUNT_PASSWORD` | private generic env input or hidden prompt, fallback only | MSGET account password |
| `MSGET_ACCOUNT_NAME` | plaintext generic env input | Optional display name. Omitted or blank names use `MSGET owner`. |
| `MSGET_EMAIL_CODE` | code | MSGET sign-in, account-creation, or email-verification code |
| `--apple-id EMAIL` | plaintext argument or local prompt | Apple Account identifier |
| `--apple-password-file PATH` | private path argument or local prompt | Dedicated file with one encoded or explicitly unsafe password record |
| `--plaintext-password-DANGEROUSLY VALUE` | explicitly chosen literal password argument | Apple start or recovery start only |
| `APPLE_HARDWARE_PROFILE` | sensitive base64, generic env input | Hardware profile, when `status` asks for it |
| `APPLE_2FA_CODE` | code | Apple challenge response after the challenge starts |

Generic `--env-file` input rejects `APPLE_ID`, `APPLE_PASSWORD`, and `UNSAFE_APPLE_PASSWORD` with migration guidance.
Use the Apple options above instead. Other generic env fields retain their existing behavior.

## 4. Enable interfaces

1. When the loop reaches the interfaces step, run `interfaces set --enable LIST` with the user's choice. Use `--mcp-policy` to limit MCP permissions.
2. If the output shows `blueBubblesPasswordPending`, treat it as the `acknowledgement` moment in section 3: reveal once with `--reveal-password`, give the password to the user once (never in a report), then acknowledge after they confirm saving it.
3. Publish only the ports of the enabled interfaces in `compose.yaml`, bound to loopback unless the user explicitly chooses another route. Do not expose interfaces beyond the host without the user's explicit instruction.

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
