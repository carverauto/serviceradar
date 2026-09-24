## 1. Run the import off the callback
- [x] 1.1 In `index_events/device_management.ex`, change `import_csv_preview/1` to `start_async(:import_devices, fn -> ... end)` instead of calling `IndexCsvImport.import_devices/2` inline. Follow the house pattern (47 existing `start_async` sites; `settings/mail_live.ex` `send_test_email` is the cleanest model).
- [x] 1.2 Capture the parse-time skip warnings before clearing them, so the result summary can report rows dropped while reading the file. Today the success path clears `csv_warnings` before the operator can read them.
- [x] 1.3 Add a `handle_event("import_csv", _, socket)` clause that matches an already-running import and returns without starting another, mirroring `mail_live.ex`'s `test_sending: true` guard.
- [x] 1.4 Add `handle_async(:import_devices, {:ok, result}, socket)` building the summary from `import_devices/2`'s existing `{:ok, {created, updated}}` / `{:error, %{created:, updated:, errors:}}` returns — do not change what the importer returns.
- [x] 1.5 Add `handle_async(:import_devices, {:exit, reason}, socket)` that clears the pending state and reports a failure. No such path exists today because the work is synchronous, so a crash takes the LiveView with it.

## 2. Pending state on the control
- [x] 2.1 Thread an `importing` assign through `index.ex` -> `index_view.ex` -> `import_modal.ex` as a declared `attr`.
- [x] 2.2 Disable the Import button while importing and relabel it ("Importing…") with a spinner, so the feedback is on the control the operator clicked.
- [ ] 2.3 Confirm the Cancel/close affordance still behaves sensibly mid-import, and decide deliberately whether closing is allowed while work is in flight. Record the decision.

## 3. The result summary
- [x] 3.1 Thread an `import_result` assign through the same path as `importing`.
- [x] 3.2 Render created and updated counts, the failure count with its error list, and the skip warnings verbatim (they already name the row and reason and already summarise an overflow).
- [x] 3.3 Require an explicit dismissal. A successful import must no longer auto-close the modal nor `push_patch` to `/devices` — that is what discarded the account of what happened.
- [x] 3.4 On dismissal, clear the import state and refresh the device list so the operator sees the imported devices.
- [x] 3.5 Make sure a skipped row is never presented as created or updated.

## 4. Tests
- [x] 4.1 Covered by construction and by `import_modal_markup_test.exs`: `disabled={@importing}` and the "Importing…" label are asserted directly via `render_component/2` (no database). The original claim that a rendering test would require a database was wrong — ImportModal is a pure function component and renders without a LiveView process.
- [x] 4.2 A second `import_csv` event while one is running starts no second import.
- [x] 4.3 A wholly successful import renders created/updated counts and does NOT close the modal or navigate away.
- [x] 4.4 A partial import renders the counts alongside the identified failures.
- [x] 4.5 Rows skipped at parse time appear in the summary with their reasons.
- [x] 4.6 An `{:exit, _}` from the async task clears the pending state, reports failure, and re-enables the control.
- [x] 4.7 The six existing `parse_csv_file` assertions in `test/phoenix/live/device_live/index_helpers_test.exs` still pass — its 3-tuple contract is deliberately untouched.
- [x] 4.8 CORRECTION: The original claim that modal rendering tests need a database was wrong. ImportModal is a pure function component (`use ServiceRadarWebNGWeb, :html`); `render_component/2` renders it without a LiveView process or database. Rendering tests have been added in `import_modal_markup_test.exs` and tagged `:db_free`.

## 5. Verification
- [x] 5.1 `mix compile` clean with no new warnings in the changed files.
- [x] 5.2 `mix format --check-formatted` clean.
- [x] 5.3 Not needed: this change introduces no timestamp formatter call site. Inventory test re-run anyway and passes 5/0.
- [ ] 5.4 NOT DONE — needs a running instance and a browser. This is the acceptance test: import a CSV mixing valid rows, an unreadable row, and a duplicate, and confirm the spinner appears, the button is unclickable during the run, and the summary accounts for all three categories.

## 6. Hand-off
- [x] 6.1 Note that `start_async` is bound to the LiveView process, so navigating away still abandons the import; a durable job is out of scope and deliberately not attempted.
- [x] 6.2 Note that no determinate progress is possible without restructuring the importer to report per-row, and that an indeterminate spinner was chosen over a fictional percentage.

## 7. Integration wiring caught during implementation
- [x] 7.1 `handle_async` callbacks are dispatched to the LiveView module, which is `Index` — not to `DeviceManagement`. Clauses written in `DeviceManagement` would never have fired, and the import result would have reached `Index.handle_async/3` with no matching clause. The callbacks now live in `index.ex` and delegate to `DeviceManagement.apply_import_result/2` and `apply_import_failure/2`. A clean compile does not catch this.
- [x] 7.2 `index_events.ex` routes `handle_event` through an `@device_management_events` whitelist, so the new `dismiss_import_result` event had to be added to it or it would never have routed.
- [x] 7.3 Removed `import_partial_message/3`, which this change orphaned — it existed to cram a partial result into one flash line, which the summary tiles now do properly. It had no remaining callers and no tests. `import_success_message/3` is kept and still used, for the one-line sentence above the tiles, so it does not become test-only code.
- [x] 7.4 The summary sentence is omitted entirely when nothing succeeded: `import_success_message(0, 0)` returns "Created 0 device(s) successfully", which on a wholly failed import is worse than saying nothing. Caught by a test, not by review.
