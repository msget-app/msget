# Capturing the broker's traffic

> Operator copy mirrored from the MSGET release source. The [Docker Hub guide](https://hub.docker.com/r/msget/msget-app) is the installation source of truth.

The broker is the only component that talks to MSGET's hosted services,
and you can inspect that traffic yourself. The broker trusts the system
roots plus one optional extra root CA of yours:

- Environment: `MSGET_BROKER_EXTRA_ROOT_CA_FILE=/path/in/container/ca.pem`
  on the `msget-broker` service, or
- Flag: `command: ["broker", "--extra-root-ca", "/path/in/container/ca.pem"]`

The PEM roots in that file are **added** to the native roots for the
broker's auth and relay connections. The variable does nothing on the
core service; the core makes no hosted-service connections to capture.

> **Captures contain credentials.** Broker traffic includes your MSGET
> password, email codes, session bearers, and relay material (see the
> broker data inventory in the [privacy model](https://msget.app/how-it-works/#privacy-model)). Treat capture files like passwords: keep them
> private, and delete them when you are done. Your Apple ID password and
> codes you type for Apple never reach the broker, so they cannot appear
> in these captures.

## Worked capture: transparent mitmproxy on a Linux Docker host

There is no proxy setting in the broker and its destinations are fixed,
so this example redirects only TCP 443 traffic entering the host from the
broker bridge to a transparent mitmproxy process. It works for both the
auth and relay hostnames without changing DNS answers.

1. In a dedicated terminal, start mitmproxy with a private configuration
   directory and capture file. Leave it running:

   ```sh
   mkdir -p capture-conf
   mitmdump --mode transparent --listen-host 127.0.0.1 --listen-port 18080 \
     --set confdir="$PWD/capture-conf" \
     --save-stream-file "$PWD/broker-capture.mitm" --showhost
   ```

   On first start it creates `capture-conf/mitmproxy-ca-cert.pem`. The
   same directory contains the CA private key; never mount the whole
   directory into the broker.
2. Give the broker only the public CA certificate. Save this as
   `compose.capture.yaml` next to the shipped `compose.yaml`:

   ```yaml
   services:
     msget-broker:
       environment:
         MSGET_BROKER_EXTRA_ROOT_CA_FILE: /capture/ca.pem
       volumes:
         - ./capture-conf/mitmproxy-ca-cert.pem:/capture/ca.pem:ro
   ```

   Recreate only the broker:

   ```sh
   docker compose -f compose.yaml -f compose.capture.yaml up -d msget-broker
   ```
3. Find the broker bridge and redirect its forwarded TCP 443 traffic to
   mitmproxy:

   ```sh
   BROKER_CONTAINER=$(docker compose ps -q msget-broker)
   NETWORK_ID=$(docker inspect \
     -f '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' \
     "$BROKER_CONTAINER")
   BROKER_BRIDGE=$(docker network inspect \
     -f '{{index .Options "com.docker.network.bridge.name"}}' "$NETWORK_ID")
   test -n "$BROKER_BRIDGE" || BROKER_BRIDGE=$(printf 'br-%.12s' "$NETWORK_ID")
   sudo sysctl -w net.ipv4.ip_forward=1 net.ipv4.conf.all.send_redirects=0
   sudo iptables -t nat -C PREROUTING -i "$BROKER_BRIDGE" -p tcp --dport 443 \
     -j REDIRECT --to-ports 18080 2>/dev/null \
     || sudo iptables -t nat -A PREROUTING -i "$BROKER_BRIDGE" -p tcp \
          --dport 443 -j REDIRECT --to-ports 18080
   ```
4. Sign in or activate from the dashboard and watch the flows in the
   mitmdump terminal. Compare them with the broker counters from
   `msgetctl privacy check` or the dashboard owner view: every
   hosted-service contact should appear in both. To inspect the saved
   capture later, run `mitmproxy -r broker-capture.mitm`.
5. When finished, remove the redirect and the extra trust, then delete
   the private capture material:

   ```sh
   sudo iptables -t nat -D PREROUTING -i "$BROKER_BRIDGE" -p tcp \
     --dport 443 -j REDIRECT --to-ports 18080
   docker compose -f compose.yaml up -d msget-broker
   rm -rf compose.capture.yaml capture-conf broker-capture.mitm
   ```

   Stop mitmdump with Ctrl-C. Leaving the rule or override in place leaves
   your local CA in the broker's trust path.

This worked form uses Linux iptables. The extra-root-CA setting itself is
runtime-neutral; on Podman or nftables Docker, use an equivalent local
transparent redirect into a TLS-intercepting proxy you control.

## Reading what you captured

- **Auth traffic** is HTTPS JSON. The field lists per operation are in
  the broker data inventory in the [privacy model](https://msget.app/how-it-works/#privacy-model).
  Better Auth-owned error bodies are upstream-defined; the broker maps
  those responses by HTTP status and does not forward their bodies.
- **Relay traffic** is `POST /api/v3/rpc` with content type
  `application/vnd.msget.relay.v3+protobuf`: a serialized Protobuf
  envelope with a documented public XOR mask applied. The privacy model
  inventories the envelope and operation fields you should expect to see.
- Many relay fields (`spim`, `adi_state`, `session_state`, headers blobs,
  encrypted `*_enc` hardware values) are **opaque byte strings** produced
  by the local provisioning/ADI stack. Capture shows their presence,
  sizes, and timing; the inventory names them but does not decode
  their semantics, and neither can this guide. What capture does prove is
  the boundary: destinations, operations, field inventory, and counts —
  and that nothing outside the 29 inventoried operations is sent.
