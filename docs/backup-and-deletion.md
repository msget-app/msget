# Backup, restore, and deletion of local state

> Operator copy mirrored from the MSGET release source. The [Docker Hub guide](https://hub.docker.com/r/msget/msget-app) is the installation source of truth.

All durable MSGET data on your host lives in the `/state` volume (the
Compose volume `msget-state`). The broker keeps nothing on disk; the
`/run/msget-ipc` volume holds only its live socket. Deleting local state
does not delete your hosted MSGET account, and deleting that account does
not delete local state. Complete both procedures below when you want both
copies gone.

## What is in `/state`

Treat the directory as one atomic unit: back it up whole, restore it
whole, never split or share it between instances.

| Path | Contents |
| --- | --- |
| `product.sqlite3` (+ `-wal`, `-shm`, `-journal` sidecars) | Deployment identity and ownership, owner session records (including the central session bearer), settings, interface configuration and generated secrets, and the Apple operation record (redacted Apple ID, activation ticket) |
| `msget.sqlite3` (+ sidecars) | Saved Apple/device connection state used to resume messaging without a new activation |
| `imessage-history.sqlite3` (+ sidecars) | Local message history: chats, messages, attachment metadata, reactions, send status |
| `attachments/` | Managed attachment files (the only directory MCP file access may read) |
| `voice-audio-cache/` | MP3 copies of received voice notes, served by the BlueBubbles gateway. The gateway rebuilds them on demand. |
| `anisette/` | Device provisioning (ADI/anisette) state files |
| `.msget.lock` | Single-instance lock for the state directory |

Older layouts may also contain legacy identity files (`config.plist`,
`gsa.plist`, `hwconfig.plist`, `id_cache.plist`). If present, they are
part of the same unit.

The state is sensitive: `product.sqlite3` contains a live session bearer,
and the Apple/device state can resume your iMessage registration. Keep
backups encrypted and access-controlled accordingly.

## Backup

1. Stop the stack so the databases are closed cleanly:

   ```sh
   docker compose down
   ```

   (Without `-v`, this keeps the volumes.)
2. Archive the whole state volume with your preferred tooling into a
   private, encrypted location. Copy every file, including the SQLite
   sidecars and the `attachments/` and `anisette/` directories.
3. Start again with `docker compose up -d` and confirm the dashboard
   shows your existing setup.

## Restore / move to another host

1. Stop the old deployment and leave it stopped (see the warning below).
2. On the new host, create the Compose project, then restore the archived
   files into the fresh `msget-state` volume before first start,
   preserving ownership for UID/GID `65532:65532`.
3. Start the stack. The deployment identity, ownership, and saved Apple
   state come with the files; no new activation is needed for an intact,
   compatible state.

> **Warning:** Keep only one active MSGET service for each Apple ID. A
> restored copy has the same saved Apple and device state as the
> original, and the state-directory lock cannot detect a copy running on
> another machine. Do not run the original and the copy at the same time;
> concurrent use can disrupt the iMessage registration. Services that run
> concurrently need separate state and different Apple IDs.

## Delete the hosted MSGET account

The Accounts service provides an authenticated deletion endpoint. Deleting
an account is immediate and cannot be undone.

1. If the account signs in only with Telegram, first add and verify a
   recovery email in the dashboard. The direct deletion call needs a fresh
   email-account bearer.
2. Sign in directly to the Accounts service and keep the returned `token`
   private. For a password account, use
   `POST https://auth.msget.app/api/auth/sign-in/email` with JSON fields
   `email` and `password`. For an email-code account, request a sign-in
   code and complete sign-in with the email OTP endpoints.
3. Within five minutes of that sign-in, send:

   ```text
   POST https://auth.msget.app/api/auth/account-methods/delete
   Authorization: Bearer <token>
   Origin: https://auth.msget.app
   Content-Type: application/json

   {}
   ```

   A successful response is `{"success":true}`. Do not put the password,
   email code, or bearer in a URL or share them in a support message.

This deletes the hosted account profile and credential, all hosted
sessions, linked Telegram identity and account-linked login transactions,
recovery-email record, activation quota, activation attempts and records,
email verification rows for the account email, and audit rows targeted at
the account. It does not delete this deployment's `/state`, backups of
that state, your Apple account, or copies and logs held outside the
Accounts database by infrastructure operators. An unlinked Telegram login
transaction that has not identified an account expires after 10 minutes.

## Delete everything local

Stop the stack and delete both volumes:

```sh
docker compose down -v
```

This removes `msget-state` (all files above) and `msget-ipc` (socket
only). If you used bind mounts instead of the named volumes, delete the
host directories you mounted at `/state` and `/run/msget-ipc` after
stopping the containers. Also delete any backups you made; a surviving
backup is a surviving copy of the session bearer and Apple state.

After a wipe, the next start is a brand-new deployment: new deployment
identity, a fresh setup code, owner claim, and Apple activation.

Resetting deployment ownership is **not** deletion: it changes who owns
the deployment while keeping the state. Use the volume wipe above when
you want the data gone.
