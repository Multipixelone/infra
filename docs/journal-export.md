# Journal export to Loki

> **INFO — EXCLUDED FROM DEPLOYMENT:** Journal export is configured but must not be activated until the credentials below exist and runtime gates pass.

This is an implementation record, not deployment approval. The Nix wiring and
cheap static checks exist; credentials, connectivity, and runtime behaviour
still need the activation checks below.

## Source declaration and enrollment

`observability.journal.sources.<host>.<service>.units` declares the exact
systemd `.service` units whose journal entries may leave a source host. The
`<service>` key becomes the bounded `service_name` Loki label; it is not a
free-form producer label. For example, the IoT Mosquitto source is:

```nix
observability.journal.sources.iot.mosquitto.units = [ "mosquitto.service" ];
```

The producer owns that service-to-unit mapping. Central policy owns the separate
`observability.journal.clients.<host>` enrollment, credential selection, and
ingress authorization. A client with no nonempty source declaration receives no
Alloy projection and no ingress authorization.

Source assertions require unique exact `.service` units, one logical owner per
unit, an enrolled NixOS/systemd host, and a final enabled NixOS service. Units
created only at package/runtime are unsupported until they can meet that
contract.

## Network and rollout order

- HTTPS writer endpoint: `loki-journal.home.finnrut.is:8443`
- Link ingress destination: `192.168.6.6`
- Expected IoT egress source: `192.168.8.111` (the default `homeAddress`)

Source hosts map the endpoint name to Link's private address while Alloy verifies
the TLS server name. Deploy Link first so the certificate, dedicated listener,
Loki proxy, and `/32` ingress policy are present; deploy IoT only after Link is
ready and the rollout checks pass. IoT routing/effective egress remains a
runtime rollout check, not an assumption made by the registry.

## Required credentials

Create and encrypt these files in the secrets input. Do **not** commit plaintext
or an htpasswd hash to this infrastructure repository, and do not put either in
the Nix store.

1. `${inputs.secrets}/observability/journal-ingress-password.age` contains the
   plaintext push password. It is delivered on IoT as
   `/run/agenix/journal-ingress-password`, then systemd loads it into
   `/run/credentials/alloy.service/journal-push-password`. Recipients must
   include the secret maintainer/user and the IoT host identity as appropriate.
2. `${inputs.secrets}/observability/journal-ingress-htpasswd.age` contains an
   nginx-compatible htpasswd entry for username `journal`, using a hash of the
   same password. It is delivered on Link as
   `/run/agenix/journal-ingress-htpasswd`. Recipients include the
   maintainer/user and Link host identity.
3. `${inputs.secrets}/cloudflare/acme-dns01.age` is an existing credential, not
   a new journal credential. It must remain available on Link as
   `/run/agenix/cloudflare-acme-dns01` for DNS-01 issuance of the ingress
   certificate.

For rotation, deploy both the plaintext-password and htpasswd sides together,
then restart Alloy on each client: `LoadCredential` is read when the service
starts. Do not rotate only one side.

## Activation checks

Before approving deployment, verify all of the following:

- IoT actually egresses from `192.168.8.111` to Link.
- The ingress certificate chain validates for
  `loki-journal.home.finnrut.is` and Alloy's TLS server-name check succeeds.
- Unauthorized authentication, wrong path, wrong method, wrong Host, and query
  requests fail closed.
- Redaction fixtures prove Bearer, generic key/value, and Telegram tokens do
  not reach Loki.
- A positive Loki query returns Mosquitto entries for
  `{host="iot", service_name="mosquitto"}`.

The writer has bounded batching/retry but no validated WAL. It is therefore
best-effort during disconnection or restart; do not make a durability claim
until WAL support is validated for the pinned Alloy version.
