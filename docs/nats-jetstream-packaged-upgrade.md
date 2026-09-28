# NATS JetStream sizes on upgraded packaged installs

This applies to deb/rpm installs of `serviceradar-nats` that were installed
before JetStream sizing profiles and are now being upgraded. Fresh installs
already have the change below and need nothing.

## What changed

The `serviceradar-nats` package now ships `/etc/serviceradar/jetstream-sizes.env`
with the `small` sizing profile. `serviceradar-nats.service` loads it with
`EnvironmentFile=`, and so do the datasvc, log-collector, flow-collector,
bmp-collector, core-elx and web-ng units. It sets every JetStream stream size
and `SERVICERADAR_NATS_MAX_FILE_STORE` (`30G` for `small`).

A fresh install's `/etc/nats/nats-server.conf` reads the NATS file-store
ceiling from that variable:

```
  max_file_store: $SERVICERADAR_NATS_MAX_FILE_STORE
```

## Why an upgrade needs one manual edit

`/etc/nats/nats-server.conf` is a package conffile, and the postinstall step
writes this deployment's partition ID into it. The package manager therefore
treats it as locally modified and keeps your copy on upgrade (dpkg leaves the
new version as `nats-server.conf.dpkg-dist`, rpm as `nats-server.conf.rpmnew`).
Your copy still has the old ceiling:

```
  max_file_store: 10G
```

With the new stream sizes (about 22.25 GiB for `small`), a 10G ceiling cannot
place every stream. Replace that one line.

## Procedure

1. Confirm the sizes file is installed:

   ```
   grep '^SERVICERADAR_NATS_MAX_FILE_STORE=' /etc/serviceradar/jetstream-sizes.env
   ```

2. In the `jetstream { ... }` block of `/etc/nats/nats-server.conf`, change the
   `max_file_store` line to exactly:

   ```
     max_file_store: $SERVICERADAR_NATS_MAX_FILE_STORE
   ```

   Leave the rest of the file, including the rendered partition ID, as it is.

3. Check the configuration with the variables loaded, the way the unit loads
   them:

   ```
   sudo env $(grep -v '^#' /etc/serviceradar/jetstream-sizes.env | xargs) \
     /usr/bin/nats-server -t -c /etc/nats/nats-server.conf
   ```

   An error such as `variable reference for 'SERVICERADAR_NATS_MAX_FILE_STORE'
   ... can not be found` means the sizes file is missing or the variable is
   misspelled.

4. Restart NATS, then the services that size streams:

   ```
   sudo systemctl restart serviceradar-nats
   sudo systemctl restart serviceradar-datasvc serviceradar-core-elx serviceradar-web-ng
   ```

   Also restart `serviceradar-log-collector`, `serviceradar-flow-collector` and
   `serviceradar-bmp-collector` where they are installed.

The host needs at least `max_file_store` of free disk under `/var/lib/nats`:
the value is a reservation ceiling, not an allocation.

To move to the `medium` (100G) or `large` (500G) profile, replace the values in
`/etc/serviceradar/jetstream-sizes.env` with those of
`docker/compose/profiles/medium.env` or `large.env` from the ServiceRadar
release, and restart as in step 4.
