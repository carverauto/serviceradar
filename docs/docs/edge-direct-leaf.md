# Direct OTLP to an edge NATS leaf

The normal OTLP add-on path is the agent-to-gateway relay. It does not need a
NATS credential on the agent. Use this procedure only when an operator has
deliberately selected `output.backend = "jetstream"` for an add-on assigned to
an active, connected EdgeSite with a registered leaf URL.

Direct access uses a short-lived certificate issued through the authenticated
agent gateway. The certificate and private key are encrypted in CNPG and are
materialized only in the running add-on. The base agent bundle never contains
these values or a NATS `.creds` file.

## Lifecycle

1. Select the EdgeSite in the add-on assignment and save the direct JetStream
   configuration. The assignment remains `pending`.
2. Issue the assignment identity:

   ```text
   mix serviceradar.edge.direct_leaf issue --assignment-id <assignment-uuid>
   ```

   The command prints status and generation metadata only; it never prints
   certificate or key material.

3. Download a fresh bundle from the EdgeSite admin page. The generated
   `nats-leaf.conf` contains the assignment certificate identity and its exact
   OTEL publish, stream-management, and request/ack subject permissions. The
   bundle does not contain the add-on certificate or key.
4. Install the bundle on the leaf and let `setup.sh` validate and restart the
   `nats-server` service. Verify the service is healthy before continuing.
5. Mark the exact issued generation ready:

   ```text
   mix serviceradar.edge.direct_leaf mark-ready \
     --assignment-id <assignment-uuid> --generation <generation>
   ```

   Only a matching `pending` generation with all encrypted identity fields can
   transition to `ready`. The next agent configuration poll can then receive
   the add-on-scoped mTLS material.

## Rotation and revocation

Issuing again advances the generation, revokes the predecessor through the
gateway, and returns the new assignment to `pending`. Regenerate and reinstall
the leaf bundle before marking the new generation ready.

To disable direct access, switch the assignment back to gateway relay or run:

```text
mix serviceradar.edge.direct_leaf revoke --assignment-id <assignment-uuid> --reason "direct output disabled"
```

After revocation, regenerate and reinstall the EdgeSite bundle so the old
certificate-CN authorization is removed from the leaf as well.

The leaf's upstream account credentials remain a leaf-to-platform concern;
they are not delivered to the base agent or to the OTLP add-on.
