# Change: Tell the operator what the device import is doing, and what it did

## Why

Importing a device CSV gives no feedback while it runs and no reviewable account
of what happened when it finishes.

Reported from use: "I hit the import button, there is no progress indicator that
it is working/loading, it just sits there and the user has no idea if it worked or
failed."

Both halves of that are real, and the first is worse than it looks.

**Nothing indicates work is happening, because the LiveView cannot render.**
`import_csv_preview/1` in `index_events/device_management.ex` calls
`IndexCsvImport.import_devices/2` **synchronously inside `handle_event`**. That
call resolves hostnames over DNS for every hostname-only row — `Task.async_stream`
with a `@dns_timeout` per row — and then upserts every device. While it runs, the
LiveView process is blocked in the callback, so it cannot re-render even if
something wanted it to. The Import button has no `disabled` state and no pending
label, so it stays live and clickable: a second click is another full import.
For a several-hundred-row file this is tens of seconds of a frozen screen that
looks broken.

**What happened is reported thinly, and only on the failure path.** On success the
modal closes, state is cleared, a flash says "Created N device(s) successfully.",
and the view patches back to `/devices` — so the one account of the import is a
transient flash, gone on the next navigation, with no per-row detail. On partial
failure the modal stays open with `csv_errors` and an `import_status` line, which
is more useful than the success path. And rows dropped while *reading* the file
are tracked with reasons (`skip_warnings/1` emits "Row 12 skipped: …") but land in
`csv_warnings`, which the success path clears before the operator can read it.

So the operator learns the least in the case they most want to confirm.

## What Changes

- **Run the import asynchronously** via `start_async/3`, matching the established
  pattern in this app (47 existing `start_async` call sites, e.g. `send_test_email`
  in `settings/mail_live.ex`). The LiveView stays responsive and can render a
  pending state while the work runs.
- **Guard against re-entry.** A `handle_event("import_csv", …)` clause matching on
  an already-running import returns without starting a second one, the same shape
  as `mail_live.ex`'s `test_sending: true` guard. Today a double click means two
  concurrent imports of the same file.
- **Show progress on the control that started it.** The Import button is disabled
  while importing and relabels to "Importing…" with a spinner, so the feedback is
  attached to the thing the operator clicked rather than somewhere else on screen.
- **Replace the success flash with a result summary the operator can read.** When
  the import finishes, the modal shows what happened instead of closing:
  - **created** and **updated** counts, exact, from `import_devices/2`
  - **failed** count with the error list, exact
  - the **rows skipped while reading the file**, verbatim from the existing skip
    warnings, which already name the row and the reason and already summarise an
    overflow ("… and 14 more row(s) skipped")
  - a single explicit dismissal, so nothing disappears before it is read
- **Handle the crash case.** `handle_async` gains an `{:exit, reason}` clause, so
  an import that dies reports a failure instead of leaving the modal in its
  pending state forever. Today there is no such path because the work is
  synchronous — a crash takes the whole LiveView down instead.

## Non-goals

- **A percentage or row-by-row progress bar.** `import_devices/2` is one call that
  returns once; there is no progress channel to read, and inventing one means
  restructuring the importer to report per-row. A determinate bar would be a
  fiction. An indeterminate spinner plus a disabled control is honest about what
  is known.
- **An exact count of rows skipped while reading.** `parse_csv_file/1` returns
  `{:ok, devices, warnings}` and discards the skipped count; `skip_warnings/1`
  converts it to strings. Six existing assertions in
  `test/phoenix/live/device_live/index_helpers_test.exs` match that 3-tuple
  exactly, and widening it buys no information the warnings do not already carry —
  they name each row and summarise the remainder. Deliberately left alone.
- **Changing what the import does.** No change to parsing, hostname resolution,
  partition handling, upsert behaviour, or the shape `import_devices/2` returns.
  This change is entirely about what the operator is told.
- **Backgrounding the import beyond the LiveView's lifetime.** `start_async` is
  tied to the LiveView process, so navigating away still abandons the import. A
  durable job queue is a larger change and is not what the report asked for.

## Impact

- Affected specs: `device-inventory`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/device_live/index_events/device_management.ex`
    — `import_csv_preview/1` starts an async task instead of blocking; new
    `handle_async` clauses for success and exit; result assigned rather than
    flashed.
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/device_live/index_view/import_modal.ex`
    — pending state on the Import button; a result section rendering
    created/updated/failed and the skip warnings.
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/device_live/index_view.ex` and
    `index.ex` — assign plumbing for the new `importing` / `import_result` state.
  - tests alongside each.
- Risk: low. The importer itself is untouched; the change is where its result is
  rendered and when the work runs. The one behavioural change beyond presentation
  is that a successful import no longer auto-closes the modal and no longer
  patches to `/devices` — deliberate, since that is what discarded the account of
  what happened, but it is a visible difference for anyone used to the old flow.
- No API, manifest, or CLI surface changes. No migration.

## Note on OpenSpec conventions

`openspec/AGENTS.md` says to skip a proposal for a bug fix restoring intended
behaviour. This is filed as a change because it alters the operator-facing contract
of an import: a successful import now reports a reviewable summary and keeps the
modal open, rather than flashing a count and navigating away. That belongs in the
`device-inventory` spec rather than in a commit message.
