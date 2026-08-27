# Give engine-fired alerts a device identity

## Why

`alerts.device_uid` exists, is a real Ash attribute, is accepted by the
`:trigger` action, has a foreign key to `ocsf_devices(uid)`, and is already
whitelisted by SRQL for filtering. It is simply never populated on the path that
creates most alerts.

`AlertGenerator.from_event/2` builds its attrs from `title`, `description`,
`severity`, `source_type`, `source_id`, `event_id`, `event_time` and `metadata`
— and nothing else. Every alert the stateful engine fires therefore lands with
`device_uid` NULL.

Three things are broken by that, in increasing order of seriousness:

1. **Alerts cannot be correlated with anything.** `in:alerts device_uid:"..."`
   returns nothing, so no dashboard can join alerts to the device or metrics
   they are about.
2. **The alert detail page has a dead link.** Its meta strip builds a `Device`
   fact with a `/devices/{uid}` link and then discards it, because the value is
   always nil.
3. **Out-of-service suppression silently does not apply.** The `:trigger` action
   runs a `before_action` gate that suppresses alerts for a device marked out of
   service, and `:device_out_of_service` is the highest-precedence notification
   suppression reason. Both key on `device_uid`. `DeviceLifecycle.active?(nil,
   _)` returns `true`, so with a NULL column **every engine-fired alert bypasses
   both gates**. Marking a device out of service does not stop it paging.

## What Changes

1. `AlertGenerator.from_event/2` accepts a `:device_uid` option and writes it.
2. The stateful alert engine resolves its record's device to a **canonical** uid
   via `DeviceCorrelation.resolve/1` and passes it.
3. `AlertGenerator.normalize_device_uid/1` becomes public and rejects anything
   that is not a non-empty binary.

### The value must be canonical, and that is the whole design

`alerts.device_uid` has a foreign key to `ocsf_devices(uid)`. A value that is
not a real device uid does **not** produce a mislabelled alert — it fails the
insert and the alert is lost. In this path that is the worst of the three
callers: `create_event_and_alert/4` returns `{:error, reason}`, the state
machine only logs it, and the snapshot never receives an `alert_id`, so the rule
re-fires forever and nobody is paged for any of it.

Trading "an alert with no device" for "no alert" is a bad trade. So the uid is
**never** read off the record directly — a record's `device_uid`/`device_id` is
whatever the producer put there, frequently a hostname, an IP, or a plugin-local
id. It goes through `DeviceCorrelation.resolve/1`, which returns a canonical uid
or nil, and nil is a perfectly acceptable answer.

## Impact

- Affected specs: `observability-signals`
- Affected code: `lib/serviceradar/monitoring/alert_generator.ex`,
  `lib/serviceradar/observability/stateful_alert_engine/alert_lifecycle.ex`
- **No migration.** The column, the FK and the accept-list entry all exist.
- **No SRQL change.** `device_uid` is already on the alerts filter whitelist.

### This changes who gets paged — read before deploying

Populating the column activates two systems that are dormant while it is NULL:

- the create-time out-of-service gate on `:trigger`, and
- `:device_out_of_service`, precedence-1 in notification suppression, which
  withholds every notification for that device from every route and channel.

`alert.device_uid` is also a declared routable match field, so routes and
silences authored against it are inert today and **begin matching on deploy**.

Every one of those is the designed behaviour finally working. But it is still a
change in who gets paged, arriving with no configuration change, so existing
routes and out-of-service markings should be audited first. That is a product
decision, not a technical one.

### Performance

One additional cached lookup per alert creation. `DeviceCorrelation.resolve/1`
is cached per correlation input and fail-open. The `:trigger` gate also gains a
real `Device.get_by_uid` read where it previously short-circuited on nil. Alert
volume is orders of magnitude below event volume, so this is acceptable — but it
is a new query on a path that had none.

### Deliberately out of scope

- **The trivy and log-promotion callers.** Trivy's `event.device.uid` is a
  fallback chain (`device_uid || hostname || host_ip || resource_name`), so
  threading its already-resolved uid means carrying it through the insert path;
  log promotion never resolves its uid at all. Both are FK-unsafe without more
  work than this change should carry.
- **Backfilling existing rows.** They stay NULL; `:update_metadata` accepts only
  `[:metadata, :tags]`, so there is no backfill route short of `:reassign_device`.
- **An index on `device_uid`.** Nothing queries by it yet. Add
  `(device_uid, triggered_at DESC)` when a device-scoped query actually ships.
- **`stats:` on the alerts entity.** `alerts.rs` has no stats handling and the
  dispatcher does not reject it, so `in:alerts stats:count() by device_uid`
  returns raw un-aggregated rows with a 200. A real bug, pre-existing, and
  orthogonal to this change.
