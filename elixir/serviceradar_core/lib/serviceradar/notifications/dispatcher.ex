defmodule ServiceRadar.Notifications.Dispatcher do
  @moduledoc """
  The impure orchestrator that turns an alert into a delivery, and a delivery
  into a send.

  Everything hard about notifications - routing, deduplication, escalation,
  suppression, and the retry rule - is decided by pure functions that take `now`
  as a parameter and never touch a database:
  `ServiceRadar.Notifications.Router`, `.Dedupe`, `.Escalation`, `.Suppression`,
  and `Transport.Result.outcome/2`. This module is the layer that **loads** what
  they need, **calls** them, and **persists** what comes back. It is the only
  place in the platform that does all three.

  Decide, then persist. No query belongs inside a core, and no core may read the
  clock: `now` is captured here exactly once per entry point and threaded down,
  which is what makes a routing or suppression decision replayable when an
  operator asks "why was I paged?" - or, more often, "why was I not?".

  ## Four entry points, and what drives each

  | Function | Called by | Emits |
  | --- | --- | --- |
  | `route/3` | `AlertLifecycle` for a new incident notification; the scheduler for escalation/renotify continuation | `:pending` and `:suppressed` `NotificationDelivery` rows |
  | `deliver/2` | the delivery Oban worker | one transport attempt, and the row that records it |
  | `due/2` | the scheduler tick | the work owed right now |
  | `reconcile/2` | the receipt sweep | agent-routed rows settled from their command row, plus the ones a reconnected agent made due early |

  Design D8 splits those deliberately and they are not interchangeable:
  `AlertLifecycle` is the **only** path that may originate a first notification,
  because it is where incident identity, dedup state, and the alert row are
  already consistent. The scheduler drives **continuation only** - retry-due,
  escalation-step-due, renotify - always against deliveries that already exist.
  `due/2` reflects that: its `:escalation` list contains only alerts that
  already have a delivery record.

  ## The Oban contract the workers must honour

  The `:notifications` queue (concurrency 5, `config.exs:36`) is about to carry
  several workers - a delivery worker, an escalation/continuation worker, a
  silence-expiry sweeper, a snooze-expiry sweeper, and a delivery-retention
  worker. All of them call into this module, and all of them are bound by the
  Oban Iron Laws: **args use string keys, args carry ids and never structs, and
  every job is safe to run twice**.

  Safety on re-run is provided here, not in the workers:

    * `route/3` re-derives the same plan and excludes dispatches it already
      created, so a duplicate lifecycle callback or an overlapping scheduler tick
      resolves to the existing work (design D6, "routing requests are
      idempotent").
    * `deliver/2` guards on the delivery's own state before doing anything -
      the `:already_sent` shape of
      `ServiceRadarWebNG.Dashboards.ReportDeliveryWorker.ensure_deliverable/1`.
      A `:sent` row answers `{:ok, :sent}` without a second send; a `:suppressed`
      row answers `{:ok, :suppressed}`.

  ### `{:error, _}` from `deliver/2` never means "run me again"

  This is the one place a worker author can get it wrong and produce a bug that
  looks like the system working. Retry in this platform is governed by the
  **delivery row** - `attempt_count`, `max_attempts`, `next_attempt_at` - and
  never by Oban's own attempt counter. So:

    * `{:retry, at}` means "come back at `at`". Snooze the job until then.
    * `{:error, _}` means the attempt is finished and recorded, or the delivery
      could not be processed at all. Log it and complete the job. Returning
      `{:error, _}` from `perform/1` hands the delivery a second, invisible
      retry budget that no operator configured and `max_attempts` does not
      bound.

  A delivery that still deserves another attempt is always reachable through
  `due/2`, whatever the job did.

  ## `route/3` in detail

  1. Load the alert, its subject device, the rule that fired it, the enabled
     routes, and the active silences. Capture `now`.
  2. `Router.match/3` -> `Dedupe.dedupe_key/3` -> `Escalation.plan/1`, all pure.
  3. An **unrouted** alert is recorded, never dropped: one delivery row with
     `state: :suppressed` and the reason `Suppression.evaluate/1` returns, which
     is `Router.suppression_reason/1`'s `:no_matching_route` unless something
     alert-scoped (an out-of-service device, an active silence) explains it
     better. Design D5 puts `:no_matching_route` last in the precedence order
     for exactly that reason.
  4. Each planned dispatch becomes a `:pending` row carrying the **required**
     `alert_snapshot` (`Jobs.AlertsRetentionWorker` hard-deletes alerts after
     three days, so a delivery must outlive its alert), `max_attempts` and
     `execution_route` resolved from the channel, the negotiated
     `payload_format` and `provider_version` (design G7/G8: written before
     dispatch so the row stays explicable after the provider moves on), the
     `dedupe_key`, and `queued_at`/`next_attempt_at` set to the instant the rung
     was **owed** rather than the instant the scheduler happened to wake.
  5. Each `withheld` entry from the plan becomes a `:suppressed` row with
     `suppression_reason: :acknowledged`. Silent drops are prohibited (D5).

  `next_attempt_at` is populated at creation on purpose. It is what makes the
  `:retry_due` scan a genuine safety net: a pending row whose Oban job was lost
  is still owed, and a scan that only found rows some earlier attempt had
  stamped would never find the ones that never got an attempt at all.

  ### Idempotency

  Two mechanisms, because they cover different failures.

  Sequentially, the plan is recomputed and dispatches that already have a row
  are excluded - `Escalation.plan/1` takes them as `:dispatched`
  `{step_number, channel_id, due_at}` tuples, and `queued_at` is where `due_at`
  is stored. Re-emitting the same routing request therefore resolves to the
  existing work rather than a second dispatch.

  Concurrently, that read-then-write would race, so `route/3` serialises on a
  transaction-scoped Postgres advisory lock derived from
  `Dedupe.routing_request_key/1` - the one derivation of
  `{alert_id, lifecycle_reason, step_number, dedupe_key}`, not a second one
  invented here. Two schedulers that overlap on the same request take the lock
  in turn, and the second one finds the first one's rows.

  ## `deliver/2` in detail

  1. Load the delivery, its channel, and the channel's provider.
  2. **Re-evaluate suppression** (D5, property 1). The delivery may have been
     planned fifteen minutes ago; since then the device may have been marked out
     of service, a silence may have started, the schedule window may have
     closed, or a human may have acknowledged. A withheld delivery transitions
     to `:suppressed` with the reason and answers `{:ok, :suppressed}`.
  3. Check the per-channel budget. Over budget reschedules and **does not burn
     an attempt** - the row is left exactly as it was, still `:pending` with
     `next_attempt_at` set, so the retry scan re-drives it even if the job is
     lost.
  4. Resolve `secret_refs` through `Plugins.SecretRefs` ->
     `Credentials.SecretBroker` into `Transport.Request.secrets`. Transports
     receive **already-resolved** secrets; that is what keeps every transport
     test async and database-free.
  5. Resolve the template for (alert class x payload format) and render it with
     the provider's declared `payload_formats`.
  6. Resolve the transport module - `Transports.Registry` for the `:native`
     tier, one engine for every `:declarative` document, `Transports.Stream` for
     the built-in firehose. This is the single point where a channel's provider
     tier is consulted, and the last one (design D2: nothing downstream may
     branch on `provider_type`). The provider's `definition` and the variable
     context the body was rendered against ride along on the request, so an
     engine that renders templates of its own has them without a second lookup.
  7. Map the result through `Transport.Result.outcome/2` and persist. That
     function is the only place the retry rule lives; a status code is never
     re-classified here.

  ### Both plugin routes end at an agent, because there is one Wasm host

  `:edge_agent` and `:wasm_plugin` are different reasons to reach an agent and
  both land in `edge_dispatch/4`. `:edge_agent` is the operator's choice of
  EGRESS: the notification must leave from the customer's own network (design
  R1). A `:wasm_plugin` provider reaches an agent whatever its route, because
  the only Wasm host in the product is wazero inside `go/pkg/agent` - on
  `:control_plane` the host is the platform-resident `serviceradar-agent` that
  already ships (design D3, tasks 3.3.1). Same command, same binary, same
  runtime; only the agent id differs, which is what
  `ServiceRadar.Notifications.PluginTarget` resolves.

  That resolution is also where package approval and `notify:v1` are checked
  before a command is sent, and its failures are PERMANENT: an unapproved
  package or a missing assignment is a configuration error that no retry fixes.

  ### The edge route is retryable, not immediately failed over

  An `:edge_agent` channel dispatches `plugin.run_action` through
  `ServiceRadar.Edge.AgentCommandBus`, which is **at-most-once with no
  store-and-forward**: with no control session it marks the command `offline`
  and returns `{:error, {:agent_offline, _}}`, and nothing re-drains it on
  reconnect. Design R2 resolves that this is permanent, not transitional -
  `usp-01` is an observation plane and does not make the command plane durable -
  and that the fix is a core-side dispatch outbox, tracked as **forgejo issue
  #4902**.

  This module is that outbox. An offline agent is a **retryable** outcome: the
  row stays `:pending` with `next_attempt_at` set, and failover happens only
  once the retry budget is spent. Failing over on the first offline reply would
  abandon a site that was briefly disconnected, which is precisely the
  disconnect an escalation ladder is supposed to survive.

  The delivery row is the system of record throughout; the command result is a
  wake-up signal only. Bus acceptance records the durable command id and leaves
  the delivery `:dispatching`. `reconcile/2` reads the persisted command result,
  validates the notifier SDK's `delivered | retryable | failed` payload, and is
  the only path that settles an accepted agent command. A missing or unreadable
  receipt is bounded by the same retry/failover budget rather than being guessed
  successful (tasks 3.4.4).

  This path was implemented in Phase 1, before anything could reach it, so that
  Phase 3 would inherit a working outbox rather than discover it needed one.
  Phase 3 opened the gate at the provider: `:wasm_plugin` rows now save, bound
  to a notifier their package's `notifications:` manifest block declares
  (`ServiceRadar.Notifications.Validations.ProviderActionKeyDeclared`). The
  agent refuses the dispatch unless the assignment's narrowed capability set
  carries `notify:v1` (`go/pkg/agent/plugin_runtime_notify.go`).

  ## Failover is one hop, and only from `:failed`

  Retry, failover, and escalation are three mechanisms and conflating them is
  the classic error (D4). Failover fires when a delivery reaches `:failed` -
  never on a retryable outcome that still has budget - and takes exactly **one**
  hop to `fallback_channel_id`. The successor carries `originating_delivery_id`
  so the Delivery Log renders one failover chain rather than two unrelated
  attempts. A `fail_closed` channel never fails over, and a delivery that is
  itself already a failover never fails over again.

  ## What this module deliberately does not do

  It does not mint acknowledgement capability tokens or build action links; it
  accepts them through `opts[:links]` so the acknowledgement surface owns its
  own credentials. It does not enqueue Oban jobs - the workers own their own
  scheduling and this module stays callable from a test with no queue running.
  It does not decide escalation, cadence, or suppression; it asks.

  See `openspec/changes/add-notification-platform/design.md` (D3, D4, D5, D6,
  D8, R2).
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.ActionLinks
  alias ServiceRadar.Notifications.Dedupe
  alias ServiceRadar.Notifications.Escalation
  alias ServiceRadar.Notifications.Grouping
  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationDelivery
  alias ServiceRadar.Notifications.NotificationDeliveryMember
  alias ServiceRadar.Notifications.NotificationEscalationPolicy
  alias ServiceRadar.Notifications.NotificationEscalationStep
  alias ServiceRadar.Notifications.NotificationRoute
  alias ServiceRadar.Notifications.NotificationSilence
  alias ServiceRadar.Notifications.NotificationTemplate
  alias ServiceRadar.Notifications.PluginCredentialGrants
  alias ServiceRadar.Notifications.PluginDeliveryResult
  alias ServiceRadar.Notifications.PluginTarget
  alias ServiceRadar.Notifications.RateLimiter
  alias ServiceRadar.Notifications.Renderer
  alias ServiceRadar.Notifications.Router
  alias ServiceRadar.Notifications.RoutingWorker
  alias ServiceRadar.Notifications.Suppression
  alias ServiceRadar.Notifications.Telemetry
  alias ServiceRadar.Notifications.TimeZone
  alias ServiceRadar.Notifications.Transport.Request
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.Notifications.Transports
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @edge_command_type "plugin.run_action"

  # The discriminator that makes a `plugin.run_action` payload a NOTIFICATION
  # dispatch (tasks 3.1.3). It is what `go/pkg/agent` keys the `notify:v1`
  # capability gate on, so it is a wire contract, not a label: the agent refuses
  # a payload carrying this schema unless the assignment's narrowed capability
  # set includes `notify:v1`. Its Go counterpart is
  # `notificationDeliveryEnvelopeSchema` in `plugin_runtime_notify.go`; the two
  # strings must stay identical.
  @edge_command_schema "serviceradar.notification_delivery.v1"

  @doc """
  The envelope schema every edge notification dispatch carries.

  Exposed so a test can assert the Elixir and Go halves of the capability gate
  name the same envelope rather than each asserting its own constant.
  """
  @spec edge_command_schema() :: String.t()
  def edge_command_schema, do: @edge_command_schema

  # Backoff floor, ceiling, and jitter. Thirty seconds is long enough that a
  # rate-limited or briefly-down destination has actually changed state by the
  # next attempt, and an hour is long enough that the ceiling is reached only
  # after the attempt budget realistically is.
  @base_backoff_ms 30_000
  @max_backoff_ms 3_600_000
  @jitter_fraction 0.2

  # How long receipt reconciliation leaves a `:dispatching` row alone when its
  # durable AgentCommand cannot be read. `due/2` deliberately selects only
  # `:pending`: redispatching an in-flight command would duplicate a page. Once
  # this grace period passes, `reconcile/2` settles the unreadable handoff as a
  # retryable failure through the ordinary attempt budget.
  @dispatching_stall_seconds 300

  # 2^32 base backoff already exceeds the ceiling by orders of magnitude, so the
  # exponent is capped before it is computed rather than after: `min/2` on a
  # bignum still pays for the bignum.
  @max_backoff_exponent 32

  @default_due_limit 500

  # Used when no NotificationTemplate resolves for (alert class x payload
  # format). A deployment whose managed templates have not been seeded yet must
  # still be able to page; every path here is in the published variable catalog,
  # so an unresolved one renders empty rather than raising.
  @fallback_template %{
    subject_template: "{{ alert.severity }}: {{ alert.title }}",
    body_template:
      "{{ alert.title }}\n\n{{ alert.description }}\n\n" <>
        "Severity: {{ alert.severity }}\nStatus: {{ alert.status }}",
    payload_format: nil
  }

  @terminal_states [:sent, :failed, :expired, :cancelled, :suppressed, :skipped]
  @attemptable_states [:pending]

  @type route_result :: %{planned: [binary()], suppressed: [binary()]}
  @type due_result :: %{retry: [binary()], escalation: [binary()], renotify: [binary()]}

  @type deliver_result ::
          {:ok, :sent | :suppressed | :dispatching}
          | {:retry, DateTime.t()}
          | {:error, term()}

  # --- route ----------------------------------------------------------------

  @doc """
  Plans and persists the notification deliveries an alert is owed.

  `lifecycle_reason` records *why* the lifecycle emitted - `:fire`, `:renotify`,
  `:escalate`, `:resolve` - and is half of the idempotency key, so two otherwise
  identical requests for the same alert and step stay distinct.

  Returns the ids of the rows created: `planned` are `:pending` deliveries an
  Oban job should pick up, `suppressed` are withheld decisions recorded for the
  Delivery Log. Both lists are empty when everything the plan asked for already
  existed, which is the normal answer to a duplicate request.

  Options:

    * `:now` - the decision instant. Defaults to `DateTime.utc_now/0`, captured
      once and threaded through every pure call.
    * `:actor` - defaults to a system actor.
    * `:step_number` - the step this request continues, for the idempotency key.
      `nil` (the default) is correct for a first notification.
    * `:dedupe_key` - overrides the derived key. For the caller that already
      holds one; do not use it to invent a second identity scheme.
    * `:lock?` - default `true`. Take the advisory lock that serialises
      concurrent requests for the same routing request key.
    * `:load_alert`, `:load_enabled_routes`, `:load_rule`, and
      `:load_active_silences` - read seams used to prove that decision-critical
      database failures abort before a suppression or delivery row is written.
  """
  @spec route(binary(), atom(), keyword()) :: {:ok, route_result()} | {:error, term()}
  def route(alert_id, lifecycle_reason, opts \\ [])

  def route(alert_id, lifecycle_reason, opts)
      when is_binary(alert_id) and is_atom(lifecycle_reason) and not is_nil(lifecycle_reason) and
             is_list(opts) do
    now = fetch_now(opts)
    actor = fetch_actor(opts)

    with {:ok, alert} <- load_alert(alert_id, actor, opts) do
      if lifecycle_reason == :resolve do
        scope = resolution_scope(alert, now, opts)
        result = route_resolution(scope, actor, opts)
        emit_routed(alert_id, lifecycle_reason, %{matched: []}, result)
        result
      else
        with {:ok, routes} <- load_enabled_routes(actor, opts),
             {:ok, scope} <- routing_scope(alert, now, actor, opts) do
          decision = Router.match(alert, routes, now)

          log_route_errors(alert_id, decision)

          result =
            if Router.unrouted?(decision) do
              route_unrouted(scope, decision, lifecycle_reason, actor, opts)
            else
              route_matched(scope, decision, lifecycle_reason, actor, opts)
            end

          emit_routed(alert_id, lifecycle_reason, decision, result)

          result
        end
      end
    end
  end

  def route(_alert_id, _lifecycle_reason, _opts), do: {:error, :invalid_routing_request}

  # --- deliver --------------------------------------------------------------

  @doc """
  Performs one transport attempt for a delivery, and records what happened.

  Safe to call twice against the same row: a terminal delivery answers from its
  own state without contacting anything.

  Returns:

    * `{:ok, :sent}` - accepted by the destination, or already was.
    * `{:ok, :suppressed}` - withheld by re-evaluated suppression, recorded with
      its reason.
    * `{:retry, at}` - the attempt is owed again at `at`; the row is `:pending`.
      This is the ONLY return value that asks the caller to come back.
    * `{:error, reason}` - finished, or unprocessable. See the moduledoc: never
      translate this into an Oban retry.

  Options:

    * `:now` - the attempt instant. Defaults to `DateTime.utc_now/0`.
    * `:actor` - defaults to a system actor.
    * `:transport` - a module replacing the resolved transport. The seam that
      lets the happy path be tested without a network.
    * `:transport_opts` - forwarded verbatim to the transport (`:req_options`,
      `:broadcast`, `:secret_broker` are the documented per-transport seams).
    * `:command_bus` - a module replacing `Edge.AgentCommandBus`.
    * `:rand` - a zero-arity float source for backoff jitter, so a backoff test
      is deterministic.
    * `:create_failover_delivery` - a three-argument persistence seam used to
      prove the failed origin and its failover successor commit atomically.
    * `:links` - `%{acknowledge:, snooze:, resolve:, alert:}` for the renderer.
      Minted by the acknowledgement surface, never here.
    * `:render_context` - extra renderer namespaces merged over the ones built
      from the loaded rows.
    * `:load_delivery`, `:load_route`, `:load_step`, `:load_delivery_alert`,
      `:load_rule`, `:load_active_silences`, and `:load_last_dispatch_at` - read
      seams for the suppression preflight. A read error aborts before rate-limit
      reservation, delivery mutation, or transport egress.
  """
  @spec deliver(binary(), keyword()) :: deliver_result()
  def deliver(delivery_id, opts \\ [])

  def deliver(delivery_id, opts) when is_binary(delivery_id) and is_list(opts) do
    now = fetch_now(opts)
    actor = fetch_actor(opts)

    with {:ok, delivery} <- load_delivery(delivery_id, actor, opts),
         :continue <- attemptable(delivery, now) do
      deliver_attemptable(delivery, now, actor, opts)
    else
      {:settled, {:ok, :sent}, delivery} ->
        case ensure_late_resolution_routed(delivery, actor, opts) do
          :ok -> {:ok, :sent}
          {:error, reason} -> {:error, {:sent_but_resolution_unrouted, reason}}
        end

      {:settled, result} ->
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  def deliver(_delivery_id, _opts), do: {:error, :invalid_delivery_id}

  defp deliver_attemptable(delivery, now, actor, opts) do
    with {:ok, channel} <- fetch_channel(delivery),
         {:ok, provider} <- fetch_provider(channel) do
      attempt(delivery, channel, provider, now, actor, opts)
    else
      {:error, :channel_not_found} ->
        result =
          Result.permanent_failure("channel_not_found",
            error_message: "notification channel was deleted before delivery"
          )

        record_failed(delivery, nil, result, now, actor, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- due ------------------------------------------------------------------

  @doc """
  The notification work owed at `now`.

    * `:retry` - delivery ids for `deliver/2`. Only retry-due `:pending` rows.
      An agent command already in `:dispatching` is never re-dispatched blind;
      `reconcile/2` owns its bounded receipt timeout.
    * `:escalation` - **alert** ids for `route/3` with an escalation
      `lifecycle_reason`. Only alerts that already have a non-test delivery that
      was actually dispatched to a destination appear - a suppression record is
      not one, so an unrouted alert never shows up here. Design D8 forbids the
      scheduler from originating a first notification; that is `AlertLifecycle`'s
      alone.
    * `:renotify` - **alert** ids whose governing stateful rule cadence has
      elapsed. These already have a dispatched delivery and are handed back to
      `AlertLifecycle.send_renotify/4`, which owns cadence bookkeeping.

  Returns a bare map with no error channel, because a scheduler tick that cannot
  read one half must still drive the other. A failed read is logged and yields
  an empty list.

  Options: `:actor` and `:limit` (per list, default #{@default_due_limit}).
  """
  @spec due(DateTime.t(), keyword()) :: due_result()
  def due(now, opts \\ [])

  def due(%DateTime{} = now, opts) when is_list(opts) do
    actor = fetch_actor(opts)
    limit = Keyword.get(opts, :limit, @default_due_limit)

    %{
      retry: due_retry(now, limit, actor, opts),
      escalation: due_escalation(limit, actor),
      renotify: due_renotify(now, limit, actor)
    }
  end

  # --- reconcile ------------------------------------------------------------

  @doc """
  Closes out agent-routed deliveries whose wake-up signal never arrived, and
  names the ones a reconnected agent has made due early.

  Two lists come back:

    * `:settled` - delivery ids this pass drove to a terminal state (or back to
      `:pending` with a fresh backoff) from the durable `agent_commands` row.
    * `:drain` - delivery ids waiting out a backoff they no longer need,
      because the agent they are bound to has a control session again. The
      caller reschedules them; nothing is written here.

  ## Why this exists (design D3, tasks 3.4.4)

  `ServiceRadar.AgentCommands.StatusHandler` durably persists command acks,
  progress, and results; deployed releases enable it. This pass then maps that
  durable command row onto the delivery instead of treating the handler's
  wake-up as the record. With the handler unavailable, the command's core-owned
  `expires_at` still bounds the wait and moves the delivery through its ordinary
  retry/failover budget, but success is never inferred without a persisted SDK
  result.

  Every accepted agent command remains `:dispatching` until this pass reads its
  receipt. `due/2` never re-dispatches such a row blind, which would send a
  second notification for a command the agent may already have run.

  Options: `:actor`, `:limit`, `:load_command`, and `:agent_online?`.
  """
  @spec reconcile(DateTime.t(), keyword()) :: %{settled: [binary()], drain: [binary()]}
  def reconcile(now, opts \\ [])

  def reconcile(%DateTime{} = now, opts) when is_list(opts) do
    actor = fetch_actor(opts)
    limit = Keyword.get(opts, :limit, @default_due_limit)

    %{
      settled: settle_receipts(now, limit, actor, opts),
      drain: drain_ready(now, limit, actor, opts)
    }
  end

  defp settle_receipts(now, limit, actor, opts) do
    NotificationDelivery
    |> Ash.Query.filter(state == :dispatching)
    |> Ash.Query.load(channel: [:provider])
    |> Ash.Query.sort(started_at: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, deliveries} ->
        Enum.flat_map(deliveries, &settle_receipt(&1, now, actor, opts))

      {:error, reason} ->
        log_read_failure("deliveries awaiting a command receipt", reason)
        []
    end
  end

  defp settle_receipt(delivery, now, actor, opts) do
    loader = Keyword.get(opts, :load_command, &load_command/2)

    command =
      case delivery.command_id do
        nil -> nil
        command_id -> loader.(command_id, actor)
      end

    case command_outcome(command, delivery, now, opts) do
      nil ->
        []

      %Result{} = result ->
        _ = settle(delivery, delivery.channel, result, nil, now, actor, opts)
        [delivery.id]
    end
  end

  # A command row that cannot be read is left alone rather than guessed at: the
  # stall sweep in `due/2` is the backstop, and inventing a failure here would
  # fail a delivery whose command may have succeeded.
  defp command_outcome(nil, delivery, now, opts) do
    if dispatch_stalled?(delivery, now, opts) do
      Result.retryable_failure("command_handoff_incomplete",
        error_message: "the agent handoff never recorded a durable command id",
        result_summary: %{"receipt" => "command_handoff_incomplete"}
      )
    end
  end

  defp command_outcome({:error, reason}, delivery, now, opts),
    do: unavailable_command_outcome(delivery, now, opts, reason)

  defp command_outcome({:ok, nil}, delivery, now, opts),
    do: unavailable_command_outcome(delivery, now, opts, :not_found)

  defp command_outcome({:ok, command}, delivery, now, opts),
    do: command_outcome(command, delivery, now, opts)

  defp command_outcome(%{status: status} = command, delivery, _now, _opts)
       when status in [:completed, :failed] do
    PluginDeliveryResult.from_command(command, delivery.id)
  end

  defp command_outcome(%{status: status} = command, _delivery, _now, _opts)
       when status in [:expired, :canceled, :offline] do
    Result.retryable_failure("command_#{status}",
      error_message:
        Map.get(command, :failure_reason) || Map.get(command, :message) ||
          "the agent command ended #{status} without delivering",
      result_summary: %{
        "receipt" => "command_#{status}",
        "command_id" => to_string(Map.get(command, :id))
      }
    )
  end

  # In flight and still inside its own TTL: the agent may yet answer, so the row
  # is left where it is. Past the TTL with no result, the command is dead
  # whether or not anything was listening for its ack, and the delivery is owed
  # another attempt within its ordinary budget.
  defp command_outcome(%{} = command, _delivery, now, _opts) do
    if expired?(Map.get(command, :expires_at), now) do
      Result.retryable_failure("command_receipt_timeout",
        error_message: "the agent command passed its TTL with no result",
        result_summary: %{
          "receipt" => "timeout",
          "command_id" => to_string(Map.get(command, :id)),
          "expires_at" => iso8601(Map.get(command, :expires_at))
        }
      )
    end
  end

  defp dispatch_stalled?(delivery, now, opts) do
    cutoff =
      DateTime.add(
        now,
        -Keyword.get(opts, :stall_seconds, @dispatching_stall_seconds),
        :second
      )

    case Map.get(delivery, :started_at) do
      %DateTime{} = started_at -> not DateTime.after?(started_at, cutoff)
      _missing -> true
    end
  end

  defp unavailable_command_outcome(delivery, now, opts, reason) do
    if dispatch_stalled?(delivery, now, opts) do
      Result.retryable_failure("command_receipt_unavailable",
        error_message: "the durable agent command receipt could not be read",
        result_summary: %{
          "receipt" => "command_receipt_unavailable",
          "reason" => inspect(reason)
        }
      )
    end
  end

  defp expired?(%DateTime{} = expires_at, now), do: DateTime.before?(expires_at, now)
  defp expired?(_expires_at, _now), do: false

  defp load_command(command_id, actor) do
    Ash.get(AgentCommand, command_id, actor: actor)
  end

  # The "reconnect drain" (tasks 3.4.5). There is nothing queued AT the agent to
  # drain - the bus is at-most-once and marks the command `offline` rather than
  # spooling it - so what is drained is the delivery row waiting out a backoff
  # in core. A row whose next attempt is still in the future is not selected by
  # `due/2`; when the agent it is bound to has a control session again, waiting
  # out the rest of that backoff is pure lost time on a page that is already
  # late.
  #
  # Rows already due are deliberately excluded: `due/2` returns those, and
  # naming them here as well would only enqueue the same work twice.
  defp drain_ready(now, limit, actor, opts) do
    online? = Keyword.get(opts, :agent_online?, &agent_online?/1)

    NotificationDelivery
    |> Ash.Query.filter(
      state == :pending and error_class == "agent_offline" and not is_nil(agent_uid) and
        attempt_count < max_attempts and next_attempt_at > ^now
    )
    |> Ash.Query.sort(next_attempt_at: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, deliveries} ->
        deliveries
        |> Enum.group_by(& &1.agent_uid)
        |> Enum.filter(fn {agent_uid, _rows} -> online?.(agent_uid) end)
        |> Enum.flat_map(fn {_agent_uid, rows} -> Enum.map(rows, & &1.id) end)

      {:error, reason} ->
        log_read_failure("offline deliveries awaiting a reconnect", reason)
        []
    end
  end

  defp agent_online?(agent_uid) do
    AgentCommandBus.lookup_control_session_entries(agent_uid) != []
  end

  # --- backoff --------------------------------------------------------------

  @doc """
  The delay before attempt `attempt` is retried, in milliseconds.

  Exponential from a 30 s base, capped at one hour, with up to 20% of positive
  jitter so a fan-out that failed together does not retry together and turn a
  transient outage into a synchronised thundering herd.

  `retry_after_ms` is a provider-supplied floor - Discord's fractional
  `retry_after`, an HTTP `Retry-After` header - and is honoured even when it
  exceeds the cap: a destination that says "wait ten minutes" is telling the
  truth about its own quota, and ignoring it earns a longer ban.

  Jitter is only ever added, never subtracted, so the result never lands before
  a floor the provider asked for.

  Pure, and the randomness is injected, so a test can pin it.
  """
  @spec backoff_ms(pos_integer(), non_neg_integer() | nil, (-> float())) :: pos_integer()
  def backoff_ms(attempt, retry_after_ms \\ nil, rand \\ &:rand.uniform/0)

  def backoff_ms(attempt, retry_after_ms, rand) when is_function(rand, 0) do
    exponent = attempt |> normalize_attempt() |> Kernel.-(1) |> min(@max_backoff_exponent)
    exponential = min(@base_backoff_ms * Integer.pow(2, exponent), @max_backoff_ms)
    floor_ms = if is_integer(retry_after_ms) and retry_after_ms > 0, do: retry_after_ms, else: 0
    base = max(exponential, floor_ms)

    base + trunc(base * @jitter_fraction * rand.())
  end

  defp normalize_attempt(attempt) when is_integer(attempt) and attempt >= 1, do: attempt
  defp normalize_attempt(_attempt), do: 1

  # --- routing --------------------------------------------------------------

  # A resolution is historical fan-out, not a fresh route match. Only
  # destinations that successfully received this incident are eligible, and
  # each policy decides independently whether it closes the loop.
  defp route_resolution(scope, actor, opts) do
    lock_dedupe = "resolution:" <> to_string(field(scope.alert, :id))

    with_request_lock(scope.alert, :resolve, lock_dedupe, opts, fn ->
      with {:ok, sent} <- resolution_sources(scope.alert, actor),
           :ok <- lock_resolution_sources(sent),
           {:ok, existing} <- existing_resolutions(scope.alert, actor),
           {:ok, cancelled, cancelled_notifications} <-
             cancel_pending_for_resolution(scope.alert, scope.now, actor),
           {:ok, planned, planned_notifications} <-
             persist_resolutions(scope, sent, existing, actor, opts) do
        {:ok,
         %{
           planned: planned,
           suppressed: [],
           cancelled: cancelled,
           notifications: cancelled_notifications ++ planned_notifications
         }}
      end
    end)
  end

  defp resolution_sources(alert, actor) do
    alert_id = field(alert, :id)

    direct_query =
      NotificationDelivery
      |> Ash.Query.filter(
        alert_id == ^alert_id and state == :sent and is_test == false and
          (is_nil(lifecycle_reason) or lifecycle_reason != :resolve)
      )
      |> Ash.Query.load([:policy, channel: [:provider]])
      |> Ash.Query.sort(finished_at: :desc)

    with {:ok, direct} <- Ash.read(direct_query, actor: actor),
         {:ok, memberships} <-
           delivery_memberships_for_alert(alert_id, actor, [:policy, channel: [:provider]]) do
      sources =
        memberships
        |> Enum.map(& &1.delivery)
        |> Enum.filter(fn delivery ->
          field(delivery, :state) == :sent and field(delivery, :is_test) == false and
            field(delivery, :lifecycle_reason) != :resolve
        end)
        |> Kernel.++(direct)
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})
        |> Enum.filter(fn delivery ->
          delivery |> field(:policy) |> field(:resolve_notifies) == true and
            not is_nil(field(delivery, :channel))
        end)
        |> Enum.uniq_by(&resolution_source_identity/1)

      {:ok, sources}
    else
      {:error, reason} ->
        {:error, {:resolution_history_unreadable, reason}}
    end
  end

  defp existing_resolutions(alert, actor) do
    alert_id = field(alert, :id)

    direct_query =
      Ash.Query.filter(
        NotificationDelivery,
        alert_id == ^alert_id and lifecycle_reason == :resolve and is_test == false
      )

    with {:ok, direct} <- Ash.read(direct_query, actor: actor),
         {:ok, memberships} <- delivery_memberships_for_alert(alert_id, actor) do
      resolutions =
        memberships
        |> Enum.map(& &1.delivery)
        |> Enum.filter(fn delivery ->
          field(delivery, :lifecycle_reason) == :resolve and field(delivery, :is_test) == false
        end)
        |> Kernel.++(direct)
        |> Enum.uniq_by(& &1.id)

      {:ok, MapSet.new(resolutions, &resolution_identity/1)}
    else
      {:error, reason} -> {:error, {:resolution_deliveries_unreadable, reason}}
    end
  end

  defp lock_resolution_sources(sources) do
    sources
    |> Enum.map(& &1.id)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
    |> Enum.each(fn delivery_id ->
      key = "notification-resolution-source:" <> to_string(delivery_id)
      _ = SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [lock_key(key)])
    end)

    :ok
  end

  defp persist_resolutions(scope, sent, existing, actor, opts) do
    sent
    |> Enum.reject(&MapSet.member?(existing, resolution_identity_from_source(&1)))
    |> collect(fn source -> create_resolution(scope, source, actor, opts) end)
  end

  defp create_resolution(scope, source, actor, opts) do
    channel = field(source, :channel)
    provider = field(channel, :provider)

    attrs = %{
      alert_id: field(scope.alert, :id),
      alert_snapshot: scope.snapshot,
      route_id: source.route_id,
      policy_id: source.policy_id,
      step_number: source.step_number,
      channel_id: source.channel_id,
      dedupe_key: source.dedupe_key,
      external_correlation_id: source.external_correlation_id,
      max_attempts: max_attempts(channel),
      execution_route: execution_route(channel),
      agent_uid: field(channel, :agent_uid),
      payload_format: negotiated_format(nil, provider),
      provider_version: field(provider, :definition_version),
      queued_at: scope.now,
      next_attempt_at: scope.now,
      lifecycle_reason: :resolve
    }

    with {:ok, delivery, delivery_notifications} <- create_planned(attrs, actor, opts),
         {:ok, source_members} <- delivery_members(source.id, actor),
         {:ok, _member_ids, member_notifications} <-
           copy_delivery_members(source_members, delivery.id, actor, opts) do
      {:ok, delivery.id, delivery_notifications ++ member_notifications}
    else
      {:error, reason} -> {:error, {:resolution_persistence_failed, reason}}
    end
  end

  defp copy_delivery_members(members, delivery_id, actor, opts) do
    collect(members, fn member ->
      case attach_delivery_member(
             delivery_id,
             member.alert_id,
             member.source_due_at,
             member.alert_snapshot,
             actor,
             opts
           ) do
        {:ok, attached, notifications} -> {:ok, attached.id, notifications}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp cancel_pending_for_resolution(alert, now, actor) do
    alert_id = field(alert, :id)

    direct_query =
      Ash.Query.filter(
        NotificationDelivery,
        alert_id == ^alert_id and state == :pending and is_test == false and
          (is_nil(lifecycle_reason) or lifecycle_reason != :resolve)
      )

    with {:ok, direct} <- Ash.read(direct_query, actor: actor),
         {:ok, memberships} <- delivery_memberships_for_alert(alert_id, actor) do
      pending =
        memberships
        |> Enum.map(& &1.delivery)
        |> Enum.filter(fn delivery ->
          field(delivery, :state) == :pending and field(delivery, :is_test) == false and
            field(delivery, :lifecycle_reason) != :resolve
        end)
        |> Kernel.++(direct)
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(& &1.id)

      collect(pending, fn delivery ->
        cancel_or_remove_pending_member(delivery, alert_id, now, actor)
      end)
    else
      {:error, reason} ->
        {:error, {:pending_resolution_deliveries_unreadable, reason}}
    end
  end

  defp cancel_or_remove_pending_member(delivery, alert_id, now, actor) do
    key =
      group_advisory_key(
        delivery.route_id,
        delivery.policy_id,
        delivery.step_number,
        delivery.channel_id,
        delivery.dedupe_key,
        delivery.lifecycle_reason
      )

    _ = SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [lock_key(key)])

    case delivery_members(delivery.id, actor) do
      {:ok, members} ->
        {removed, remaining} = Enum.split_with(members, &(&1.alert_id == alert_id))

        cond do
          removed != [] ->
            remove_pending_members(delivery, removed, remaining, now, actor)

          members != [] ->
            # Repair a stale legacy anchor without cancelling active siblings.
            case update_pending_group(delivery, members, actor) do
              {:ok, _updated, notifications} -> {:ok, nil, notifications}
              {:error, reason} -> {:error, {:resolution_cancellation_failed, reason}}
            end

          true ->
            cancel_pending_delivery(delivery, now, actor, [])
        end

      {:error, reason} ->
        {:error, {:resolution_cancellation_failed, reason}}
    end
  end

  defp remove_pending_members(delivery, removed, remaining, now, actor) do
    with {:ok, member_notifications} <- destroy_delivery_members(removed, actor) do
      if remaining == [] do
        cancel_pending_delivery(delivery, now, actor, member_notifications)
      else
        case update_pending_group(delivery, remaining, actor) do
          {:ok, _updated, delivery_notifications} ->
            {:ok, nil, member_notifications ++ delivery_notifications}

          {:error, reason} ->
            {:error, {:resolution_cancellation_failed, reason}}
        end
      end
    end
  end

  defp destroy_delivery_members(members, actor) do
    Enum.reduce_while(members, {:ok, []}, fn member, {:ok, notifications} ->
      case Ash.destroy(member, actor: actor, return_notifications?: true) do
        {:ok, new_notifications} -> {:cont, {:ok, notifications ++ new_notifications}}
        {:error, reason} -> {:halt, {:error, {:resolution_cancellation_failed, reason}}}
      end
    end)
  end

  defp cancel_pending_delivery(delivery, now, actor, member_notifications) do
    attrs = %{
      error_class: "alert_resolved",
      error_message: "the alert resolved before this delivery became due",
      result_summary: %{
        "cancelled_at" => DateTime.to_iso8601(now),
        "reason" => "alert_resolved"
      }
    }

    delivery
    |> Ash.Changeset.for_update(:record_cancelled, attrs, actor: actor)
    |> Ash.update(actor: actor, return_notifications?: true)
    |> case do
      {:ok, cancelled, notifications} ->
        {:ok, cancelled.id, member_notifications ++ notifications}

      {:error, reason} ->
        {:error, {:resolution_cancellation_failed, reason}}
    end
  end

  defp resolution_source_identity(delivery) do
    {delivery.route_id, delivery.policy_id, delivery.channel_id, delivery.dedupe_key,
     delivery.external_correlation_id}
  end

  defp resolution_identity_from_source(delivery) do
    {delivery.route_id, delivery.policy_id, delivery.channel_id, delivery.dedupe_key,
     delivery.external_correlation_id}
  end

  defp resolution_identity(delivery) do
    {delivery.route_id, delivery.policy_id, delivery.channel_id, delivery.dedupe_key,
     delivery.external_correlation_id}
  end

  defp routing_scope(alert, now, actor, opts) do
    with {:ok, rule} <- load_rule(alert, actor, opts),
         {:ok, silences} <- load_active_silences(now, actor, opts) do
      {:ok,
       %{
         alert: alert,
         device: alert_device(alert),
         rule: rule,
         silences: silences,
         snapshot: alert_snapshot(alert, opts),
         now: now
       }}
    end
  end

  # Resolution fans out from persisted delivery history, not current routing or
  # suppression configuration. Keep its scope free of route/rule/silence reads:
  # an outage on a table resolution does not consult must not prevent close-out.
  defp resolution_scope(alert, now, opts) do
    %{
      alert: alert,
      snapshot: alert_snapshot(alert, opts),
      now: now
    }
  end

  # An unrouted alert is the one case that would otherwise produce nothing at
  # all, so it is recorded through the same audit path as every other withheld
  # notification. Suppression - not a hardcoded reason - decides which
  # explanation an operator sees, because "the device is out of service" ends the
  # investigation and "you never wrote a route" does not.
  defp route_unrouted(scope, decision, lifecycle_reason, actor, opts) do
    dedupe_key = dedupe_key(scope.alert, nil, opts)

    context =
      suppression_context(scope, %{
        route: nil,
        dedupe_key: dedupe_key
      })

    outcome =
      case Suppression.evaluate(context) do
        :allow -> {:suppress, Router.suppression_reason(decision) || :no_matching_route, %{}}
        suppressed -> suppressed
      end

    with_request_lock(scope.alert, lifecycle_reason, dedupe_key, opts, fn ->
      with_unresolved_alert(scope.alert, actor, fn ->
        case record_suppression(outcome, context, actor) do
          {:ok, id, notifications} ->
            {:ok, %{planned: [], suppressed: [id], notifications: notifications}}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end)
  end

  defp route_matched(scope, decision, lifecycle_reason, actor, opts) do
    dedupe_key = dedupe_key(scope.alert, first_route(decision), opts)

    with_request_lock(scope.alert, lifecycle_reason, dedupe_key, opts, fn ->
      with_unresolved_alert(scope.alert, actor, fn ->
        Enum.reduce_while(decision.matched, {:ok, empty_result()}, fn match, acc ->
          case merge_result(acc, route_match(scope, match, lifecycle_reason, actor, opts)) do
            {:ok, _result} = result -> {:cont, result}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
      end)
    end)
  end

  # Alert loading happens before routing acquires its advisory lock. Re-read
  # after the lifecycle-wide lock so a stale fire callback that waited behind a
  # resolve cannot create a page for an alert that is already closed.
  defp with_unresolved_alert(alert, actor, fun) do
    case load_alert(field(alert, :id), actor) do
      {:ok, current} when current.status == :resolved -> {:ok, empty_result()}
      {:ok, _current} -> fun.()
      {:error, reason} -> {:error, {:alert_state_unreadable, reason}}
    end
  end

  defp route_match(scope, match, lifecycle_reason, actor, opts) do
    route = match.route
    dedupe_key = dedupe_key(scope.alert, route, opts)

    with {:ok, policy} <- load_policy(match.escalation_policy_id, actor, opts),
         {:ok, dispatched} <- existing_dispatches(scope.alert, route, dedupe_key, actor) do
      plan =
        Escalation.plan(%{
          now: scope.now,
          alert: scope.alert,
          policy: policy,
          steps: policy_steps(policy),
          rule: scope.rule,
          dispatched: dispatched
        })

      log_plan_diagnostics(scope.alert, route, plan)

      persist_plan(scope, route, policy, dedupe_key, plan, lifecycle_reason, actor, opts)
    end
  end

  defp persist_plan(scope, route, policy, dedupe_key, plan, lifecycle_reason, actor, opts) do
    channels = policy_channels(policy)
    steps = policy_steps_by_number(policy)

    placement = %{
      route: route,
      policy: policy,
      steps: steps,
      channels: channels,
      dedupe_key: dedupe_key,
      # Carried to the delivery row because it is not recoverable at render
      # time, and an incident API needs it: a resolving alert must tell PagerDuty
      # to resolve rather than trigger on the same dedup_key (task 4.3.3b).
      lifecycle_reason: lifecycle_reason
    }

    with {:ok, planned, planned_notifications} <-
           collect(plan.dispatches, &record_planned(scope, placement, &1, actor, opts)),
         {:ok, suppressed, withheld_notifications} <-
           collect(plan.withheld, fn {:acknowledged, dispatch} ->
             record_withheld(scope, placement, dispatch, actor)
           end) do
      {:ok,
       %{
         planned: planned,
         suppressed: suppressed,
         notifications: planned_notifications ++ withheld_notifications
       }}
    end
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, [], []}, fn item, {:ok, ids, notifications} ->
      case fun.(item) do
        {:ok, id, new_notifications} ->
          {:cont, {:ok, ids ++ List.wrap(id), notifications ++ new_notifications}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp record_planned(scope, placement, {step_number, channel_id, due_at}, actor, opts) do
    case grouped_not_before(
           scope,
           placement,
           step_number,
           channel_id,
           due_at,
           actor,
           opts
         ) do
      {:ok, next_attempt_at} ->
        record_planned_at(
          scope,
          placement,
          step_number,
          channel_id,
          due_at,
          next_attempt_at,
          actor,
          opts
        )

      {:error, reason} ->
        log_read_failure("the previous grouped delivery", reason)
        {:error, {:group_history_unreadable, reason}}
    end
  end

  defp record_planned_at(
         scope,
         placement,
         step_number,
         channel_id,
         due_at,
         next_attempt_at,
         actor,
         opts
       ) do
    channel = Map.get(placement.channels, channel_id)
    provider = field(channel, :provider)

    attrs = %{
      alert_id: field(scope.alert, :id),
      alert_snapshot: scope.snapshot,
      route_id: field(placement.route, :id),
      policy_id: field(placement.policy, :id),
      step_number: step_number,
      channel_id: channel_id,
      dedupe_key: placement.dedupe_key,
      max_attempts: max_attempts(channel),
      execution_route: execution_route(channel),
      agent_uid: field(channel, :agent_uid),
      payload_format: negotiated_format(nil, provider),
      provider_version: field(provider, :definition_version),
      # `due_at` is the instant the rung was OWED. Recording it rather than
      # `now` is what lets the Delivery Log show a late page as late, and it is
      # the value `Escalation.plan/1` reads back as `:dispatched`.
      queued_at: due_at,
      next_attempt_at: next_attempt_at,
      lifecycle_reason: Map.get(placement, :lifecycle_reason)
    }

    result =
      if Grouping.enabled?(placement.route) and placement.lifecycle_reason != :resolve do
        record_grouped(scope, placement, attrs, step_number, channel_id, actor, opts)
      else
        create_planned(attrs, actor, opts)
      end

    case result do
      {:ok, delivery, notifications} ->
        emit_escalated(delivery, channel)
        {:ok, delivery.id, notifications}

      {:error, reason} ->
        log_write_failure("plan a delivery", field(scope.alert, :id), step_number, reason)
        {:error, {:delivery_plan_persistence_failed, reason}}
    end
  end

  defp create_planned(attrs, actor, opts) do
    create = Keyword.get(opts, :create_delivery, &create_delivery/3)
    create.(:record_dispatch, attrs, actor)
  end

  defp record_grouped(scope, placement, attrs, step_number, channel_id, actor, opts) do
    key =
      group_advisory_key(
        field(placement.route, :id),
        field(placement.policy, :id),
        step_number,
        channel_id,
        placement.dedupe_key,
        placement.lifecycle_reason
      )

    _ = SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [lock_key(key)])

    case pending_group_delivery(placement, step_number, channel_id, actor) do
      {:ok, nil} ->
        with {:ok, delivery, delivery_notifications} <- create_planned(attrs, actor, opts),
             {:ok, _member, member_notifications} <-
               attach_delivery_member(
                 delivery.id,
                 field(scope.alert, :id),
                 attrs.queued_at,
                 scope.snapshot,
                 actor,
                 opts
               ) do
          {:ok, delivery, delivery_notifications ++ member_notifications}
        else
          {:error, reason} -> {:error, {:group_member_persistence_failed, reason}}
        end

      {:ok, pending} ->
        with {:ok, _member, member_notifications} <-
               attach_delivery_member(
                 pending.id,
                 field(scope.alert, :id),
                 attrs.queued_at,
                 scope.snapshot,
                 actor,
                 opts
               ),
             {:ok, members} <- delivery_members(pending.id, actor),
             {:ok, grouped, delivery_notifications} <-
               update_pending_group(pending, members, actor) do
          {:ok, grouped, member_notifications ++ delivery_notifications}
        else
          {:error, reason} -> {:error, {:group_member_persistence_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:pending_group_unreadable, reason}}
    end
  end

  defp attach_delivery_member(
         delivery_id,
         alert_id,
         %DateTime{} = source_due_at,
         snapshot,
         actor,
         opts
       ) do
    create = Keyword.get(opts, :create_delivery_member, &create_delivery_member/2)

    create.(
      %{
        delivery_id: delivery_id,
        alert_id: alert_id,
        source_due_at: source_due_at,
        alert_snapshot: snapshot
      },
      actor
    )
  end

  defp create_delivery_member(attrs, actor) do
    NotificationDeliveryMember
    |> Ash.Changeset.for_create(:attach, attrs, actor: actor)
    |> Ash.create(actor: actor, return_notifications?: true)
  end

  defp delivery_members(delivery_id, actor) do
    NotificationDeliveryMember
    |> Ash.Query.for_read(:for_delivery, %{delivery_id: delivery_id})
    |> Ash.read(actor: actor)
  end

  defp update_pending_group(pending, members, actor) do
    snapshot = members |> Enum.map(& &1.alert_snapshot) |> Grouping.aggregate_snapshots()
    anchor_alert_id = members |> List.first() |> field(:alert_id)

    pending
    |> Ash.Changeset.for_update(
      :record_group_member,
      %{
        alert_id: anchor_alert_id,
        alert_snapshot: snapshot,
        next_attempt_at: pending.next_attempt_at
      },
      actor: actor
    )
    |> Ash.update(actor: actor, return_notifications?: true)
  end

  defp group_advisory_key(
         route_id,
         policy_id,
         step_number,
         channel_id,
         dedupe_key,
         lifecycle_reason
       ) do
    Enum.join(
      [
        "notification-group",
        route_id,
        policy_id,
        step_number,
        channel_id,
        dedupe_key,
        lifecycle_reason
      ],
      ":"
    )
  end

  defp pending_group_delivery(placement, step_number, channel_id, actor) do
    route_id = field(placement.route, :id)
    policy_id = field(placement.policy, :id)
    dedupe_key = placement.dedupe_key
    lifecycle_reason = placement.lifecycle_reason

    NotificationDelivery
    |> Ash.Query.filter(
      route_id == ^route_id and policy_id == ^policy_id and step_number == ^step_number and
        channel_id == ^channel_id and dedupe_key == ^dedupe_key and
        lifecycle_reason == ^lifecycle_reason and state == :pending and is_test == false
    )
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor)
  end

  defp grouped_not_before(_scope, placement, step_number, channel_id, due_at, actor, opts) do
    if Grouping.enabled?(placement.route) and placement.lifecycle_reason != :resolve do
      with {:ok, last_sent_at} <-
             last_group_sent_at(placement, step_number, channel_id, actor, opts) do
        {:ok,
         Grouping.not_before(%{
           route: placement.route,
           due_at: due_at,
           last_sent_at: last_sent_at,
           step_number: step_number,
           first_step_number: first_step_number(placement.steps)
         })}
      end
    else
      {:ok, due_at}
    end
  end

  defp last_group_sent_at(placement, step_number, channel_id, actor, opts) do
    loader = Keyword.get(opts, :load_last_group_sent_at, &read_last_group_sent_at/4)

    case loader.(placement, step_number, channel_id, actor) do
      {:ok, %{finished_at: %DateTime{} = at}} -> {:ok, at}
      {:ok, _none_or_unfinished} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_group_history_result, other}}
    end
  end

  defp read_last_group_sent_at(placement, step_number, channel_id, actor) do
    route_id = field(placement.route, :id)
    policy_id = field(placement.policy, :id)
    dedupe_key = placement.dedupe_key

    NotificationDelivery
    |> Ash.Query.filter(
      route_id == ^route_id and policy_id == ^policy_id and step_number == ^step_number and
        channel_id == ^channel_id and dedupe_key == ^dedupe_key and state == :sent and
        is_test == false
    )
    |> Ash.Query.sort(finished_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor)
  end

  defp first_step_number(steps) when map_size(steps) > 0, do: steps |> Map.keys() |> Enum.min()

  defp first_step_number(_steps), do: nil

  defp record_withheld(scope, placement, {step_number, channel_id, due_at}, actor) do
    context =
      suppression_context(scope, %{
        route: placement.route,
        policy: placement.policy,
        step: Map.get(placement.steps, step_number),
        channel: Map.get(placement.channels, channel_id),
        dedupe_key: placement.dedupe_key
      })

    outcome =
      {:suppress, :acknowledged,
       %{step_number: step_number, channel_id: channel_id, due_at: due_at}}

    case record_suppression(outcome, context, actor) do
      {:ok, id, notifications} ->
        {:ok, id, notifications}

      {:error, reason} ->
        log_write_failure("record a withheld rung", field(scope.alert, :id), step_number, reason)
        {:error, {:withheld_plan_persistence_failed, reason}}
    end
  end

  defp record_suppression(outcome, context, actor) do
    case Suppression.to_delivery_attributes(outcome, context) do
      {:ok, attrs} ->
        case create_delivery(:record_suppression, drop_absent_execution_route(attrs), actor) do
          {:ok, delivery, notifications} ->
            emit_suppressed(delivery, context, :routing)
            {:ok, delivery.id, notifications}

          {:error, reason} ->
            {:error, reason}
        end

      :allow ->
        {:error, :not_a_suppression}
    end
  end

  # `Suppression.to_delivery_attributes/2` reads `execution_route` off the
  # channel, and an unrouted alert has no channel. The column is NOT NULL with a
  # default, so an explicit nil is REJECTED where an absent key is defaulted -
  # and the reason that matters is that `:no_matching_route` is precisely the
  # decision with no channel, so passing the nil through would make the one
  # suppression an operator most needs to see the one that fails to record.
  # The default is not duplicated here; the key is dropped so the resource's own
  # default stays authoritative.
  defp drop_absent_execution_route(attrs) do
    case Map.get(attrs, :execution_route) do
      nil -> Map.delete(attrs, :execution_route)
      _route -> attrs
    end
  end

  defp create_delivery(action, attrs, actor) do
    NotificationDelivery
    |> Ash.Changeset.for_create(action, attrs, actor: actor)
    |> Ash.create(actor: actor, return_notifications?: true)
  end

  # --- delivery -------------------------------------------------------------

  defp attempt(delivery, channel, provider, now, actor, opts) do
    with {:ok, scope} <- delivery_scope(delivery, channel, provider, now, actor, opts) do
      case Suppression.evaluate(scope.suppression) do
        {:suppress, reason, detail} ->
          suppress_delivery(delivery, channel, reason, detail, now, actor)

        :allow ->
          consume_budget(delivery, channel, provider, scope, now, actor, opts)
      end
    end
  end

  defp suppress_delivery(delivery, channel, reason, detail, now, actor) do
    attrs = %{
      suppression_reason: reason,
      result_summary: %{
        "suppression" => %{
          "reason" => Atom.to_string(reason),
          "evaluated_at" => DateTime.to_iso8601(now),
          "detail" => jsonable(detail)
        }
      }
    }

    case update_delivery(delivery, :record_suppressed, attrs, actor) do
      {:ok, suppressed} ->
        delivery
        |> telemetry_fields(channel)
        |> Map.merge(%{
          suppression_reason: reason,
          occurrence_count: suppressed.occurrence_count,
          phase: :dispatch
        })
        |> Telemetry.suppressed()

        {:ok, :suppressed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Over budget leaves the row untouched: no attempt consumed, no state change,
  # `next_attempt_at` still whatever routing set. That is deliberate - a rate
  # limit is not a failed attempt, and burning `max_attempts` on a busy channel
  # would fail deliveries the destination never even saw.
  defp consume_budget(delivery, channel, provider, scope, now, actor, opts) do
    case RateLimiter.check_and_consume(channel.id, channel.rate_limit_per_minute, now) do
      {:wait, at} -> {:retry, at}
      :ok -> prepare_and_send(delivery, channel, provider, scope, now, actor, opts)
    end
  end

  # The dispatch-attempted signal fires here rather than around the transport
  # call, so it covers the attempts that never reach a transport at all - an
  # unresolvable secret, a provider with no transport module. Those consume an
  # attempt slot and settle exactly like a transport failure, and an
  # "attempted" denominator that excluded them would report a per-channel error
  # rate above one.
  defp prepare_and_send(delivery, channel, provider, scope, now, actor, opts) do
    Telemetry.dispatched(telemetry_fields(delivery, channel))

    case build_request(delivery, channel, provider, scope, opts) do
      {:ok, request, rendered} ->
        send_request(delivery, channel, provider, request, rendered, now, actor, opts)

      {:failed, result} ->
        settle(delivery, channel, result, nil, now, actor, opts)
    end
  end

  defp send_request(delivery, channel, provider, request, rendered, now, actor, opts) do
    # Claim the row before any external side effect. This is both the concurrent
    # worker fence and the crash boundary: a second job now observes
    # `:dispatching` and cannot contact the provider while this attempt owns it.
    # Agent commands additionally preallocate their durable command id, so a
    # crash after bytes leave core can still be reconciled to the exact command.
    command_id = if agent_routed?(channel, provider), do: Ash.UUID.generate()
    request = %{request | command_id: command_id}

    case mark_dispatching(delivery, channel, command_id, actor) do
      {:ok, dispatching} ->
        case invoke_transport(dispatching, channel, provider, request, opts) do
          {:accepted, ^command_id, _summary} ->
            {:ok, :dispatching}

          {:accepted, unexpected_command_id, _summary} ->
            result =
              Result.retryable_failure("agent_command_correlation_mismatch",
                error_message:
                  "the command bus returned a different command id than was reserved",
                result_summary: %{
                  "reserved_command_id" => command_id,
                  "returned_command_id" => unexpected_command_id
                }
              )

            settle(dispatching, channel, result, rendered, now, actor, opts)

          {%Result{} = result, _command_id} ->
            settle(dispatching, channel, result, rendered, now, actor, opts)
        end

      {:error, reason} ->
        {:error, {:dispatch_state_not_persisted, reason}}
    end
  end

  # This transition is the durable claim and therefore MUST precede the
  # transport call. For plugin.run_action the id is preallocated and persisted
  # on both rows before the command bus can transmit bytes.
  defp mark_dispatching(delivery, channel, command_id, actor) do
    attrs = %{
      execution_route: execution_route(channel),
      agent_uid: field(channel, :agent_uid),
      command_id: command_id
    }

    update_delivery(delivery, :record_dispatching, attrs, actor)
  end

  defp settle(delivery, channel, %Result{} = result, rendered, now, actor, opts) do
    attempts_remaining? = delivery.attempt_count + 1 < delivery.max_attempts

    case Result.outcome(result, attempts_remaining?) do
      :sent -> record_sent(delivery, channel, result, rendered, now, actor, opts)
      :retry -> record_retry(delivery, channel, result, now, actor)
      :failed -> record_failed(delivery, channel, result, now, actor, opts)
    end
  end

  defp record_sent(delivery, channel, result, rendered, now, actor, opts) do
    attrs =
      put_rendered(
        %{
          # Retries and resolution updates already carry the provider's
          # correlation id. A successful transport that omits the optional
          # field must not erase it (or replace it with an agent command id).
          external_correlation_id:
            result.external_correlation_id || field(delivery, :external_correlation_id),
          result_summary: jsonable(result.result_summary)
        },
        rendered
      )

    persisted =
      Repo.transaction(fn ->
        case update_delivery_with_notifications(delivery, :record_sent, attrs, actor) do
          {:ok, sent, notifications} ->
            {sent, notifications}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case persisted do
      {:ok, {sent, notifications}} ->
        Ash.Notifier.notify(notifications)
        _ = record_channel_success(channel, actor)

        delivery
        |> telemetry_fields(channel)
        |> Map.put(:dispatch_latency_ms, dispatch_latency_ms(delivery, now))
        |> Telemetry.sent()

        # The provider side effect has already succeeded, so a close-out queue
        # outage must never roll the row back to `:dispatching` and invite a
        # duplicate send. Report the repair failure while keeping `:sent` true.
        case ensure_late_resolution_routed(sent, actor, opts) do
          :ok -> {:ok, :sent}
          {:error, reason} -> {:error, {:sent_but_resolution_unrouted, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_late_resolution_routed(
         %{lifecycle_reason: reason, is_test: false, alert_id: alert_id},
         actor,
         opts
       )
       when reason != :resolve and is_binary(alert_id) do
    case load_alert(alert_id, actor) do
      {:ok, %{status: :resolved}} ->
        enqueue = Keyword.get(opts, :enqueue_routing, &RoutingWorker.enqueue/2)

        case enqueue.(alert_id, :resolve) do
          :ok -> :ok
          {:ok, _job} -> :ok
          {:error, reason} -> recover_late_resolution(alert_id, actor, opts, reason)
          other -> recover_late_resolution(alert_id, actor, opts, other)
        end

      _not_resolved_or_gone ->
        :ok
    end
  end

  defp ensure_late_resolution_routed(_delivery, _actor, _opts), do: :ok

  defp recover_late_resolution(alert_id, actor, opts, enqueue_reason) do
    route_opts = [actor: actor, now: fetch_now(opts)]
    router = Keyword.get(opts, :route_resolution, &route/3)

    case router.(alert_id, :resolve, route_opts) do
      {:ok, _result} ->
        :ok

      {:error, route_reason} ->
        {:error,
         {:resolution_enqueue_failed, enqueue_reason,
          {:synchronous_resolution_failed, route_reason}}}
    end
  end

  defp record_retry(delivery, channel, result, now, actor) do
    delay_ms = backoff_ms(delivery.attempt_count + 1, result.retry_after_ms, rand_source())
    next_attempt_at = DateTime.add(now, delay_ms, :millisecond)

    attrs = %{
      next_attempt_at: next_attempt_at,
      error_class: result.error_class,
      error_message: result.error_message,
      result_summary: jsonable(result.result_summary)
    }

    case update_delivery(delivery, :record_retry_scheduled, attrs, actor) do
      {:ok, _delivery} ->
        delivery
        |> telemetry_fields(channel)
        |> Map.merge(%{error_class: result.error_class, delay_ms: delay_ms})
        |> Telemetry.retried()

        {:retry, next_attempt_at}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_failed(delivery, channel, result, now, actor, opts) do
    attrs = %{
      error_class: result.error_class,
      error_message: result.error_message,
      result_summary: jsonable(result.result_summary),
      external_correlation_id: result.external_correlation_id
    }

    case persist_failure_and_failover(delivery, channel, attrs, now, actor, opts) do
      {:ok, failed, failover} ->
        _ = record_channel_failure(channel, result, actor)

        delivery
        |> telemetry_fields(channel)
        |> Map.put(:error_class, result.error_class)
        |> Telemetry.failed()

        notify_failover(failed, channel, failover)
        {:error, {:delivery_failed, result.error_class}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Exactly one hop (design D4/G6). A delivery that already carries
  # `originating_delivery_id` is itself the hop, so it never takes another - the
  # bound has to live here, because the successor is an ordinary delivery in
  # every other respect and nothing downstream could tell the difference.
  defp persist_failure_and_failover(delivery, channel, attrs, now, actor, opts) do
    if failover_eligible?(delivery, channel) do
      case Repo.transaction(fn ->
             case update_delivery_with_notifications(
                    delivery,
                    :record_failed,
                    attrs,
                    actor
                  ) do
               {:ok, failed, failed_notifications} ->
                 case do_failover(failed, channel, now, actor, opts) do
                   {:ok, failover} ->
                     {failed, failover,
                      failed_notifications ++ Map.fetch!(failover, :notifications)}

                   :skip ->
                     {failed, nil, failed_notifications}

                   {:error, reason} ->
                     Repo.rollback({:failover_persistence_failed, reason})
                 end

               {:error, reason} ->
                 Repo.rollback(reason)
             end
           end) do
        {:ok, {failed, failover, notifications}} ->
          Ash.Notifier.notify(notifications)
          {:ok, failed, drop_notifications(failover)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      case update_delivery_with_notifications(delivery, :record_failed, attrs, actor) do
        {:ok, failed, notifications} ->
          Ash.Notifier.notify(notifications)
          {:ok, failed, nil}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp failover_eligible?(delivery, channel) do
    not delivery.is_test and not is_nil(channel) and not channel.fail_closed and
      not is_nil(channel.fallback_channel_id) and
      is_nil(delivery.originating_delivery_id)
  end

  defp do_failover(delivery, channel, now, actor, opts) do
    case load_channel(channel.fallback_channel_id, actor) do
      {:ok, fallback} ->
        attrs = %{
          alert_id: delivery.alert_id,
          alert_snapshot: delivery.alert_snapshot,
          route_id: delivery.route_id,
          policy_id: delivery.policy_id,
          step_number: delivery.step_number,
          channel_id: fallback.id,
          originating_delivery_id: delivery.id,
          dedupe_key: delivery.dedupe_key,
          max_attempts: max_attempts(fallback),
          execution_route: execution_route(fallback),
          agent_uid: field(fallback, :agent_uid),
          payload_format: negotiated_format(nil, fallback.provider),
          provider_version: field(fallback.provider, :definition_version),
          queued_at: now,
          next_attempt_at: now,
          # A failover of a resolve notice is still a resolve notice. Dropping it
          # here would make the second attempt tell PagerDuty to trigger.
          lifecycle_reason: delivery.lifecycle_reason
        }

        create = Keyword.get(opts, :create_failover_delivery, &create_delivery/3)

        case create.(:record_dispatch, attrs, actor) do
          {:ok, successor, notifications} ->
            {:ok, %{successor: successor, fallback: fallback, notifications: notifications}}

          {:error, reason} ->
            log_write_failure(
              "fail over a delivery",
              delivery.alert_id,
              delivery.step_number,
              reason
            )

            {:error, reason}
        end

      {:error, :channel_not_found} ->
        :skip

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp notify_failover(_delivery, _channel, nil), do: :ok

  defp notify_failover(delivery, channel, %{successor: successor, fallback: fallback}) do
    Logger.info("notification delivery failed over",
      delivery_id: delivery.id,
      failover_delivery_id: successor.id
    )

    Telemetry.failed_over(%{
      alert_id: delivery.alert_id,
      delivery_id: delivery.id,
      successor_delivery_id: successor.id,
      channel_id: channel.id,
      fallback_channel_id: fallback.id,
      step_number: delivery.step_number
    })
  end

  defp update_delivery(delivery, action, attrs, actor) do
    delivery
    |> Ash.Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp update_delivery_with_notifications(delivery, action, attrs, actor) do
    delivery
    |> Ash.Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update(actor: actor, return_notifications?: true)
  end

  defp drop_notifications(nil), do: nil
  defp drop_notifications(failover), do: Map.delete(failover, :notifications)

  defp record_channel_success(nil, _actor), do: :ok

  defp record_channel_success(channel, actor) do
    channel
    |> Ash.Changeset.for_update(:record_success, %{}, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp record_channel_failure(nil, _result, _actor), do: :ok

  defp record_channel_failure(channel, result, actor) do
    channel
    |> Ash.Changeset.for_update(:record_failure, %{last_error: result.error_class}, actor: actor)
    |> Ash.update(actor: actor)
  end

  # --- transport ------------------------------------------------------------

  # Two things send a delivery to an agent, and they are not the same thing.
  #
  # `:edge_agent` is the operator's choice of egress: the notification must
  # leave from the customer's own network (design R1), so it goes to the site
  # agent named on the channel.
  #
  # A `:wasm_plugin` provider goes to an agent whatever its route, because the
  # ONLY Wasm host in the product is wazero inside `go/pkg/agent`. On
  # `:control_plane` the host is the platform-resident `serviceradar-agent` that
  # already ships (design D3, tasks 3.3.1), reached through the SAME
  # `plugin.run_action` command as any edge dispatch - which is what lets one
  # plugin binary serve both routes and is why core never needed a second host.
  defp invoke_transport(delivery, channel, provider, request, opts) do
    if agent_routed?(channel, provider) do
      edge_dispatch(request, channel, provider, opts)
    else
      {local_dispatch(delivery, provider, request, opts), nil}
    end
  end

  defp agent_routed?(channel, provider) do
    execution_route(channel) == :edge_agent or
      field(provider, :provider_type) == :wasm_plugin
  end

  defp local_dispatch(delivery, provider, request, opts) do
    case resolve_transport(provider, opts) do
      {:ok, module} ->
        if delivery.is_test do
          module.test(request, transport_opts(opts))
        else
          module.deliver(request, transport_opts(opts))
        end

      {:error, message} ->
        Result.permanent_failure("transport_unavailable", error_message: message)
    end
  end

  # Design D2: this is the ONE place a channel's provider tier is consulted.
  # Nothing downstream - routing, escalation, suppression, acknowledgement, or
  # the delivery record - may branch on `provider_type` again.
  defp resolve_transport(provider, opts) do
    case Keyword.get(opts, :transport) do
      module when is_atom(module) and not is_nil(module) -> {:ok, module}
      _none -> resolve_provider_transport(provider)
    end
  end

  defp resolve_provider_transport(%{provider_type: :stream}) do
    {:ok, Transports.Stream}
  end

  defp resolve_provider_transport(%{provider_type: :native} = provider) do
    case Transports.Registry.resolve(provider.implementation_module) do
      {:ok, module} -> {:ok, module}
      {:error, reason} -> {:error, Transports.Registry.describe_error(reason)}
    end
  end

  # There is one declarative engine for every uploaded and seeded document, which
  # is exactly why the tier needs no code per provider: the document travels on
  # the request (see `request/6`), not in a module lookup.
  defp resolve_provider_transport(%{provider_type: :declarative}) do
    {:ok, Transports.Declarative}
  end

  # A `:wasm_plugin` provider never resolves to a module here: it is dispatched
  # to an agent by `invoke_transport/5` before this is reached, on both routes
  # (tasks 3.3.1). Reaching this clause means the `:transport` seam was not
  # supplied and the tier has no in-process transport, which is a programming
  # error rather than a configuration one, so it says so.
  defp resolve_provider_transport(%{provider_type: :wasm_plugin}) do
    {:error,
     "a :wasm_plugin provider executes on an agent through plugin.run_action, " <>
       "never through an in-process transport"}
  end

  defp resolve_provider_transport(%{provider_type: type}) do
    {:error, "provider tier #{inspect(type)} has no transport"}
  end

  defp resolve_provider_transport(_provider), do: {:error, "the channel has no provider"}

  # Design R2 / forgejo #4902. `AgentCommandBus.dispatch/4` is at-most-once with
  # no store-and-forward, so every TRANSPORT failure here is retryable and the
  # delivery row is the outbox. Failing over on the first offline reply would
  # abandon a site that was briefly disconnected; the retry budget, and only
  # then failover, is the bound.
  #
  # Target resolution failures are the exception and are PERMANENT: an
  # unapproved package, a missing assignment, or an unconfigured platform agent
  # is a configuration error that no retry fixes, and the useful response is to
  # fail over to a channel that can actually page. See
  # `ServiceRadar.Notifications.PluginTarget`.
  #
  # No resolved secret material crosses this boundary. The rendered payload and
  # signed action links must reach the notifier so it can send them, while
  # channel credentials remain opaque refs resolved by host-side
  # `CredentialBrokerGrant` injection and never enter guest memory.
  defp edge_dispatch(request, channel, provider, opts) do
    with {:ok, target} <- resolve_plugin_target(channel, provider, opts),
         {:ok, prepared} <- prepare_plugin_credentials(channel, target, request, opts) do
      dispatch_command(request, provider, target, prepared, opts)
    else
      {:error, {error_class, message}} when is_binary(error_class) and is_binary(message) ->
        {Result.permanent_failure(error_class,
           error_message: message,
           result_summary: %{
             "execution_route" => to_string(execution_route(channel)),
             "reason" => error_class
           }
         ), nil}

      {:error, reason} ->
        {credential_failure(reason, channel), nil}
    end
  end

  defp prepare_plugin_credentials(channel, target, request, opts) do
    preparer = Keyword.get(opts, :plugin_credential_grants, PluginCredentialGrants)

    preparer.prepare(
      channel,
      target,
      [delivery_id: request.delivery_id] ++
        Keyword.take(opts, [:actor, :grant_issuer, :grant_revoker])
    )
  end

  defp credential_failure({:notification_grant_issue_failed, _name, reason}, channel) do
    Result.retryable_failure("notification_credential_grant_unavailable",
      error_message: "could not issue a host credential grant: #{inspect(reason)}",
      result_summary: %{
        "execution_route" => to_string(execution_route(channel)),
        "reason" => "notification_credential_grant_unavailable"
      }
    )
  end

  defp credential_failure(reason, channel) do
    Result.permanent_failure("notification_credential_invalid",
      error_message: "the plugin notification credential contract is invalid: #{inspect(reason)}",
      result_summary: %{
        "execution_route" => to_string(execution_route(channel)),
        "reason" => "notification_credential_invalid"
      }
    )
  end

  defp resolve_plugin_target(channel, provider, opts) do
    resolver = Keyword.get(opts, :plugin_target, PluginTarget)

    resolver.resolve(
      channel,
      provider,
      Keyword.take(opts, [:platform_agent, :load_package, :load_assignment])
    )
  end

  defp dispatch_command(request, provider, target, prepared, opts) do
    bus = Keyword.get(opts, :command_bus, AgentCommandBus)
    route = to_string(target.execution_route)

    payload =
      %{
        "schema" => @edge_command_schema,
        # Both addressing fields are sent, and the agent prefers the exact one.
        # `plugin_assignment_id` is the address that matters: the assignment, not
        # the package, carries the narrowed capability set, the config, and the
        # resource limits the module runs under. `plugin_package_id` is the
        # fallback the agent resolves when no assignment id is supplied, and it
        # fails CLOSED when one package has several assignments on that agent -
        # two assignments of one package are two channel configurations, so
        # picking either would deliver to the wrong destination and record it as
        # sent (`go/pkg/agent/plugin_runtime_notify.go`,
        # `resolveNotificationAssignmentID`).
        "plugin_assignment_id" => target.plugin_assignment_id,
        "plugin_package_id" => target.plugin_package_id,
        "action_key" => field(provider, :action_key),
        "entrypoint" => target.notification_entrypoint,
        "provider_key" => field(provider, :provider_key),
        "intent" => plugin_intent(request, target),
        "execution_route" => route,
        "channel_id" => request.channel_id,
        "delivery_id" => request.delivery_id,
        "alert_id" => request.alert_id,
        "route_id" => request.route_id,
        "policy_id" => request.policy_id,
        "step_number" => request.step_number,
        "payload_format" => to_string(request.payload_format),
        "rendered_payload" => request.payload,
        "alert_snapshot" => request.alert_snapshot,
        "channel_config" => prepared.channel_config,
        "attempt_count" => request.attempt,
        "max_attempts" => request.max_attempts,
        "queued_at" => iso8601(request.queued_at),
        "started_at" => iso8601(request.started_at),
        "next_attempt_at" => iso8601(request.next_attempt_at),
        "agent_uid" => target.agent_uid,
        "command_id" => request.command_id,
        "external_correlation_id" => request.external_correlation_id,
        "action_links" => request.action_links,
        "dedupe_key" => request.dedupe_key,
        "is_test" => request.is_test
      }
      |> Map.merge(prepared.payload_fields)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case bus.dispatch(target.agent_uid, @edge_command_type, payload,
           required_partition: target.partition_id,
           source: :automation,
           command_id: request.command_id,
           notification_delivery_attempt: true,
           context: %{
             notification_delivery_id: request.delivery_id,
             notification_channel_id: request.channel_id,
             plugin_assignment_id: target.plugin_assignment_id,
             credential_broker_grant_ids:
               Map.get(prepared.context, :credential_broker_grant_ids, [])
           }
         ) do
      {:ok, command_id} ->
        {:accepted, command_id,
         %{
           "execution_route" => route,
           "agent_uid" => target.agent_uid,
           "command_id" => command_id
         }}

      {:error, {:agent_offline, _agent} = reason} ->
        {Result.retryable_failure("agent_offline",
           error_message: "the agent has no control session; the delivery row is the outbox",
           result_summary: %{
             "execution_route" => route,
             "agent_uid" => target.agent_uid,
             "reason" => inspect(reason)
           }
         ), nil}

      {:error, reason} ->
        {Result.retryable_failure("agent_command_failed",
           error_message: "the agent command could not be dispatched: #{inspect(reason)}",
           result_summary: %{
             "execution_route" => route,
             "agent_uid" => target.agent_uid,
             "reason" => inspect(reason)
           }
         ), nil}
    end
  end

  defp plugin_intent(%Request{is_test: true}, _target), do: "test"

  defp plugin_intent(%Request{lifecycle_reason: :resolve}, target) do
    if "resolve_update" in Map.get(target, :notification_capabilities, []),
      do: "resolve_update",
      else: "send"
  end

  defp plugin_intent(_request, _target), do: "send"

  defp transport_opts(opts), do: Keyword.get(opts, :transport_opts, [])

  # --- request construction -------------------------------------------------

  defp build_request(delivery, channel, provider, scope, opts) do
    with {:ok, secrets} <- resolve_request_secrets(channel, provider),
         {:ok, format} <- negotiate(delivery, provider),
         {:ok, rendered, context} <- render(delivery, provider, scope, format, opts) do
      {:ok, request(delivery, channel, provider, rendered, secrets, scope, context), rendered}
    end
  end

  defp request(delivery, channel, provider, rendered, secrets, scope, context) do
    %Request{
      delivery_id: delivery.id,
      alert_id: delivery.alert_id,
      route_id: delivery.route_id,
      policy_id: delivery.policy_id,
      step_number: delivery.step_number,
      channel_id: channel.id,
      provider_key: provider.provider_key,
      provider_version: provider.definition_version,
      lifecycle_reason: delivery.lifecycle_reason,
      alert_snapshot: delivery.alert_snapshot || %{},
      payload_format: rendered.payload_format,
      payload: rendered.payload,
      subject: rendered.subject,
      body: rendered.body,
      dedupe_key: delivery.dedupe_key,
      external_correlation_id: delivery.external_correlation_id,
      agent_uid: channel.agent_uid,
      partition_id: channel.partition_id,
      queued_at: delivery.queued_at,
      started_at: delivery.started_at || scope.now,
      next_attempt_at: delivery.next_attempt_at,
      command_id: delivery.command_id,
      config: channel.config || %{},
      secrets: secrets,
      action_links: Map.get(context, "action_links", %{}),
      execution_route: execution_route(channel),
      attempt: delivery.attempt_count + 1,
      max_attempts: delivery.max_attempts,
      is_test: delivery.is_test,
      metadata: %{
        "redacted_payload" => rendered.redacted_payload,
        "rendered_payload_digest" => rendered.digest,
        # A transport that renders templates of its own carries them in the
        # provider document, and its `{{ alert.* }}` paths must resolve to the
        # values the notification body was just rendered against - otherwise a
        # declarative request template renders empty beside a correct body. This
        # is data the transport may use, not a decision: no module in the
        # dispatch path branches on `provider_type` to decide whether to set it,
        # and a transport that has no templates ignores it.
        "definition" => field(provider, :definition),
        "template_context" => context
      }
    }
  end

  defp resolve_request_secrets(channel, provider) do
    if agent_routed?(channel, provider), do: {:ok, %{}}, else: resolve_secrets(channel, provider)
  end

  # A credential store that is briefly unreachable is the common case, and losing
  # a page to a transient OpenBao blip is worse than spending a bounded retry
  # budget on a credential that really is gone - the same call the native
  # transports make for the same reason.
  defp resolve_secrets(channel, provider) do
    schema = field(provider, :config_schema) || %{}
    refs = channel.secret_refs || %{}

    case SecretRefs.resolve_runtime_params(schema, refs) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, errors} ->
        {:failed,
         Result.retryable_failure("secret_unavailable",
           error_message: "channel credentials could not be resolved: #{format_errors(errors)}"
         )}
    end
  end

  # Interactive mode is opt-in per channel and defaults OFF. A Slack app with no
  # Interactivity Request URL configured renders buttons that produce no request
  # and no log when clicked, and there is no API that detects that - so defaulting
  # this on would turn a missing install step into silently inert buttons.
  defp interactive_channel?(channel) do
    case field(channel, :config) do
      config when is_map(config) -> Map.get(config, "interactive") == true
      _other -> false
    end
  end

  defp negotiate(delivery, provider) do
    case Renderer.negotiate_format(delivery.payload_format, field(provider, :payload_formats)) do
      {:ok, format} ->
        {:ok, format}

      {:error, reason} ->
        {:failed,
         Result.permanent_failure("payload_format_unsupported",
           error_message: Renderer.describe_error(reason)
         )}
    end
  end

  defp render(delivery, provider, scope, format, opts) do
    template = resolve_template(delivery, provider, format, scope.actor)

    with {:ok, links} <- issue_action_links(delivery, provider, scope, opts) do
      context = render_context(delivery, scope, opts)

      render_opts =
        [
          supported_formats: field(provider, :payload_formats),
          context: context,
          dedupe_key: delivery.dedupe_key,
          provider_version: field(provider, :definition_version),
          # An interactive control binds to a delivery, not to a URL, so the
          # renderer needs the delivery id the Phase 1 link would have carried in
          # its token. Without it `Content.action_controls/1` returns [] rather
          # than minting a control bound to an alert alone.
          delivery_id: field(delivery, :id),
          event_action: event_action(field(delivery, :lifecycle_reason)),
          interactive?: interactive_channel?(scope.channel),
          # ActionRedaction matches on KEY names, and a capability token sits
          # inside a `url` VALUE where there is no sensitive key to match. Without
          # this second value-based pass the plaintext token survives into
          # `rendered.redacted_payload`, which is the form persisted and shown in
          # the Delivery Log - a live capability sitting in the audit trail.
          sensitive_values: ActionLinks.sensitive_values(links)
        ] ++ ActionLinks.to_renderer_opts(links)

      case Renderer.render(delivery.alert_snapshot || %{}, template, format, render_opts) do
        {:ok, rendered} ->
          {:ok, rendered, template_context(context, delivery, links)}

        {:error, reason} ->
          {:failed,
           Result.permanent_failure("render_failed",
             error_message: Renderer.describe_error(reason)
           )}
      end
    end
  end

  # The variable context the body was rendered against, for a transport that has
  # templates of its own. `links.links` is already the effective set - an exempt
  # destination mints nothing and therefore has no action link to carry - so the
  # `:stream` exemption cannot be reintroduced by handing it on.
  defp template_context(context, delivery, links) do
    snapshot = delivery.alert_snapshot || %{}

    context
    |> Map.put("alert", snapshot)
    |> Map.put("snapshot", snapshot)
    |> Map.put("links", links.links)
    |> Map.put("action_links", sdk_action_links(links))
  end

  defp sdk_action_links(%ActionLinks{} = links) do
    Map.new(links.links, fn {action, url} ->
      minted = Enum.find(links.minted, &(to_string(&1.action) == action))

      {action,
       %{
         "url" => url,
         "label" => action_link_label(action),
         "expires_at" => minted && iso8601(minted.expires_at)
       }
       |> Enum.reject(fn {_key, value} -> is_nil(value) end)
       |> Map.new()}
    end)
  end

  defp action_link_label("acknowledge"), do: "Acknowledge"
  defp action_link_label("snooze"), do: "Snooze 1h"
  defp action_link_label("resolve"), do: "Resolve"
  defp action_link_label("alert"), do: "View alert"
  defp action_link_label(action), do: action

  # Mints the acknowledge/snooze/resolve capabilities for this delivery and
  # persists them (sha256 only). `ActionLinks` decides eligibility from an
  # ALLOWLIST of provider types, so a `:stream` channel - and any provider type
  # added later that nobody remembers to exclude - mints nothing and reaches the
  # token table not at all. A caller may pre-supply `opts[:links]` (tests do);
  # in that case nothing new is minted.
  defp issue_action_links(delivery, provider, scope, opts) do
    case Keyword.fetch(opts, :links) do
      {:ok, %ActionLinks{} = links} ->
        {:ok, links}

      {:ok, _other} ->
        # A bare map of links carries no minted capabilities, so there is
        # nothing to persist and nothing sensitive to scrub.
        {:ok, %ActionLinks{}}

      :error ->
        case ActionLinks.issue(delivery, provider, actor: scope.actor) do
          {:ok, links} ->
            {:ok, links}

          {:error, reason} ->
            # A capability that cannot be persisted must not be rendered into a
            # notification: the recipient would get a link that verifies against
            # nothing. Retryable, because the usual cause is a transient write
            # failure rather than a bad delivery.
            {:failed,
             Result.retryable_failure("action_link_mint_failed",
               error_message: "could not issue notification action links: #{inspect(reason)}"
             )}
        end
    end
  end

  defp resolve_template(delivery, provider, format, actor) do
    alert_class = snapshot_field(delivery.alert_snapshot, "alert_class") || "default"
    provider_key = field(provider, :provider_key)

    resolved =
      find_template(alert_class, format, provider_key, actor) ||
        find_template("default", format, provider_key, actor)

    resolved || @fallback_template
  end

  defp find_template(alert_class, format, provider_key, actor) do
    NotificationTemplate
    |> Ash.Query.for_read(:resolve, %{
      alert_class: alert_class,
      payload_format: format,
      provider_key: provider_key
    })
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, template} -> template
      {:error, _reason} -> nil
    end
  end

  defp render_context(delivery, scope, opts) do
    base = %{
      "device" => namespace(scope.device, [:id, :uid, :hostname, :ip, :mac, :is_active]),
      "rule" => namespace(scope.rule, [:id, :name, :description]),
      "route" => namespace(scope.route, [:id, :name, :priority]),
      "policy" => namespace(scope.policy, [:id, :name]),
      "step" => step_namespace(scope.step),
      "channel" => namespace(scope.channel, [:id, :name, :execution_route]),
      "provider" => provider_namespace(scope.provider),
      "delivery" => delivery_namespace(delivery),
      "system" => %{"now" => DateTime.to_iso8601(scope.now)}
    }

    Map.merge(base, stringify_keys(Keyword.get(opts, :render_context, %{})))
  end

  defp step_namespace(nil), do: %{}

  defp step_namespace(step) do
    %{
      "number" => field(step, :step_number),
      "delay_seconds" => field(step, :delay_seconds),
      "condition" => to_string(field(step, :condition))
    }
  end

  defp provider_namespace(nil), do: %{}

  defp provider_namespace(provider) do
    %{
      "key" => field(provider, :provider_key),
      "display_name" => field(provider, :display_name)
    }
  end

  defp delivery_namespace(delivery) do
    %{
      "id" => delivery.id,
      "state" => to_string(delivery.state),
      "attempt_count" => delivery.attempt_count,
      "max_attempts" => delivery.max_attempts,
      "occurrence_count" => delivery.occurrence_count,
      "dedupe_key" => delivery.dedupe_key,
      "payload_format" => to_string(delivery.payload_format),
      "external_correlation_id" => delivery.external_correlation_id,
      "queued_at" => iso8601(delivery.queued_at),
      "started_at" => iso8601(delivery.started_at),
      "finished_at" => iso8601(delivery.finished_at),
      "lifecycle_reason" => to_string(delivery.lifecycle_reason || ""),
      "event_action" => to_string(event_action(delivery.lifecycle_reason))
    }
  end

  @doc """
  The action an incident API is told to take, derived from the lifecycle reason.

  Public so a renderer and a declarative document agree on one mapping. It has to
  be derived rather than written in a template: templates are restricted
  substitution with no conditionals, so `:renotify -> :trigger` cannot be
  expressed as a document expression.

  Everything that is not a resolution is a trigger, including `nil`. Rows written
  before `lifecycle_reason` existed therefore render exactly as they did before,
  and a reason added later without thought fails safe toward "open an incident"
  rather than toward "close one".
  """
  @spec event_action(atom()) :: :trigger | :resolve
  def event_action(:resolve), do: :resolve
  def event_action(_reason), do: :trigger

  defp namespace(nil, _keys), do: %{}

  defp namespace(record, keys) do
    Map.new(keys, fn key -> {Atom.to_string(key), jsonable(field(record, key))} end)
  end

  # --- due scans ------------------------------------------------------------

  defp due_retry(now, limit, actor, _opts), do: retry_due_ids(now, limit, actor)

  defp retry_due_ids(now, limit, actor) do
    NotificationDelivery
    |> Ash.Query.for_read(:retry_due, %{now: now})
    |> Ash.Query.limit(limit)
    |> Ash.read(actor: actor)
    |> ids("retry-due deliveries")
  end

  # D8: continuation only. The relationship predicate is intentionally inside
  # the database query and therefore runs before LIMIT. Filtering a page of the
  # oldest alerts in Elixir lets old, never-routed alerts permanently hide real
  # continuation work behind them.
  defp due_escalation(limit, actor) do
    Alert
    |> Ash.Query.filter(
      status in [:pending, :escalated, :acknowledged] and
        exists(notification_deliveries, is_test == false and not is_nil(queued_at))
    )
    |> Ash.Query.sort(triggered_at: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read(actor: actor)
    |> ids("escalation candidate alerts")
  end

  # Renotify cadence is owned by the stateful rule, not copied into a second
  # notification setting. The output is bounded after cadence evaluation so a
  # page of not-yet-due incidents cannot starve due ones behind it.
  defp due_renotify(now, limit, actor) do
    Alert
    |> Ash.Query.filter(
      status in [:pending, :escalated] and not is_nil(last_notification_at) and
        (is_nil(suppressed_until) or suppressed_until < ^now) and
        (is_nil(snooze_until) or snooze_until < ^now) and
        exists(notification_deliveries, is_test == false and not is_nil(queued_at))
    )
    |> Ash.Query.sort(last_notification_at: :asc)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, alerts} ->
        alerts
        |> Enum.filter(&renotify_due?(&1, now, actor))
        |> Enum.take(limit)
        |> Enum.map(& &1.id)

      {:error, reason} ->
        log_read_failure("renotify candidate alerts", reason)
        []
    end
  end

  defp renotify_due?(alert, now, actor) do
    case load_rule(alert, actor) do
      {:ok, %{renotify_seconds: seconds}} when is_integer(seconds) and seconds > 0 ->
        Dedupe.renotify_due?(alert.last_notification_at, seconds, now)

      _no_rule_or_disabled_cadence ->
        false
    end
  end

  defp ids({:ok, records}, _what), do: Enum.map(records, & &1.id)

  defp ids({:error, reason}, what) do
    log_read_failure(what, reason)
    []
  end

  defp log_read_failure(what, reason) do
    Logger.error("notification dispatcher could not read #{what}", reason: inspect(reason))
    :ok
  end

  # --- loading --------------------------------------------------------------

  defp load_alert(alert_id, actor), do: load_alert(alert_id, actor, [])

  defp load_alert(alert_id, actor, opts) do
    loader = Keyword.get(opts, :load_alert, &read_alert/2)

    case loader.(alert_id, actor) do
      {:ok, nil} -> {:error, :alert_not_found}
      {:ok, alert} when is_map(alert) -> {:ok, alert}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_alert_loader_result, other}}
    end
  end

  defp read_alert(alert_id, actor) do
    Alert
    |> Ash.Query.for_read(:by_id, %{id: alert_id})
    |> Ash.Query.load([:device])
    |> Ash.read_one(actor: actor)
  end

  defp load_enabled_routes(actor, opts) do
    loader = Keyword.get(opts, :load_enabled_routes, &read_enabled_routes/1)

    case loader.(actor) do
      {:ok, routes} when is_list(routes) ->
        {:ok, routes}

      {:error, reason} ->
        log_read_failure("enabled routes", reason)
        {:error, {:enabled_routes_unreadable, reason}}

      other ->
        {:error, {:enabled_routes_unreadable, {:invalid_loader_result, other}}}
    end
  end

  defp read_enabled_routes(actor) do
    NotificationRoute
    |> Ash.Query.for_read(:enabled)
    |> Ash.Query.load([:schedule])
    |> Ash.read(actor: actor)
  end

  defp load_policy(nil, _actor, _opts), do: {:error, :escalation_policy_not_configured}

  defp load_policy(policy_id, actor, opts) do
    loader = Keyword.get(opts, :load_policy, &load_policy_record/2)
    loader.(policy_id, actor)
  end

  defp load_policy_record(policy_id, actor) do
    NotificationEscalationPolicy
    |> Ash.Query.for_read(:by_id, %{id: policy_id})
    |> Ash.Query.load(steps: [channels: [:provider]])
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} ->
        {:error, {:escalation_policy_not_found, policy_id}}

      {:ok, policy} ->
        {:ok, policy}

      {:error, reason} ->
        log_read_failure("escalation policy #{policy_id}", reason)
        {:error, {:escalation_policy_unreadable, policy_id, reason}}
    end
  end

  defp load_active_silences(now, actor, opts) do
    loader = Keyword.get(opts, :load_active_silences, &read_active_silences/2)

    case loader.(now, actor) do
      {:ok, silences} when is_list(silences) ->
        {:ok, silences}

      {:error, reason} ->
        log_read_failure("active silences", reason)
        {:error, {:active_silences_unreadable, reason}}

      other ->
        {:error, {:active_silences_unreadable, {:invalid_loader_result, other}}}
    end
  end

  defp read_active_silences(now, actor) do
    NotificationSilence
    |> Ash.Query.for_read(:active_at, %{at: now})
    |> Ash.read(actor: actor)
  end

  # The rule is optional context: it supplies the cadence floor and the `rule.*`
  # render namespace. An alert created by a path that bypasses the stateful
  # engine has none, and that is a valid state rather than an error.
  defp load_rule(alert, actor), do: load_rule(alert, actor, [])

  defp load_rule(alert, actor, opts) do
    loader = Keyword.get(opts, :load_rule, &read_rule/2)

    case loader.(alert, actor) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, rule} when is_map(rule) ->
        {:ok, rule}

      {:error, reason} ->
        rule_id = incident_rule_id(alert)
        log_read_failure("stateful alert rule #{inspect(rule_id)}", reason)
        {:error, {:alert_rule_unreadable, rule_id, reason}}

      other ->
        {:error,
         {:alert_rule_unreadable, incident_rule_id(alert), {:invalid_loader_result, other}}}
    end
  end

  defp read_rule(alert, actor) do
    case incident_rule_id(alert) do
      nil ->
        {:ok, nil}

      rule_id ->
        StatefulAlertRule
        |> Ash.Query.filter(id == ^rule_id)
        |> Ash.Query.limit(1)
        |> Ash.read_one(actor: actor)
    end
  end

  defp load_delivery(delivery_id, actor, opts) do
    loader = Keyword.get(opts, :load_delivery, &read_delivery/2)

    case loader.(delivery_id, actor) do
      {:ok, nil} -> {:error, :delivery_not_found}
      {:ok, delivery} when is_map(delivery) -> {:ok, delivery}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_delivery_loader_result, other}}
    end
  end

  defp read_delivery(delivery_id, actor) do
    NotificationDelivery
    |> Ash.Query.for_read(:by_id, %{id: delivery_id})
    |> Ash.Query.load(channel: [:provider])
    |> Ash.read_one(actor: actor)
  end

  defp load_channel(nil, _actor), do: {:error, :channel_not_found}

  defp load_channel(channel_id, actor) do
    NotificationChannel
    |> Ash.Query.for_read(:by_id, %{id: channel_id})
    |> Ash.Query.load([:provider])
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :channel_not_found}
      {:ok, channel} -> {:ok, channel}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_route(nil, _actor, _opts), do: {:ok, nil}

  defp load_route(route_id, actor, opts) do
    loader = Keyword.get(opts, :load_route, &read_route/2)

    case loader.(route_id, actor) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, route} when is_map(route) ->
        {:ok, route}

      {:error, reason} ->
        log_read_failure("notification route #{route_id}", reason)
        {:error, {:notification_route_unreadable, route_id, reason}}

      other ->
        {:error, {:notification_route_unreadable, route_id, {:invalid_loader_result, other}}}
    end
  end

  defp read_route(route_id, actor) do
    NotificationRoute
    |> Ash.Query.for_read(:by_id, %{id: route_id})
    |> Ash.Query.load([:schedule])
    |> Ash.read_one(actor: actor)
  end

  defp load_step(nil, _step_number, _actor, _opts), do: {:ok, nil}
  defp load_step(_policy_id, nil, _actor, _opts), do: {:ok, nil}

  defp load_step(policy_id, step_number, actor, opts) do
    loader = Keyword.get(opts, :load_step, &read_step/3)

    case loader.(policy_id, step_number, actor) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, step} when is_map(step) ->
        {:ok, step}

      {:error, reason} ->
        log_read_failure("escalation step #{policy_id}/#{step_number}", reason)
        {:error, {:escalation_step_unreadable, policy_id, step_number, reason}}

      other ->
        {:error,
         {:escalation_step_unreadable, policy_id, step_number, {:invalid_loader_result, other}}}
    end
  end

  defp read_step(policy_id, step_number, actor) do
    NotificationEscalationStep
    |> Ash.Query.for_read(:by_policy_step, %{policy_id: policy_id, step_number: step_number})
    |> Ash.read_one(actor: actor)
  end

  # The dispatches this dedupe key has already produced, as the
  # `{step_number, channel_id, due_at}` tuples `Escalation.plan/1` excludes.
  # `queued_at` is where `due_at` was stored, which is why routing writes the
  # OWED instant there rather than the wall clock.
  #
  # A read failure ABORTS the routing pass rather than degrading to "exclude
  # nothing". Both `nil` and `[]` mean "exclude nothing" to `plan/1`, so a
  # swallowed error here would re-create every dispatch the ladder has ever
  # made - the exact duplicate-page failure the exclusion exists to prevent.
  # Nothing has been written yet at this point, so returning an error is free
  # and the caller simply comes back.
  defp existing_dispatches(alert, route, key, actor) do
    id = field(alert, :id)
    route_id = field(route, :id)

    direct_query =
      NotificationDelivery
      |> Ash.Query.filter(
        alert_id == ^id and route_id == ^route_id and dedupe_key == ^key and
          is_test == false and not is_nil(step_number) and not is_nil(channel_id) and
          not is_nil(queued_at)
      )
      |> Ash.Query.select([:id, :step_number, :channel_id, :queued_at])

    with {:ok, direct} <- Ash.read(direct_query, actor: actor),
         {:ok, memberships} <- delivery_memberships_for_alert(id, actor) do
      member_dispatches =
        Enum.filter(memberships, fn member ->
          delivery = member.delivery

          field(delivery, :route_id) == route_id and field(delivery, :dedupe_key) == key and
            field(delivery, :is_test) == false and not is_nil(field(delivery, :step_number)) and
            not is_nil(field(delivery, :channel_id))
        end)

      member_delivery_ids = MapSet.new(member_dispatches, & &1.delivery_id)

      dispatches =
        Enum.map(member_dispatches, fn member ->
          {member.delivery.step_number, member.delivery.channel_id, member.source_due_at}
        end) ++
          (direct
           |> Enum.reject(&MapSet.member?(member_delivery_ids, &1.id))
           |> Enum.map(&{&1.step_number, &1.channel_id, &1.queued_at}))

      {:ok, Enum.uniq(dispatches)}
    else
      {:error, reason} ->
        log_read_failure("existing dispatches", reason)
        {:error, {:existing_dispatches_unreadable, reason}}
    end
  end

  defp delivery_memberships_for_alert(alert_id, actor, delivery_load \\ []) do
    NotificationDeliveryMember
    |> Ash.Query.for_read(:for_alert, %{alert_id: alert_id})
    |> Ash.Query.load(delivery: delivery_load)
    |> Ash.read(actor: actor)
  end

  # The last time THIS rung reached THIS destination for THIS incident. Scoping
  # to (dedupe_key, channel_id, step_number) is what keeps cadence from eating
  # fan-out: a sibling channel in the same step is a different destination, and
  # a later rung of the same ladder is a different rung. What it does catch is a
  # policy REPEAT re-dispatching the same rung, which is exactly what
  # `renotify_seconds` and `throttle_seconds` govern (design D6).
  defp last_dispatch_at(delivery, actor, opts) do
    loader = Keyword.get(opts, :load_last_dispatch_at, &read_last_dispatch_at/2)

    case loader.(delivery, actor) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %DateTime{} = at} ->
        {:ok, at}

      {:error, reason} ->
        log_read_failure("last dispatch for delivery #{delivery.id}", reason)
        {:error, {:last_dispatch_unreadable, delivery.id, reason}}

      other ->
        {:error, {:last_dispatch_unreadable, delivery.id, {:invalid_loader_result, other}}}
    end
  end

  defp read_last_dispatch_at(delivery, actor) do
    with key when is_binary(key) <- delivery.dedupe_key,
         channel_id when not is_nil(channel_id) <- delivery.channel_id do
      NotificationDelivery
      |> Ash.Query.filter(
        dedupe_key == ^key and channel_id == ^channel_id and state == :sent and
          is_test == false and id != ^delivery.id
      )
      |> Ash.Query.filter(step_number == ^delivery.step_number)
      |> Ash.Query.sort(finished_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one(actor: actor)
      |> case do
        {:ok, %{finished_at: %DateTime{} = finished_at}} -> {:ok, finished_at}
        {:ok, _none_or_unfinished} -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    else
      _missing -> {:ok, nil}
    end
  end

  # --- context assembly -----------------------------------------------------

  defp delivery_scope(delivery, channel, provider, now, actor, opts) do
    with {:ok, route} <- load_route(delivery.route_id, actor, opts),
         {:ok, step} <- load_step(delivery.policy_id, delivery.step_number, actor, opts),
         {:ok, alert} <- load_delivery_alert(delivery, actor, opts),
         {:ok, rule} <- load_rule(alert, actor, opts),
         {:ok, silences} <- load_active_silences(now, actor, opts),
         {:ok, last_dispatch_at} <- last_dispatch_at(delivery, actor, opts) do
      device = alert_device(alert)

      scope = %{
        now: now,
        actor: actor,
        alert: alert,
        device: device,
        rule: rule,
        route: route,
        policy: nil,
        step: step,
        channel: channel,
        provider: provider
      }

      suppression =
        put_schedule_local_datetime(
          %{
            now: now,
            alert: alert,
            device: device,
            # A delivery that exists was routed. A missing row is legitimate
            # retention/config churn, so keep the identity stand-in that avoids
            # misclassifying it as an unrouted alert.
            route: route || %{id: delivery.route_id},
            schedule: route && route.schedule,
            silences: silences,
            match_subject: %{"alert" => alert || delivery.alert_snapshot || %{}},
            channel: channel,
            provider: provider,
            step: step,
            policy: %{id: delivery.policy_id},
            rule: rule,
            last_dispatch_at: last_dispatch_at,
            dedupe_key: delivery.dedupe_key,
            alert_snapshot: delivery.alert_snapshot || %{}
          },
          opts
        )

      {:ok, Map.put(scope, :suppression, suppression)}
    end
  end

  defp put_schedule_local_datetime(%{schedule: nil} = context, _opts), do: context

  defp put_schedule_local_datetime(%{schedule: schedule, now: now} = context, opts) do
    resolver = Keyword.get(opts, :time_zone, TimeZone)

    resolver_opts =
      case Keyword.get(opts, :time_zone_query) do
        query when is_function(query, 2) -> [query: query]
        _none -> []
      end

    case resolver.local_datetime(now, field(schedule, :timezone), resolver_opts) do
      {:ok, %NaiveDateTime{} = local} -> Map.put(context, :schedule_local_datetime, local)
      _unresolved -> context
    end
  end

  # The alert may be gone: AlertsRetentionWorker hard deletes after three days
  # and the FK is nilify. That is not an error - it is the case
  # `alert_snapshot` exists for.
  defp load_delivery_alert(%{alert_id: nil}, _actor, _opts), do: {:ok, nil}

  defp load_delivery_alert(delivery, actor, opts) do
    loader = Keyword.get(opts, :load_delivery_alert, &read_delivery_alert/2)

    case loader.(delivery, actor) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, alert} when is_map(alert) ->
        {:ok, alert}

      {:error, reason} ->
        log_read_failure("alert #{delivery.alert_id} for delivery #{delivery.id}", reason)
        {:error, {:delivery_alert_unreadable, delivery.alert_id, reason}}

      other ->
        {:error, {:delivery_alert_unreadable, delivery.alert_id, {:invalid_loader_result, other}}}
    end
  end

  defp read_delivery_alert(delivery, actor) do
    case read_alert(delivery.alert_id, actor) do
      {:ok, nil} -> {:ok, nil}
      {:ok, alert} -> {:ok, alert}
      {:error, reason} -> {:error, reason}
    end
  end

  defp suppression_context(scope, overrides) do
    Map.merge(
      %{
        now: scope.now,
        alert: scope.alert,
        device: scope.device,
        rule: scope.rule,
        silences: scope.silences,
        alert_snapshot: scope.snapshot,
        match_subject: %{"alert" => scope.alert || %{}},
        route: nil,
        schedule: route_schedule(Map.get(overrides, :route)),
        policy: nil,
        step: nil,
        channel: nil,
        last_dispatch_at: nil,
        dedupe_key: nil
      },
      overrides
    )
  end

  defp route_schedule(nil), do: nil

  defp route_schedule(route) do
    case field(route, :schedule) do
      %Ash.NotLoaded{} -> nil
      schedule -> schedule
    end
  end

  # Denormalised at creation because the delivery outlives the alert. Keys match
  # the published `alert.*` variable catalog in
  # `ServiceRadar.Notifications.Template.Syntax`, so a template written against
  # the documented paths resolves rather than silently rendering blanks.
  defp alert_snapshot(alert, opts) do
    Map.reject(
      %{
        "id" => field(alert, :id),
        "title" => field(alert, :title),
        "message" => field(alert, :description),
        "description" => field(alert, :description),
        "severity" => jsonable(field(alert, :severity)),
        "status" => jsonable(field(alert, :status)),
        "alert_class" => alert_class(alert),
        "source" => jsonable(field(alert, :source_type)),
        "source_id" => field(alert, :source_id),
        "device_uid" => field(alert, :device_uid),
        "agent_uid" => field(alert, :agent_uid),
        "metric_name" => field(alert, :metric_name),
        "metric_value" => field(alert, :metric_value),
        "threshold_value" => field(alert, :threshold_value),
        "comparison" => jsonable(field(alert, :comparison)),
        "escalation_level" => field(alert, :escalation_level),
        "occurrence_count" => field(alert, :notification_count),
        "rule_id" => incident_rule_id(alert),
        "group_key" => incident_group_key(alert),
        "first_seen_at" => iso8601(field(alert, :triggered_at) || field(alert, :created_at)),
        "last_seen_at" => iso8601(field(alert, :last_notification_at)),
        "acknowledged_at" => iso8601(field(alert, :acknowledged_at)),
        "acknowledged_by" => field(alert, :acknowledged_by),
        "resolved_at" => iso8601(field(alert, :resolved_at)),
        "resolved_by" => field(alert, :resolved_by),
        "snooze_until" => iso8601(field(alert, :snooze_until)),
        "tags" => field(alert, :tags) || [],
        "metadata" => jsonable(field(alert, :metadata) || %{}),
        "url" => Keyword.get(opts, :alert_url)
      },
      fn {_key, value} -> is_nil(value) end
    )
  end

  defp alert_class(alert) do
    metadata = field(alert, :metadata) || %{}

    presence(Map.get(metadata, "alert_class")) ||
      presence(jsonable(field(alert, :source_type))) ||
      "default"
  end

  defp incident_rule_id(alert) do
    metadata = field(alert, :metadata) || %{}
    presence(Map.get(metadata, "incident_rule_id"))
  end

  defp incident_group_key(alert) do
    metadata = field(alert, :metadata) || %{}
    presence(Map.get(metadata, "incident_group_key"))
  end

  defp alert_device(nil), do: nil

  defp alert_device(alert) do
    case field(alert, :device) do
      %Ash.NotLoaded{} -> nil
      device -> device
    end
  end

  # --- idempotency ----------------------------------------------------------

  # `Dedupe.routing_request_key/1` is THE key; it is derived there so every
  # emitter derives it the same way. A request that cannot produce one is not
  # locked - the plan-level `:dispatched` exclusion still applies - because
  # refusing to route an alert over a missing lock key would trade a duplicate
  # page for no page at all.
  defp with_request_lock(alert, lifecycle_reason, dedupe_key, opts, fun) do
    request = %{
      alert_id: field(alert, :id),
      lifecycle_reason: lifecycle_reason,
      step_number: Keyword.get(opts, :step_number),
      dedupe_key: dedupe_key
    }

    lifecycle_key = "notification-alert-lifecycle:" <> to_string(field(alert, :id))

    case {Keyword.get(opts, :lock?, true), Dedupe.routing_request_key(request)} do
      {true, {:ok, request_key}} ->
        emit_notifications(locked([lifecycle_key, request_key], fun))

      {true, _unlockable} ->
        emit_notifications(locked([lifecycle_key], fun))

      {false, _request_key} ->
        emit_notifications(transactional(fun))
    end
  end

  # Ash discards resource notifications raised inside a transaction unless the
  # caller asks for them back, and warns loudly when it does. The creates run
  # under the routing lock's transaction, so they are collected there and sent
  # here - after the transaction has committed, which is the only point at which
  # a subscriber reading the delivery back would find it.
  defp emit_notifications({:ok, %{notifications: notifications} = result}) do
    Ash.Notifier.notify(notifications)
    {:ok, Map.delete(result, :notifications)}
  end

  defp emit_notifications(other), do: other

  defp empty_result, do: %{planned: [], suppressed: [], notifications: []}

  defp locked(keys, fun) do
    case Repo.transaction(fn ->
           Enum.each(List.wrap(keys), fn key ->
             _ = SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [lock_key(key)])
           end)

           rollback_on_error(fun.())
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.error("notification routing lock unavailable",
        reason: inspect(error)
      )

      {:error, {:routing_lock_unavailable, Exception.message(error)}}
  end

  defp transactional(fun) do
    case Repo.transaction(fn -> rollback_on_error(fun.()) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_on_error({:error, reason}), do: Repo.rollback(reason)
  defp rollback_on_error(result), do: result

  defp lock_key(key) do
    <<value::signed-integer-size(64), _rest::binary>> = :crypto.hash(:sha256, key)
    value
  end

  defp dedupe_key(alert, route, opts) do
    case Keyword.get(opts, :dedupe_key) do
      key when is_binary(key) ->
        key

      _none ->
        case Dedupe.dedupe_key(alert, route) do
          {:ok, key} ->
            key

          {:error, reason} ->
            # A key that cannot be derived must not become a guessed one - a
            # guessed key silently merges unrelated incidents - so the alert's
            # own identity is used, which is what Dedupe returns for the two
            # engine-bypassing creation paths anyway.
            Logger.warning("notification dedupe key fell back to the alert id",
              alert_id: field(alert, :id),
              reason: inspect(reason)
            )

            "alert=" <> to_string(field(alert, :id))
        end
    end
  end

  # --- telemetry ------------------------------------------------------------

  # Metadata carries ids and classifications ONLY. Nothing assembled here may be
  # a payload, a rendered subject or body, a resolved secret, or an alert title:
  # a telemetry handler ships metadata to label sets, logs, and traces
  # indiscriminately, so a leak here is a leak everywhere at once.
  defp telemetry_fields(delivery, channel) do
    provider = field(channel, :provider)

    %{
      alert_id: delivery.alert_id,
      delivery_id: delivery.id,
      channel_id: delivery.channel_id,
      policy_id: delivery.policy_id,
      route_id: delivery.route_id,
      step_number: delivery.step_number,
      # `delivery` is always the PRE-update row here, so every event for one
      # attempt reports the same attempt number.
      attempt: (delivery.attempt_count || 0) + 1,
      provider_key: field(provider, :provider_key),
      provider_type: field(provider, :provider_type),
      execution_route: delivery.execution_route,
      is_test: delivery.is_test == true
    }
  end

  defp emit_routed(alert_id, lifecycle_reason, decision, {:ok, result}) do
    Telemetry.routed(%{
      alert_id: alert_id,
      lifecycle_reason: lifecycle_reason,
      matched_routes: length(decision.matched),
      planned: length(Map.get(result, :planned, [])),
      suppressed: length(Map.get(result, :suppressed, []))
    })
  end

  # A routing request that failed produced no decision to measure. Emitting a
  # zero-planned event for it would read as "this alert was routed and owed
  # nothing", which is the opposite of what happened.
  defp emit_routed(_alert_id, _lifecycle_reason, _decision, _other), do: :ok

  defp emit_suppressed(delivery, context, phase) do
    provider = Map.get(context, :provider) || field(Map.get(context, :channel), :provider)

    Telemetry.suppressed(%{
      alert_id: delivery.alert_id,
      delivery_id: delivery.id,
      channel_id: delivery.channel_id,
      policy_id: delivery.policy_id,
      step_number: delivery.step_number,
      provider_key: field(provider, :provider_key),
      provider_type: field(provider, :provider_type),
      suppression_reason: delivery.suppression_reason,
      occurrence_count: delivery.occurrence_count,
      phase: phase
    })
  end

  # Step 1 is the first notification, not an escalation. Counting it as one
  # would make every paged alert look escalated and the escalation series
  # useless for answering "did the ladder fire?".
  defp emit_escalated(%{step_number: step_number} = delivery, channel)
       when is_integer(step_number) and step_number > 1 do
    Telemetry.escalated(%{
      alert_id: delivery.alert_id,
      delivery_id: delivery.id,
      policy_id: delivery.policy_id,
      channel_id: delivery.channel_id,
      step_number: step_number,
      provider_key: field(field(channel, :provider), :provider_key)
    })
  end

  defp emit_escalated(_delivery, _channel), do: :ok

  # End-to-end dispatch latency is measured from ALERT FIRE TIME, not from
  # `queued_at` - a rung that was owed fifteen minutes after the alert fired is
  # not fifteen minutes late, and a rung whose dispatch was delayed by retries
  # is. `first_seen_at` on the snapshot is the alert's `triggered_at`, which is
  # denormalised precisely because the alert row may already be pruned.
  defp dispatch_latency_ms(delivery, now) do
    delivery.alert_snapshot
    |> snapshot_field("first_seen_at")
    |> parse_iso8601()
    |> Telemetry.latency_ms(now)
  end

  defp parse_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_iso8601(_value), do: nil

  # --- small helpers --------------------------------------------------------

  defp attemptable(%{state: :pending, next_attempt_at: %DateTime{} = at}, now) do
    if DateTime.after?(at, now), do: {:settled, {:retry, at}}, else: :continue
  end

  defp attemptable(%{state: state}, _now) when state in @attemptable_states, do: :continue
  defp attemptable(%{state: :dispatching}, _now), do: {:settled, {:ok, :dispatching}}
  defp attemptable(%{state: :sent} = delivery, _now), do: {:settled, {:ok, :sent}, delivery}
  defp attemptable(%{state: :suppressed}, _now), do: {:settled, {:ok, :suppressed}}

  defp attemptable(%{state: state}, _now) when state in @terminal_states do
    {:settled, {:error, {:not_deliverable, state}}}
  end

  defp attemptable(%{state: state}, _now),
    do: {:settled, {:error, {:unknown_delivery_state, state}}}

  defp fetch_channel(%{channel: %Ash.NotLoaded{}}), do: {:error, :channel_not_loaded}
  defp fetch_channel(%{channel: nil}), do: {:error, :channel_not_found}
  defp fetch_channel(%{channel: channel}), do: {:ok, channel}

  defp fetch_provider(%{provider: %Ash.NotLoaded{}}), do: {:error, :provider_not_loaded}
  defp fetch_provider(%{provider: nil}), do: {:error, :provider_not_found}
  defp fetch_provider(%{provider: provider}), do: {:ok, provider}

  defp policy_steps(nil), do: []

  defp policy_steps(policy) do
    case field(policy, :steps) do
      steps when is_list(steps) -> steps
      _other -> []
    end
  end

  defp policy_steps_by_number(policy) do
    policy |> policy_steps() |> Map.new(&{field(&1, :step_number), &1})
  end

  defp policy_channels(policy) do
    policy
    |> policy_steps()
    |> Enum.flat_map(fn step ->
      case field(step, :channels) do
        channels when is_list(channels) -> channels
        _other -> []
      end
    end)
    |> Map.new(&{field(&1, :id), &1})
  end

  defp max_attempts(nil), do: 3
  defp max_attempts(channel), do: field(channel, :max_attempts) || 3

  defp execution_route(nil), do: :control_plane
  defp execution_route(channel), do: field(channel, :execution_route) || :control_plane

  defp negotiated_format(requested, provider) do
    case Renderer.negotiate_format(requested, field(provider, :payload_formats)) do
      {:ok, format} -> format
      {:error, _reason} -> nil
    end
  end

  defp put_rendered(attrs, nil), do: attrs

  defp put_rendered(attrs, rendered) do
    attrs
    |> Map.put(:rendered_payload_digest, rendered.digest)
    |> Map.put(:payload_format, rendered.payload_format)
    |> Map.put(:provider_version, rendered.provider_version)
  end

  defp merge_result({:ok, acc}, {:ok, next}) do
    {:ok,
     %{
       planned: acc.planned ++ next.planned,
       suppressed: acc.suppressed ++ next.suppressed,
       notifications: acc.notifications ++ next.notifications
     }}
  end

  defp merge_result({:error, _reason} = error, _next), do: error
  defp merge_result(_acc, {:error, _reason} = error), do: error

  defp first_route(%{matched: [%{route: route} | _rest]}), do: route
  defp first_route(_decision), do: nil

  defp rand_source, do: fn -> :rand.uniform() end

  defp fetch_now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> now
      _none -> DateTime.utc_now()
    end
  end

  defp fetch_actor(opts) do
    Keyword.get(opts, :actor) || SystemActor.system(:notification_dispatcher)
  end

  defp field(nil, _key), do: nil

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, %Ash.NotLoaded{}} -> nil
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_other, _key), do: nil

  defp snapshot_field(snapshot, key) when is_map(snapshot), do: presence(Map.get(snapshot, key))
  defp snapshot_field(_snapshot, _key), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp iso8601(_value), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(_map), do: %{}

  defp format_errors(errors) when is_list(errors), do: Enum.join(errors, "; ")
  defp format_errors(error), do: inspect(error)

  # Persisted into jsonb columns, so values are flattened to JSON-encodable
  # forms here. Atoms become strings; nothing becomes an atom.
  defp jsonable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp jsonable(%Date{} = value), do: Date.to_iso8601(value)
  defp jsonable(%Time{} = value), do: Time.to_iso8601(value)
  defp jsonable(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp jsonable(value) when is_nil(value) or is_binary(value) or is_number(value), do: value
  defp jsonable(value) when is_boolean(value), do: value
  defp jsonable(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  defp jsonable(%_struct{} = value), do: inspect(value)

  defp jsonable(value) when is_map(value) do
    Map.new(value, fn {key, inner} -> {to_string(key), jsonable(inner)} end)
  end

  defp jsonable(value), do: inspect(value)

  # --- logging --------------------------------------------------------------

  defp log_route_errors(_alert_id, %{errors: []}), do: :ok

  # A broken predicate is an operator-fixable configuration fault and an
  # unclaimed alert is not, so the two are distinguished in the log even though
  # both record `:no_matching_route`.
  defp log_route_errors(alert_id, %{errors: errors}) do
    Logger.error("notification route predicates failed to evaluate",
      alert_id: alert_id,
      route_ids: Enum.map(errors, & &1.route_id),
      reasons: Enum.map(errors, & &1.reason)
    )
  end

  defp log_plan_diagnostics(_alert, _route, %{diagnostics: []}), do: :ok

  defp log_plan_diagnostics(alert, route, %{diagnostics: diagnostics}) do
    Logger.warning("notification escalation plan has configuration diagnostics",
      alert_id: field(alert, :id),
      route_id: field(route, :id),
      diagnostics: inspect(diagnostics)
    )
  end

  defp log_write_failure(what, alert_id, step_number, reason) do
    Logger.error("notification dispatcher could not #{what}",
      alert_id: alert_id,
      step_number: step_number,
      reason: inspect(reason)
    )
  end
end
