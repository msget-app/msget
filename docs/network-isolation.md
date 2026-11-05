# Network isolation: Standard and Docker Strong

> Operator copy mirrored from the MSGET release source. The [Docker Hub guide](https://hub.docker.com/r/msget/msget-app) is the installation source of truth.

The shipped Compose example is the **Standard** setup: core and broker sit
on separate container networks, and the core is built to reach MSGET's
hosted services only through the broker. Standard does not stop a
compromised or modified core from opening its own connections — its
network has ordinary outbound access, which it needs for Apple.

**Strong** adds host firewall rules so that, at the network layer:

- the core cannot open connections to MSGET's auth or relay services at
  all, and
- the broker can open connections only to those services (TCP 443).

Strong exists only for **Docker Engine on Linux using the iptables
backend**. There is no Podman Strong variant (Podman/netavark has no
`DOCKER-USER` equivalent here), and a Docker daemon configured for the
nftables backend is not covered by these instructions. On Podman or
nftables Docker, use Standard.

## Inspect the running topology

Run these checks from the host after `docker compose up -d`. They show
the image digest, process user, mounts, and networks the runtime created:

```sh
docker compose ps
for service in msget msget-broker; do
  echo "$service"
  docker inspect \
    --format 'image={{.Image}} user={{.Config.User}} networks={{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}} mounts={{range .Mounts}}{{.Name}}:{{.Destination}} {{end}}' \
    "$(docker compose ps -q "$service")"
done
```

The core must run the exact core image digest and the broker the exact
broker image digest from the same release version. The core must mount the
state volume at `/state`; the broker must have no state-volume mount at
any destination and only the IPC volume at `/run/msget-ipc`. The broker
must not share a network with the core.

Also check that a process in the broker's network namespace cannot reach
the core listeners. This uses a temporary BusyBox container only as a
network probe; `--rm` removes it:

```sh
CORE_IP=$(docker inspect \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
  "$(docker compose ps -q msget)")
BROKER_GATEWAY=$(docker inspect \
  --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' \
  "$(docker compose ps -q msget-broker)")
for port in 8739 8741 8742 1234; do
  docker run --rm \
    --network "container:$(docker compose ps -q msget-broker)" \
    busybox:1.36.1 sh -c 'nc -w 2 "$1" "$2" </dev/null' sh "$CORE_IP" "$port" \
    && echo "UNEXPECTED: broker namespace reached core port $port"
done
docker run --rm \
  --network "container:$(docker compose ps -q msget-broker)" \
  busybox:1.36.1 sh -c 'nc -w 2 "$1" 8739 </dev/null' sh "$BROKER_GATEWAY" \
  && echo "UNEXPECTED: broker namespace reached the host-published dashboard"
```

Every probe should time out or be refused. If one connects, the runtime
is routing between the separate networks or through the host-published
port; do not treat that deployment as network-isolated until the host
network configuration blocks it. For Podman, use the same checks with
`podman compose`, `podman inspect`, and `podman run`. When
podman-compose places the broker in a pod, replace
`--network "container:<broker-id>"` with
`--pod "$(podman inspect -f '{{.Pod}}' <broker-id>)"` so the probe joins
the broker pod's network namespace. Rootless Podman also needs both
networks created with `isolate=strict`; verify enforcement with these
probes because some older Podman/Netavark releases accept the option
without blocking cross-network traffic.

Docker Desktop forwards traffic to a host-published container port from
other container networks. On Docker Desktop the `CORE_IP` probe for the
published dashboard port can connect even when every other probe fails.
That deployment is not network-isolated. The release smoke records this
reachability as `published_port_isolation` in `runtime-smoke.json`; on a
host that blocks it the value is `blocked`, and on Docker Desktop it is
`reached-by-host-publishing`.

## 1. Fixed bridge names

Firewall rules match bridge interfaces, so the two networks need stable
interface names. Create them once, outside Compose:

```sh
docker network create --opt com.docker.network.bridge.name=br-msget-core msget-core
docker network create --opt com.docker.network.bridge.name=br-msget-broker msget-broker
```

In `compose.yaml`, mark both networks external (the services are unchanged
from the shipped example):

```yaml
networks:
  msget-core:
    external: true
  msget-broker:
    external: true
```

Fixed bridge names belong only to this Docker Strong variant. Never put
them in a Podman configuration.

## 2. Firewall rules (DOCKER-USER)

Build the destination sets from the services' current DNS answers. The
production hostnames are fixed in the build (`auth.msget.app`,
`relay.msget.app`):

```sh
set -eu
MSGET_DNS_OK=0
AUTH_A_RESPONSE=$(dig +noall +comments +answer A auth.msget.app)
RELAY_A_RESPONSE=$(dig +noall +comments +answer A relay.msget.app)
AUTH_AAAA_RESPONSE=$(dig +noall +comments +answer AAAA auth.msget.app)
RELAY_AAAA_RESPONSE=$(dig +noall +comments +answer AAAA relay.msget.app)
for response in "$AUTH_A_RESPONSE" "$RELAY_A_RESPONSE" \
  "$AUTH_AAAA_RESPONSE" "$RELAY_AAAA_RESPONSE"; do
  printf '%s\n' "$response" | grep -q 'status: NOERROR'
done
AUTH_A=$(printf '%s\n' "$AUTH_A_RESPONSE" | awk '$4 == "A" { print $5 }')
RELAY_A=$(printf '%s\n' "$RELAY_A_RESPONSE" | awk '$4 == "A" { print $5 }')
AUTH_AAAA=$(printf '%s\n' "$AUTH_AAAA_RESPONSE" | awk '$4 == "AAAA" { print $5 }')
RELAY_AAAA=$(printf '%s\n' "$RELAY_AAAA_RESPONSE" | awk '$4 == "AAAA" { print $5 }')
MSGET_IPS=$(
  printf '%s\n' "$AUTH_A" "$RELAY_A" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u
)
MSGET_IPV6S=$(
  printf '%s\n' "$AUTH_AAAA" "$RELAY_AAAA" \
    | grep -E '^[0-9A-Fa-f:]*:[0-9A-Fa-f:]+$' | sort -u || true
)
test -n "$MSGET_IPS"
MSGET_DNS_OK=1
printf '%s\n' "$MSGET_IPS" "$MSGET_IPV6S"
```

Keep using the same root shell for the installation blocks. If any lookup
fails or returns no A address, `set -e` stops before `MSGET_DNS_OK` is set
and the existing firewall chains remain unchanged. Successful AAAA
lookups with no addresses are legitimate and leave `MSGET_IPV6S` empty.

Install dedicated chains and insert jumps to them at the **start** of
`DOCKER-USER`. Inserting, rather than appending, keeps the rules effective
on Docker hosts whose existing `DOCKER-USER` chain ends in an
unconditional `RETURN`. Run these commands as root after creating the
fixed-name networks:

```sh
set -eu
test "${MSGET_DNS_OK:-0}" = 1
iptables -N MSGET-BROKER 2>/dev/null || true
iptables -N MSGET-CORE 2>/dev/null || true
iptables -F MSGET-BROKER
iptables -F MSGET-CORE
iptables -C DOCKER-USER -i br-msget-broker -j MSGET-BROKER 2>/dev/null \
  || iptables -I DOCKER-USER 1 -i br-msget-broker -j MSGET-BROKER
iptables -C DOCKER-USER -i br-msget-core -j MSGET-CORE 2>/dev/null \
  || iptables -I DOCKER-USER 1 -i br-msget-core -j MSGET-CORE

# Broker may reach only the auth/relay addresses on 443; drop its other egress.
for ip in $MSGET_IPS; do
  iptables -A MSGET-BROKER -d "$ip" -p tcp --dport 443 -j RETURN
done
iptables -A MSGET-BROKER -j DROP

# Core may not reach the auth/relay addresses at all. Its Apple traffic
# falls through this chain and is unaffected.
for ip in $MSGET_IPS; do
  iptables -A MSGET-CORE -d "$ip" -j DROP
done
```

If IPv6 is enabled on either container network, install the same
dedicated-chain structure with `ip6tables`, using every current AAAA
address:

```sh
set -eu
test "${MSGET_DNS_OK:-0}" = 1
ip6tables -N MSGET-BROKER 2>/dev/null || true
ip6tables -N MSGET-CORE 2>/dev/null || true
ip6tables -F MSGET-BROKER
ip6tables -F MSGET-CORE
ip6tables -C DOCKER-USER -i br-msget-broker -j MSGET-BROKER 2>/dev/null \
  || ip6tables -I DOCKER-USER 1 -i br-msget-broker -j MSGET-BROKER
ip6tables -C DOCKER-USER -i br-msget-core -j MSGET-CORE 2>/dev/null \
  || ip6tables -I DOCKER-USER 1 -i br-msget-core -j MSGET-CORE

for ip in $MSGET_IPV6S; do
  ip6tables -A MSGET-BROKER -d "$ip" -p tcp --dport 443 -j RETURN
done
ip6tables -A MSGET-BROKER -j DROP

for ip in $MSGET_IPV6S; do
  ip6tables -A MSGET-CORE -d "$ip" -j DROP
done
```

Notes:

- Do not enable IPv6 on the two networks unless you apply the `ip6tables`
  mirror above. If the AAAA lookups return nothing today, that can change;
  keep the broker IPv6 drop rule and re-check when refreshing (below).
- These rules govern forwarded container traffic. Docker's embedded DNS
  (127.0.0.11) is host-local and is not forwarded traffic, so name
  resolution keeps working on both networks; what is blocked is
  connecting to the resolved MSGET addresses from the core, and any
  broker egress beyond them.
- Return traffic for allowed connections is handled by Docker's own
  forwarding rules after the dedicated chain returns.

## 3. Refresh after reboot and DNS changes

iptables rules are not persistent across reboot unless your distribution
saves them, and the destination addresses are a snapshot of today's DNS.
After every reboot, and whenever the A/AAAA answers change, re-resolve
both hostnames and re-run the applicable installation block above. It is
idempotent: it flushes and refills the dedicated chains and adds each
`DOCKER-USER` jump only if it is missing.

Stale rules fail in the safe direction for the broker (it loses contact
and sign-in/activation report unavailable), but a newly published MSGET
address would not be blocked for the core until you refresh. Treat the
refresh as part of host maintenance.

## 4. Verify

```sh
docker compose exec msget /usr/local/bin/msgetctl privacy check
```

This runs in the core's network namespace, attempts no-data TCP connects
to the fixed auth and relay hostnames on 443 plus an Apple control host,
and prints the broker's contact counters. Under Strong you expect the two
MSGET probes to fail, the Apple control to pass, and the counters to
explain any hosted-service contact. The check reports `pass`, `fail`, or
`unknown` per probe; it is evidence about reachability, not a Standard or
Strong certification.

## Limits

Strong closes the direct core→MSGET-services path and confines the
broker's egress. It does not make a compromised core harmless: the core
legitimately talks to Apple, and a malicious core could encode data into
traffic, timing, or DNS lookups on paths it is allowed to use (covert
channels). Strong also says nothing about the broker process itself,
which is why the broker is kept small, stateless, and without state
access. For what the broker is allowed to send, see the broker data
inventory in the [privacy model](https://msget.app/how-it-works/#privacy-model);
to watch it yourself, see [traffic-capture.md](traffic-capture.md).
