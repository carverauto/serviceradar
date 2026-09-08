defmodule ServiceRadar.Notifications.Suppression do
  @moduledoc """
  Decides whether one candidate notification dispatch may leave the building,
  and if not, which enumerated reason explains it (design D5).

  This module is a **pure function over plain maps**. It performs no Ash reads,
  no Ecto queries, no `Repo` access, holds no process state, and never calls
  `DateTime.utc_now/0`: the evaluation instant is `context.now` and is supplied
  by the caller. The caller loads everything from the database, calls
  `evaluate/1`, and persists the result. That split - decide, then persist - is
  what makes the hardest semantics in the notification platform testable with
  `async: true` and no database.

  ## Re-evaluation at every dispatch is the rule

  Design D5 property 1: suppression is re-run immediately before **every**
  dispatch attempt - every escalation step, every policy repeat, every retry,
  and every failover hop - and is never evaluated once at routing time and
  cached. Nothing here caches, memoises, or reads a clock, so calling
  `evaluate/1` again fifteen minutes later with a freshly loaded context is both
  safe and required. An alert routed while its device was in service and
  escalated after the device was marked out of service MUST come back
  `{:suppress, :device_out_of_service, _}` on the later call, and it does,
  because the answer is a function of the arguments alone.

  ## Precedence: first match wins, so the order is the operator's answer

  A withheld dispatch records exactly one `suppression_reason` on its
  `NotificationDelivery` row, and that single value is what an operator reads
  when they ask "why was I not paged?". The order below is therefore fixed,
  documented, and part of the contract rather than an accident of how the
  conditionals happened to nest.

  It runs outward from the subject of the alert, through deliberate operator
  statements, through route configuration and cadence, to per-channel mechanics,
  and ends with "nothing was configured at all". Ties are broken toward the
  explanation that ends the investigation with the least further digging.

  | # | Reason | Why it sits here |
  | --- | --- | --- |
  | 1 | `:device_out_of_service` | A statement about the alert's subject, not about notification configuration. It withholds every notification for that device, from every route, channel, and step, until someone puts the device back in service. Reported first because an operator who reads any lower reason would go fix that instead - cancel the silence, widen the schedule - and still not be paged. |
  | 2 | `:silence` | A deliberate, time-bounded, individually attributed act with a required comment. "Alice silenced this until 14:00 while migrating the core switch" ends the investigation; standing configuration does not. |
  | 3 | `:schedule` | Standing route configuration. Broad and durable, but nobody decided it *for this incident*. |
  | 4 | `:snoozed` | A per-alert deferral. Below silence and schedule because it is the narrowest and most transient of the three deliberate mutes; if a silence also covers the alert, the silence outlives the snooze and is the durable cause. |
  | 5 | `:throttled` | Cadence, owned by the rule (`cooldown_seconds`) and only ever narrowed by the route (`throttle_seconds`). It says "you were paged recently", which is only interesting once nobody has muted the alert outright. |
  | 6 | `:acknowledged` | A human already owns the incident, so an `:if_unacknowledged` rung of the ladder has nothing left to do. |
  | 7 | `:channel_disabled` | Mechanical and per-channel: the same dispatch to a sibling channel in the same fan-out set may go out normally. |
  | 8 | `:dependency` | RESERVED. Never returned by this change; see below. |
  | 9 | `:no_matching_route` | The residual. Last because every route-scoped reason above is vacuous when no route matched, while the alert-scoped ones are not: "the device is out of service" is a better answer than "you never wrote a route" for a device nobody wants paged about. |

  `precedence/0` returns that order as data, and `evaluate/1` walks it, so the
  documentation and the implementation cannot drift.

  ## `:device_out_of_service` is defence in depth, on purpose

  `openspec/changes/add-device-active-lifecycle` owns suppressing device-scoped
  event and alert **generation** for inactive devices, and this module does not
  duplicate that. The notification layer re-checks anyway, because two
  alert-creation paths bypass the stateful alert engine entirely and create
  alerts with no deduplication and no device-activity filter:

    * `ServiceRadar.Observability.LogPromotion.update_alert_counts/2`
    * `ServiceRadar.EventWriter.Processors.TrivyReports.maybe_create_priority_alert/3`

  So this layer never assumes an alert reaching it was already filtered for
  device activity state.

  ## `:snoozed` is derived, never a state

  `ServiceRadar.Monitoring.Alert` deliberately has no `:snoozed` status. The
  state machine's `state_attribute` is `:status` with
  pending/acknowledged/resolved/escalated/suppressed, and `update :snooze`
  only writes a `snooze_until` timestamp. "Snoozed" is therefore the derived
  condition `status in [:pending, :escalated] and snooze_until > now`, which is
  what `snoozed?/2` computes and what keeps snooze expiry a pure timestamp
  comparison with no transition to schedule.

  ## `:acknowledged` keys on `status`, never on `acknowledged_at`

  `update :reopen` clears `resolved_at`, `resolved_by`, and `suppressed_until`
  but does **not** clear `acknowledged_at`, and `transition :escalate` moves an
  acknowledged alert to `:escalated` while leaving `acknowledged_at` populated.
  Treating a non-nil `acknowledged_at` as "acknowledged" would therefore silence
  a reopened or escalated alert forever. The predicate is `status ==
  :acknowledged` and nothing else.

  ## Schedules: correct in UTC, explicit everywhere else

  `serviceradar_core` ships **no IANA time zone database** - there is no
  `tzdata` (or equivalent) dependency, so Elixir falls back to
  `Calendar.UTCOnlyTimeZoneDatabase` and `DateTime.shift_zone/2` fails for every
  zone that is not UTC. A schedule whose `timezone` is `America/New_York`
  therefore **cannot** be evaluated today.

  That is exactly the failure that must not be silent. A schedule that cannot be
  evaluated and is treated as "outside the window" suppresses every dispatch on
  every route that references it, reads as correctly configured, and produces
  precisely the pager silence design D5 exists to eliminate. So:

    * `schedule_active?/2` returns `{:error, {:unsupported_timezone, zone}}` -
      an explicit, typed, matchable error. Configuration and UI layers SHOULD
      call it at save time and refuse the schedule while the operator is looking
      at it.
    * `evaluate/1` treats **any** unevaluable schedule as active and returns
      `:allow`. Suppression never happens on ignorance. A false page is a
      nuisance; a false suppression is an outage nobody hears about.

  The same fail-open rule covers a schedule with no windows, a malformed window
  entry, and an unknown `mode`. When a real time zone database is configured
  later, `schedule_active?/2` starts resolving non-UTC zones correctly - across
  daylight-saving transitions included - with no change here, because the zone
  shift is delegated to `DateTime.shift_zone/2`.

  ## `:dependency` is reserved and never returned

  Topology-driven parent suppression ("do not page for fifty devices behind one
  downed switch") is a follow-on. The reason is in `precedence/0` and in the
  `NotificationDelivery.suppression_reason` enum so the later change needs no
  schema migration, and `evaluate/1` provably never emits it.

  ## What this module does not decide

  It does not evaluate `MatchExpression` documents. Matcher evaluation is one
  shared evaluator over the one shared grammar (see
  `ServiceRadar.Notifications.MatchExpression`); a second implementation here
  would have to be kept in semantic parity by hand, and a silence that quietly
  stops matching the route that created it is the exact failure that grammar was
  unified to prevent. Silence matchers are evaluated by calling
  `ServiceRadar.Notifications.MatchExpression.Evaluator.evaluate/3` - the one
  evaluator that `ServiceRadar.Notifications.Router` also calls - against the
  subject `%{"alert" => alert}`, or against `context.match_subject` when the
  caller has already assembled a richer one. A caller that pre-narrowed its
  silence list may override with `:silence_matcher`.

  The state and window halves are re-checked here regardless of how the list was
  narrowed, because the candidates may have been loaded at routing time and this
  evaluation may be happening minutes later.

  A matcher document that fails to evaluate does **not** match, so a broken
  silence stops muting rather than muting everything - the same
  never-suppress-on-ignorance rule the schedule check follows.

  It also does not decide retry, failover, escalation ladder advancement, or
  rendering. `ServiceRadar.Notifications.Escalation` owns the ladder.

  ## Context

  A plain map with atom keys. Values may be Ash structs or plain maps - every
  read goes through `Map.fetch/2`, so both work, which is what lets the tests
  run without a database while production passes loaded resources straight
  through.

    * `:now` - **required** `DateTime`. The evaluation instant.
    * `:alert` - the alert (`:id`, `:status`, `:snooze_until`, `:device_uid`).
    * `:device` - the subject device (`:is_active`). `nil` when the alert has no
      device subject **or** the device could not be loaded; both fail open.
    * `:route` - the matched route, or `nil` to mean *no enabled route matched*,
      which is what produces `:no_matching_route`.
    * `:schedule` - the route's schedule, or `nil`.
    * `:schedule_local_datetime` - optional wall-clock time already resolved in
      the schedule's IANA zone by the impure dispatcher. Supplying it keeps this
      decision core pure while allowing production to use PostgreSQL's IANA
      database.
    * `:silences` - list of candidate silences (`:id`, `:state`, `:starts_at`,
      `:ends_at`, `:matchers`).
    * `:match_subject` - the subject silence matchers are evaluated against.
      Defaults to `%{"alert" => alert}`, the routing subject shape.
    * `:silence_matcher` - optional `(matchers, subject -> boolean)` replacing
      the shared evaluator, for a caller that already narrowed its silence list.
    * `:channel` - the destination channel (`:id`, `:enabled`,
      `:execution_route`), or `nil` for a decision taken before a channel is
      chosen.
    * `:provider` - the channel's provider (`:status`). Falls back to
      `channel.provider`.
    * `:step` - the escalation step (`:step_number`, `:condition`). Absent means
      `:if_unacknowledged`, the resource default and the safe one.
    * `:policy` - the escalation policy (`:id`).
    * `:throttle` - `%{last_dispatch_at:, throttle_seconds:, cooldown_seconds:}`.
      When absent it is assembled from `context.last_dispatch_at`,
      `route.throttle_seconds`, and `rule.cooldown_seconds`.
    * `:rule` - the stateful alert rule (`:cooldown_seconds`).
    * `:last_dispatch_at` - when this dedupe key last produced a dispatch.
    * `:dedupe_key`, `:alert_snapshot` - carried through to
      `to_delivery_attributes/2`; never inspected by a decision.

  See `openspec/changes/add-notification-platform/design.md` (D5) and the
  "Suppression is an enumerated, auditable decision", "Device out-of-service
  suppression at the notification layer", "Suppression is re-evaluated at every
  dispatch", and "Notification schedules" requirements.
  """

  alias ServiceRadar.Notifications.MatchExpression.Evaluator

  @reasons [
    :device_out_of_service,
    :silence,
    :schedule,
    :snoozed,
    :throttled,
    :acknowledged,
    :channel_disabled,
    :dependency,
    :no_matching_route
  ]

  # The order IS the precedence. See the moduledoc table for why each reason
  # sits where it does; `evaluate/1` walks this list and halts on the first
  # match, so the table and the behaviour cannot diverge.
  @precedence @reasons

  # Statuses in which a snooze is meaningful. A resolved, suppressed, or
  # acknowledged alert is not "snoozed" however far in the future its timestamp
  # sits - design "Alert Lifecycle Changes".
  @snoozable_statuses [:pending, :escalated]

  @days {"mon", "tue", "wed", "thu", "fri", "sat", "sun"}
  @day_tokens ~w(mon tue wed thu fri sat sun)

  # Zone names this module resolves without a time zone database. Everything
  # else is delegated to DateTime.shift_zone/2 and reported as unsupported when
  # that fails.
  @utc_zones ~w(UTC ETC/UTC GMT ETC/GMT Z ZULU ETC/ZULU)

  @type reason ::
          :device_out_of_service
          | :silence
          | :schedule
          | :snoozed
          | :throttled
          | :acknowledged
          | :channel_disabled
          | :dependency
          | :no_matching_route

  @type detail :: %{optional(atom()) => term()}
  @type outcome :: :allow | {:suppress, reason(), detail()}
  @type context :: %{optional(atom()) => term()}

  @type schedule_error ::
          {:unsupported_timezone, String.t()}
          | {:invalid_window, non_neg_integer(), String.t()}
          | {:invalid_mode, term()}
          | :no_windows

  @doc """
  The closed suppression reason vocabulary, in precedence order.

  Identical to `precedence/0`; both are exposed because callers ask two
  different questions - "what values may `suppression_reason` take?" and "in
  what order are they decided?" - and the answer happens to be one list.
  """
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc """
  The evaluation order. The first reason that matches is the one recorded.
  """
  @spec precedence() :: [reason()]
  def precedence, do: @precedence

  @doc """
  Reasons this change may emit. `:dependency` is reserved and excluded.
  """
  @spec emittable_reasons() :: [reason()]
  def emittable_reasons, do: @reasons -- [:dependency]

  @doc """
  Evaluates one candidate dispatch.

  Returns `:allow`, or `{:suppress, reason, detail}` where `reason` is the
  first entry of `precedence/0` that matched and `detail` carries the specifics
  an operator needs. Requires `context.now`; a context without it raises, rather
  than quietly substituting the wall clock and making the decision
  irreproducible.
  """
  @spec evaluate(context()) :: outcome()
  def evaluate(context) when is_map(context) do
    _now = fetch_now!(context)

    Enum.reduce_while(@precedence, :allow, fn reason, :allow ->
      case check(reason, context) do
        :allow -> {:cont, :allow}
        {:suppress, detail} -> {:halt, {:suppress, reason, detail}}
      end
    end)
  end

  @doc """
  True when the alert is in the derived "snoozed" condition.

  `status in [:pending, :escalated] and snooze_until > now`. Shared with
  `ServiceRadar.Notifications.Escalation` so the two modules cannot drift.
  """
  @spec snoozed?(map() | nil, DateTime.t()) :: boolean()
  def snoozed?(alert, %DateTime{} = now) do
    status = field(alert, :status)
    snooze_until = field(alert, :snooze_until)

    status in @snoozable_statuses and match?(%DateTime{}, snooze_until) and
      DateTime.after?(snooze_until, now)
  end

  @doc """
  True when the alert has been acknowledged.

  Keys on `status == :acknowledged` only. See the moduledoc for why
  `acknowledged_at` is not consulted.
  """
  @spec acknowledged?(map() | nil) :: boolean()
  def acknowledged?(alert), do: field(alert, :status) == :acknowledged

  @doc """
  True when the alert's subject device is marked out of service.
  """
  @spec device_out_of_service?(map() | nil) :: boolean()
  def device_out_of_service?(device), do: field(device, :is_active) == false

  @doc """
  Whether a schedule is inside its effective active period at `now`.

  Returns `{:ok, boolean}`, or `{:error, reason}` when the schedule cannot be
  evaluated at all. Callers that validate configuration SHOULD treat an error as
  a hard failure at save time; `evaluate/1` treats it as active, because a
  schedule nobody can evaluate must never be the thing that silences a
  deployment.

  A `nil` or disabled schedule is active - a route with no schedule is not gated
  by one. The impure dispatcher supplies `local_datetime: value` after resolving
  an IANA zone through PostgreSQL; database-free callers may omit it and use the
  configured `Calendar.TimeZoneDatabase` instead.
  """
  @spec schedule_active?(map() | nil, DateTime.t(), keyword()) ::
          {:ok, boolean()} | {:error, schedule_error()}
  def schedule_active?(schedule, now, opts \\ [])

  def schedule_active?(nil, %DateTime{}, _opts), do: {:ok, true}

  def schedule_active?(schedule, %DateTime{} = now, opts)
      when is_map(schedule) and is_list(opts) do
    if field(schedule, :enabled) == false do
      {:ok, true}
    else
      evaluate_schedule(schedule, now, opts)
    end
  end

  @doc """
  Maps an outcome onto the attributes
  `ServiceRadar.Notifications.NotificationDelivery`'s `:record_suppression`
  action accepts.

  Returns `:allow` for an allowed dispatch - there is nothing to persist - and
  `{:ok, attrs}` for a suppression. The attribute set is exactly the identity
  tuple design D5 collapses on
  (`{alert_id, policy_id, step_number, channel_id, dedupe_key, suppression_reason}`)
  plus `route_id`, `alert_snapshot`, `execution_route`, and a JSON-encodable
  `result_summary`.

  `result_summary` carries only identifiers, timestamps, and the enumerated
  reason. No alert content, no channel configuration, and no operator free text
  reaches it, so it adds nothing for `ActionRedaction` to strip - the caller
  still runs the alert snapshot through redaction, which is where alert content
  actually lives.
  """
  @spec to_delivery_attributes(outcome(), context()) :: :allow | {:ok, map()}
  def to_delivery_attributes(:allow, _context), do: :allow

  def to_delivery_attributes({:suppress, reason, detail}, context)
      when reason in @reasons and is_map(detail) and is_map(context) do
    now = fetch_now!(context)

    {:ok,
     %{
       alert_id: field(Map.get(context, :alert), :id),
       alert_snapshot: Map.get(context, :alert_snapshot) || %{},
       route_id: field(Map.get(context, :route), :id),
       policy_id: field(Map.get(context, :policy), :id),
       step_number: field(Map.get(context, :step), :step_number),
       channel_id: field(Map.get(context, :channel), :id),
       dedupe_key: Map.get(context, :dedupe_key),
       suppression_reason: reason,
       execution_route: field(Map.get(context, :channel), :execution_route),
       result_summary: %{
         "suppression" => %{
           "reason" => Atom.to_string(reason),
           "evaluated_at" => DateTime.to_iso8601(now),
           "detail" => jsonable(detail)
         }
       }
     }}
  end

  # --- Checks, one per reason, in precedence order --------------------------

  @spec check(reason(), context()) :: :allow | {:suppress, detail()}
  defp check(:device_out_of_service, context) do
    device = Map.get(context, :device)

    if device_out_of_service?(device) do
      {:suppress,
       %{
         device_uid: field(device, :device_uid) || field(Map.get(context, :alert), :device_uid)
       }}
    else
      :allow
    end
  end

  defp check(:silence, context) do
    now = fetch_now!(context)
    subject = match_subject(context)
    matcher = Map.get(context, :silence_matcher)

    context
    |> Map.get(:silences)
    |> List.wrap()
    |> Enum.find(&silencing?(&1, now, subject, matcher))
    |> case do
      nil ->
        :allow

      silence ->
        {:suppress, %{silence_id: field(silence, :id), ends_at: field(silence, :ends_at)}}
    end
  end

  defp check(:schedule, context) do
    schedule = Map.get(context, :schedule)

    opts =
      case Map.get(context, :schedule_local_datetime) do
        %NaiveDateTime{} = local -> [local_datetime: local]
        %DateTime{} = local -> [local_datetime: local]
        _other -> []
      end

    case schedule_active?(schedule, fetch_now!(context), opts) do
      {:ok, true} ->
        :allow

      {:ok, false} ->
        {:suppress,
         %{
           schedule_id: field(schedule, :id),
           timezone: field(schedule, :timezone),
           mode: field(schedule, :mode)
         }}

      # Never suppress on ignorance. schedule_active?/2 is the surface that
      # reports the defect; a dispatch decision must not be the place a broken
      # schedule is discovered.
      {:error, _reason} ->
        :allow
    end
  end

  defp check(:snoozed, context) do
    alert = Map.get(context, :alert)

    if snoozed?(alert, fetch_now!(context)) do
      {:suppress, %{snooze_until: field(alert, :snooze_until), status: field(alert, :status)}}
    else
      :allow
    end
  end

  defp check(:throttled, context) do
    now = fetch_now!(context)
    throttle = throttle_spec(context)
    last = Map.get(throttle, :last_dispatch_at)
    window = Map.get(throttle, :effective_seconds)

    if match?(%DateTime{}, last) and window > 0 and DateTime.diff(now, last, :second) < window do
      {:suppress,
       %{
         throttle_seconds: Map.get(throttle, :throttle_seconds),
         cooldown_seconds: Map.get(throttle, :cooldown_seconds),
         effective_seconds: window,
         last_dispatch_at: last,
         next_eligible_at: DateTime.add(last, window, :second)
       }}
    else
      :allow
    end
  end

  defp check(:acknowledged, context) do
    alert = Map.get(context, :alert)
    condition = step_condition(context)

    if condition == :if_unacknowledged and acknowledged?(alert) do
      {:suppress,
       %{
         condition: condition,
         acknowledged_at: field(alert, :acknowledged_at),
         step_number: field(Map.get(context, :step), :step_number)
       }}
    else
      :allow
    end
  end

  defp check(:channel_disabled, context) do
    channel = Map.get(context, :channel)
    provider = Map.get(context, :provider) || field(channel, :provider)

    cond do
      is_nil(channel) ->
        :allow

      field(channel, :enabled) == false ->
        {:suppress, %{channel_id: field(channel, :id), channel_enabled: false}}

      provider_deactivated?(provider) ->
        {:suppress, %{channel_id: field(channel, :id), provider_status: field(provider, :status)}}

      true ->
        :allow
    end
  end

  # RESERVED (design "Future Directions"). Topology-driven parent suppression is
  # a follow-on change; this clause exists so the reason keeps its documented
  # place in the precedence order and provably never fires today.
  defp check(:dependency, _context), do: :allow

  defp check(:no_matching_route, context) do
    if is_nil(Map.get(context, :route)) do
      {:suppress, %{}}
    else
      :allow
    end
  end

  # --- Silences -------------------------------------------------------------

  defp silencing?(silence, now, subject, matcher) when is_map(silence) do
    active_state?(silence) and inside_silence_window?(silence, now) and
      silence_matches?(silence, subject, matcher)
  end

  defp silencing?(_silence, _now, _subject, _matcher), do: false

  # `:cancelled` stops suppressing immediately and `:expired` never resumes, so
  # the state is checked as well as the window: a lagging sweeper must not
  # extend a silence, and a cancelled one must not keep muting until `ends_at`.
  defp active_state?(silence), do: field(silence, :state) == :active

  defp inside_silence_window?(silence, now) do
    starts_at = field(silence, :starts_at)
    ends_at = field(silence, :ends_at)

    started? = not match?(%DateTime{}, starts_at) or DateTime.compare(starts_at, now) != :gt
    ending? = match?(%DateTime{}, ends_at) and DateTime.compare(ends_at, now) != :gt

    started? and not ending?
  end

  # The shared evaluator, not a second implementation: `Router` asks the same
  # question of the same grammar and gets the same answer. A document that fails
  # to evaluate does not match, so a broken silence stops muting rather than
  # muting everything.
  defp silence_matches?(silence, subject, nil) do
    case Evaluator.evaluate(field(silence, :matchers) || %{}, subject) do
      {:ok, matches?} -> matches?
      {:error, _reason} -> false
    end
  end

  defp silence_matches?(silence, subject, matcher) when is_function(matcher, 2) do
    matcher.(field(silence, :matchers) || %{}, subject) == true
  end

  defp match_subject(context) do
    case Map.get(context, :match_subject) do
      subject when is_map(subject) -> subject
      _other -> %{"alert" => Map.get(context, :alert) || %{}}
    end
  end

  # --- Throttling -----------------------------------------------------------

  # The rule owns cadence and the route may only narrow it (design D6), so the
  # effective window is the LONGER of the two. Taking the route's value alone
  # would let notification configuration page more often than the rule
  # authorises, which the spec forbids in both directions.
  defp throttle_spec(context) do
    supplied = Map.get(context, :throttle) || %{}

    throttle_seconds =
      fetch_first([
        {supplied, :throttle_seconds},
        {Map.get(context, :route), :throttle_seconds}
      ])

    cooldown_seconds =
      fetch_first([
        {supplied, :cooldown_seconds},
        {Map.get(context, :rule), :cooldown_seconds}
      ])

    last_dispatch_at =
      fetch_first([
        {supplied, :last_dispatch_at},
        {context, :last_dispatch_at}
      ])

    %{
      throttle_seconds: throttle_seconds,
      cooldown_seconds: cooldown_seconds,
      last_dispatch_at: last_dispatch_at,
      effective_seconds: max(seconds(throttle_seconds), seconds(cooldown_seconds))
    }
  end

  defp seconds(value) when is_integer(value) and value > 0, do: value
  defp seconds(_value), do: 0

  # --- Schedules ------------------------------------------------------------

  defp evaluate_schedule(schedule, now, opts) do
    with {:ok, local} <- local_datetime(now, field(schedule, :timezone), opts),
         {:ok, windows} <- parse_windows(field(schedule, :windows)) do
      apply_mode(field(schedule, :mode), Enum.any?(windows, &window_contains?(&1, local)))
    end
  end

  defp apply_mode(:active_within, inside?), do: {:ok, inside?}
  defp apply_mode(:active_outside, inside?), do: {:ok, not inside?}
  defp apply_mode(mode, _inside?), do: {:error, {:invalid_mode, mode}}

  defp local_datetime(%DateTime{}, _timezone, local_datetime: %NaiveDateTime{} = local),
    do: {:ok, local}

  defp local_datetime(%DateTime{}, _timezone, local_datetime: %DateTime{} = local),
    do: {:ok, local}

  defp local_datetime(%DateTime{} = now, timezone, _opts) when is_binary(timezone) do
    zone = if utc_zone?(timezone), do: "Etc/UTC", else: timezone

    case DateTime.shift_zone(now, zone) do
      {:ok, local} -> {:ok, local}
      {:error, _reason} -> {:error, {:unsupported_timezone, timezone}}
    end
  end

  defp local_datetime(%DateTime{} = now, nil, opts), do: local_datetime(now, "Etc/UTC", opts)

  defp local_datetime(%DateTime{}, timezone, _opts),
    do: {:error, {:unsupported_timezone, timezone}}

  defp utc_zone?(timezone), do: String.upcase(timezone) in @utc_zones

  defp parse_windows(windows) when is_list(windows) and windows != [] do
    windows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {window, index}, {:ok, acc} ->
      case parse_window(window, index) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, error} -> {:error, error}
    end
  end

  defp parse_windows(_windows), do: {:error, :no_windows}

  defp parse_window(window, index) when is_map(window) do
    with {:ok, raw_days} <- fetch_window_key(window, :days),
         {:ok, days} <- parse_days(raw_days),
         {:ok, raw_start} <- fetch_window_key(window, :start_time),
         {:ok, raw_end} <- fetch_window_key(window, :end_time),
         {:ok, start_time} <- parse_time(raw_start, "start_time"),
         {:ok, end_time} <- parse_time(raw_end, "end_time") do
      {:ok, %{days: days, start_time: start_time, end_time: end_time}}
    else
      {:error, message} -> {:error, {:invalid_window, index, message}}
    end
  end

  defp parse_window(_window, index), do: {:error, {:invalid_window, index, "must be a map"}}

  # Windows arrive as JSONB maps with string keys from the API and with atom
  # keys from seeds and tests. Both are read; neither is turned into an atom.
  defp fetch_window_key(window, key) do
    with :error <- Map.fetch(window, Atom.to_string(key)),
         :error <- Map.fetch(window, key) do
      {:error, "missing #{key}"}
    end
  end

  defp parse_days(days) when is_list(days) and days != [] do
    days
    |> Enum.reduce_while({:ok, []}, fn day, {:ok, acc} ->
      case day_token(day) do
        nil -> {:halt, {:error, "unknown day #{inspect(day)}"}}
        token -> {:cont, {:ok, [token | acc]}}
      end
    end)
    |> case do
      {:ok, tokens} -> {:ok, MapSet.new(tokens)}
      {:error, message} -> {:error, message}
    end
  end

  defp parse_days(_days), do: {:error, "days must be a non-empty list of day-of-week tokens"}

  defp day_token(day) when is_binary(day) do
    downcased = String.downcase(day)
    if downcased in @day_tokens, do: downcased
  end

  defp day_token(day) when is_atom(day) and not is_nil(day), do: day_token(Atom.to_string(day))
  defp day_token(_day), do: nil

  defp parse_time(%Time{} = time, _field), do: {:ok, time}

  defp parse_time(value, field) when is_binary(value) do
    value
    |> pad_seconds()
    |> Time.from_iso8601()
    |> case do
      {:ok, time} -> {:ok, time}
      {:error, _reason} -> {:error, "#{field} must be a HH:MM or HH:MM:SS wall-clock time"}
    end
  end

  defp parse_time(_value, field),
    do: {:error, "#{field} must be a HH:MM or HH:MM:SS wall-clock time"}

  defp pad_seconds(value) do
    if Regex.match?(~r/^\d{2}:\d{2}$/, value), do: value <> ":00", else: value
  end

  # Start inclusive, end exclusive. `end_time > start_time` is enforced by the
  # resource validator, so no window wraps midnight and containment stays a
  # plain comparison; exclusive ends also keep two adjacent windows from both
  # claiming their shared boundary instant.
  defp window_contains?(window, %DateTime{} = local) do
    window_contains?(window, DateTime.to_date(local), DateTime.to_time(local))
  end

  defp window_contains?(window, %NaiveDateTime{} = local) do
    window_contains?(window, NaiveDateTime.to_date(local), NaiveDateTime.to_time(local))
  end

  defp window_contains?(window, date, time) do
    day = elem(@days, Date.day_of_week(date) - 1)

    MapSet.member?(window.days, day) and
      Time.compare(time, window.start_time) != :lt and
      Time.before?(time, window.end_time)
  end

  # --- Small shared helpers -------------------------------------------------

  defp fetch_now!(context) do
    case Map.fetch(context, :now) do
      {:ok, %DateTime{} = now} ->
        now

      _other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} requires `:now` in the context as a DateTime; " <>
                "the evaluation instant is an input so a decision is reproducible"
    end
  end

  defp step_condition(context) do
    case field(Map.get(context, :step), :condition) do
      :always -> :always
      _other -> :if_unacknowledged
    end
  end

  defp provider_deactivated?(nil), do: false
  defp provider_deactivated?(provider), do: field(provider, :status) not in [nil, :active]

  defp field(nil, _key), do: nil

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp field(_other, _key), do: nil

  defp fetch_first(sources) do
    Enum.find_value(sources, fn {source, key} -> field(source, key) end)
  end

  # Detail maps are persisted into a jsonb column, so they are flattened to
  # JSON-encodable values here. Atoms become strings; nothing becomes an atom.
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
end
