defmodule ServiceRadar.Notifications.Escalation do
  @moduledoc """
  Plans which rungs of an escalation ladder are due, and when (design D4, C6,
  C10).

  Like `ServiceRadar.Notifications.Suppression`, this module is a **pure
  function over plain maps**: no Ash, no Ecto, no `Repo`, no process state, and
  no `DateTime.utc_now/0`. The evaluation instant arrives as `context.now`. The
  caller loads the policy, its steps, each step's channel set, and the alert,
  calls `plan/1`, and persists the resulting `NotificationDelivery` rows.

  ## This module owns ESCALATION ONLY

  Design D4 keeps three mechanisms strictly separate, and conflating them is the
  most common design error in homegrown notification systems:

  | Mechanism | Level | Trigger | Bounded by |
  | --- | --- | --- | --- |
  | Retry | Transport | 5xx, timeout, 429 | channel `max_attempts`, Oban backoff |
  | Failover | Transport | Retries exhausted, or agent offline | one hop to `fallback_channel_id` |
  | **Escalation** | **Human** | **Step delay elapsed AND still unacknowledged** | **policy step count, `repeat_count`** |

  There is deliberately **no retry logic and no failover logic in this module**.
  It never inspects `attempt_count`, `max_attempts`, `next_attempt_at`,
  `fallback_channel_id`, `fail_closed`, or any transport outcome, and a transport
  failure can never make a step due earlier than its configured
  `delay_seconds`. Fan-out is orthogonal to all three: one step holds a **set**
  of channels and yields one dispatch per channel.

  ## `delay_seconds` is measured from the ALERT FIRE TIME

  This is the single most commonly mis-implemented rule in the platform. Step 2
  with `delay_seconds: 300` becomes due at `fire_time + 300s` - **not** at
  `step_1_dispatch + 300s`, and not at `step_1_completion + 300s`. Chaining
  delays off the previous dispatch makes total time-to-page depend on transport
  latency and retry behaviour, so a "5m / 15m" ladder silently becomes "5m / 15m
  plus however long two retries took" and the policy stops meaning what its
  author read.

  ## The one exception: snooze expiry rebases the origin

  After an alert's snooze expires, the delays of the steps that have not yet
  been dispatched are measured from the **snooze expiry instant**, because
  snoozing is an explicit operator statement that the clock should restart. No
  other event rebases the origin - not a dispatch, not a failure, not a
  failover, not an acknowledgement.

  The expiry instant is `alert.snooze_until` once it is at or before `now`;
  while `snooze_until` is still in the future the origin remains the fire time
  and `Suppression` withholds each due dispatch with `:snoozed`, which is what
  leaves the audit trail design D5 requires. Clearing a snooze (`update
  :unsnooze`, or `update :acknowledge`, which nils `snooze_until`) returns the
  origin to the fire time, so dispatch resumes immediately rather than waiting
  out a deferral the operator just cancelled.

  ## Acknowledgement

  A step whose `condition` is `:if_unacknowledged` does not dispatch while the
  alert is acknowledged; a `:always` step still fires, for ladders that must
  reach a downstream system even after a human has taken the page. An
  acknowledged alert also halts policy repeats.

  A withheld `:if_unacknowledged` rung is **not** dropped - design D5 prohibits
  silent drops. It is returned in `withheld` as `{:acknowledged, dispatch}` so
  the caller records a `NotificationDelivery` row with `state: :suppressed` and
  `suppression_reason: :acknowledged`. The acknowledgement predicate itself is
  `ServiceRadar.Notifications.Suppression.acknowledged?/1`, called rather than
  reimplemented, so the ladder gate and the recorded reason can never disagree.

  ## Repeats and the C10 cadence floor

  `repeat_count` replays the whole ladder that many additional times.
  `repeat_interval_seconds` is the gap between replays, so cycle `r` starts at

      origin + r * (ladder_span + effective_interval)

  where `ladder_span` is the largest `delay_seconds` in the ladder. Measuring
  the gap from the end of the previous cycle is what keeps cycles from
  overlapping: anchoring each cycle at `origin + r * interval` interleaves
  replays as soon as the ladder is longer than the interval, which would page
  more often than either knob says.

  `StatefulAlertRule.renotify_seconds` is the **floor** (design D6/C10): a
  policy may only make repeats LESS frequent. That is enforced at save time by
  `ServiceRadar.Notifications.Validations.RepeatIntervalFloor` against the
  strictest floor the deployment presents, but a rule can be enabled or lowered
  afterwards, so `plan/1` re-checks per alert against the rule that actually
  fired. When a policy interval is below the governing rule's floor, the
  interval is **clamped up to the floor** and a `:repeat_interval_clamped`
  diagnostic is returned. Paging more often than the rule authorises is not an
  option; failing silently is not either.

  Note that the floor governs **repeats**, not the rungs inside one ladder. A
  ladder whose steps sit minutes apart still pages at those offsets - that is
  what an escalation ladder is for.

  ## Context

  Plain map, atom keys. Values may be Ash structs or plain maps.

    * `:now` - **required** `DateTime`.
    * `:fire_time` - the alert fire time. Falls back to `alert.triggered_at`
      then `alert.created_at`; a context with none of the three raises.
    * `:alert` - used to derive acknowledgement, resolution, and snooze state.
    * `:policy` - `:repeat_count`, `:repeat_interval_seconds`.
    * `:steps` - the ladder. Each step carries `:step_number`, `:delay_seconds`,
      `:condition`, and its channel set as `:channel_ids` or as `:channels`
      (maps or structs with an `:id`).
    * `:renotify_seconds` - the governing rule's floor. Falls back to
      `rule.renotify_seconds`.
    * `:rule` - the stateful alert rule.
    * `:acknowledged`, `:resolved`, `:snooze_until` - explicit overrides for the
      values otherwise derived from `:alert`.
    * `:dispatched` - dispatches already created, as `{step_number, channel_id,
      due_at}` tuples (list or `MapSet`). They are excluded from `dispatches`.
      Withheld decisions are deliberately NOT excluded, because
      `NotificationDelivery`'s `:record_suppression` upsert collapses a repeat
      of an identical decision onto the existing row and increments its
      occurrence counter, which is how an operator sees both *why* and *how
      often*.

  ## Result

      %{
        dispatches: [{step_number, channel_id, due_at}],
        withheld: [{:acknowledged, {step_number, channel_id, due_at}}],
        diagnostics: [%{code: atom(), ...}],
        next_due_at: DateTime.t() | nil,
        origin: DateTime.t(),
        halted: nil | :acknowledged | :resolved,
        effective_repeat_interval_seconds: pos_integer() | nil
      }

  `due_at` is the **scheduled** instant, never `now`, so a delivery row records
  when the rung was owed rather than when the scheduler happened to wake.
  `halted` means the ladder will not advance past what is listed.

  See `openspec/changes/add-notification-platform/design.md` (D4, D6) and the
  "Escalation policies and ordered steps", "Escalation step fan-out to a channel
  set", "Human escalation requires elapsed delay and continued
  non-acknowledgement", and "Retry, failover, and escalation SHALL NOT be
  conflated" requirements.
  """

  alias ServiceRadar.Notifications.Suppression

  @type channel_id :: term()
  @type dispatch :: {step_number :: pos_integer(), channel_id(), due_at :: DateTime.t()}
  @type withheld :: {:acknowledged, dispatch()}
  @type diagnostic :: %{required(:code) => atom(), optional(atom()) => term()}
  @type context :: %{optional(atom()) => term()}

  @type plan :: %{
          dispatches: [dispatch()],
          withheld: [withheld()],
          diagnostics: [diagnostic()],
          next_due_at: DateTime.t() | nil,
          origin: DateTime.t(),
          halted: nil | :acknowledged | :resolved,
          effective_repeat_interval_seconds: pos_integer() | nil
        }

  @conditions [:always, :if_unacknowledged]

  @doc """
  Plans the dispatches that are due at `context.now`.

  Every returned dispatch has `due_at <= now`. The caller still runs
  `ServiceRadar.Notifications.Suppression.evaluate/1` per dispatch immediately
  before invoking a transport (design D5 re-evaluation), because a rung being
  temporally due says nothing about whether a silence, schedule, snooze, or
  device state withholds it.
  """
  @spec plan(context()) :: plan()
  def plan(context) when is_map(context) do
    now = fetch_now!(context)
    alert = Map.get(context, :alert)
    origin = delay_origin(context)

    {steps, step_diagnostics} = normalize_steps(Map.get(context, :steps))
    acknowledged? = acknowledged?(context, alert)
    resolved? = resolved?(context, alert)

    {repeat_count, interval, repeat_diagnostics} = repeat_plan(context, steps, acknowledged?)
    diagnostics = step_diagnostics ++ repeat_diagnostics

    candidates = candidates(steps, origin, repeat_count, interval)
    {due, upcoming} = Enum.split_with(candidates, fn {_step, dispatch} -> due?(dispatch, now) end)

    {dispatches, withheld} = partition(due, acknowledged?, resolved?)

    %{
      dispatches: dispatches |> sort_dispatches() |> reject_dispatched(context),
      withheld: sort_withheld(withheld),
      diagnostics: diagnostics,
      next_due_at: earliest(upcoming, resolved?),
      origin: origin,
      halted: halted(acknowledged?, resolved?),
      effective_repeat_interval_seconds: interval
    }
  end

  @doc """
  The instant the ladder's `delay_seconds` offsets are measured from.

  The alert fire time, except after a snooze expiry, which is the one event that
  rebases it. Exposed because it is the rule most worth asserting directly.

  A snooze expiry earlier than the fire time is not physically reachable -
  `update :snooze` refuses a timestamp that is not in the future - but if one is
  supplied the later of the two wins, so rebasing can never pull a rung earlier
  than its fire-time anchor.
  """
  @spec delay_origin(context()) :: DateTime.t()
  def delay_origin(context) when is_map(context) do
    now = fetch_now!(context)
    fire_time = fetch_fire_time!(context)

    case snooze_expiry(context, now) do
      nil -> fire_time
      expiry -> latest(expiry, fire_time)
    end
  end

  @doc """
  The instant a step becomes due for a given origin.
  """
  @spec due_at(DateTime.t(), non_neg_integer()) :: DateTime.t()
  def due_at(%DateTime{} = origin, delay_seconds) when is_integer(delay_seconds) do
    DateTime.add(origin, delay_seconds, :second)
  end

  # --- Candidate generation -------------------------------------------------

  # One entry per (cycle x step x channel). Cycle 0 is the initial run of the
  # ladder; cycles 1..repeat_count are the policy repeats.
  defp candidates(steps, origin, repeat_count, interval) do
    span = ladder_span(steps)

    Enum.flat_map(0..repeat_count//1, fn cycle ->
      cycle_origin = cycle_origin(origin, cycle, span, interval)

      Enum.flat_map(steps, fn step ->
        due_at = due_at(cycle_origin, step.delay_seconds)

        Enum.map(step.channel_ids, fn channel_id ->
          {step, {step.step_number, channel_id, due_at}}
        end)
      end)
    end)
  end

  defp cycle_origin(origin, 0, _span, _interval), do: origin

  defp cycle_origin(origin, cycle, span, interval) when is_integer(interval) do
    DateTime.add(origin, cycle * (span + interval), :second)
  end

  defp ladder_span([]), do: 0
  defp ladder_span(steps), do: steps |> Enum.map(& &1.delay_seconds) |> Enum.max()

  defp due?({_step_number, _channel_id, due_at}, now), do: DateTime.compare(due_at, now) != :gt

  # A resolved alert plans nothing: resolution notification is `resolve_notifies`
  # on the policy, a separate flow, not a rung of the ladder.
  defp partition(_due, _acknowledged?, true = _resolved?), do: {[], []}

  defp partition(due, acknowledged?, _resolved?) do
    {dispatches, withheld} =
      Enum.reduce(due, {[], []}, fn {step, dispatch}, {dispatches, withheld} ->
        if acknowledged? and step.condition == :if_unacknowledged do
          {dispatches, [{:acknowledged, dispatch} | withheld]}
        else
          {[dispatch | dispatches], withheld}
        end
      end)

    {Enum.reverse(dispatches), Enum.reverse(withheld)}
  end

  defp earliest(_upcoming, true = _resolved?), do: nil

  defp earliest(upcoming, _resolved?) do
    upcoming
    |> Enum.map(fn {_step, {_step_number, _channel_id, due_at}} -> due_at end)
    |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp halted(_acknowledged?, true = _resolved?), do: :resolved
  defp halted(true = _acknowledged?, _resolved?), do: :acknowledged
  defp halted(_acknowledged?, _resolved?), do: nil

  # `Enum.sort_by/2` is stable, so the channel order inside a step's fan-out set
  # is preserved and the plan is byte-for-byte reproducible.
  defp sort_dispatches(dispatches) do
    Enum.sort_by(dispatches, fn {step_number, _channel_id, due_at} ->
      {DateTime.to_unix(due_at, :microsecond), step_number}
    end)
  end

  defp sort_withheld(withheld) do
    withheld
    |> Enum.map(fn {:acknowledged, dispatch} -> dispatch end)
    |> sort_dispatches()
    |> Enum.map(&{:acknowledged, &1})
  end

  # Excludes dispatches the caller has already created. Identity is compared on
  # microseconds since the epoch rather than on the `DateTime` struct, because
  # two structurally different structs can name the same instant - a `:second`
  # precision timestamp read back from Postgres does not `==` the `:microsecond`
  # one that produced it, and list subtraction would silently re-emit the
  # dispatch.
  defp reject_dispatched(dispatches, context) do
    case dispatched_keys(context) do
      nil -> dispatches
      keys -> Enum.reject(dispatches, &MapSet.member?(keys, dispatch_key(&1)))
    end
  end

  defp dispatched_keys(context) do
    case Map.get(context, :dispatched) do
      nil -> nil
      %MapSet{} = dispatched -> dispatched |> MapSet.to_list() |> dispatched_keys_from_list()
      dispatched when is_list(dispatched) -> dispatched_keys_from_list(dispatched)
      _other -> nil
    end
  end

  defp dispatched_keys_from_list(dispatched) do
    dispatched
    |> Enum.flat_map(fn
      {_step_number, _channel_id, %DateTime{}} = dispatch -> [dispatch_key(dispatch)]
      _other -> []
    end)
    |> MapSet.new()
  end

  defp dispatch_key({step_number, channel_id, due_at}) do
    {step_number, channel_id, DateTime.to_unix(due_at, :microsecond)}
  end

  # --- Steps ----------------------------------------------------------------

  defp normalize_steps(nil), do: {[], []}

  defp normalize_steps(steps) when is_list(steps) do
    steps
    |> Enum.map(&normalize_step/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.step_number)
    |> collect_step_diagnostics()
  end

  defp normalize_steps(_steps), do: {[], []}

  defp normalize_step(step) when is_map(step) do
    step_number = field(step, :step_number)

    if is_integer(step_number) do
      %{
        step_number: step_number,
        delay_seconds: delay_seconds(field(step, :delay_seconds)),
        condition: condition(field(step, :condition)),
        raw_condition: field(step, :condition),
        channel_ids: channel_ids(step)
      }
    end
  end

  defp normalize_step(_step), do: nil

  defp delay_seconds(value) when is_integer(value) and value >= 0, do: value
  defp delay_seconds(_value), do: 0

  # The resource default is `:if_unacknowledged`, and it is the safe default:
  # defaulting an unrecognised condition to `:always` would page an
  # acknowledged incident.
  defp condition(value) when value in @conditions, do: value
  defp condition(_value), do: :if_unacknowledged

  defp channel_ids(step) do
    case field(step, :channel_ids) do
      ids when is_list(ids) -> Enum.reject(ids, &is_nil/1)
      _other -> step |> field(:channels) |> channel_ids_from_channels()
    end
  end

  defp channel_ids_from_channels(channels) when is_list(channels) do
    channels
    |> Enum.map(fn
      channel when is_map(channel) -> field(channel, :id)
      id -> id
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp channel_ids_from_channels(_channels), do: []

  # Configuration smells that make a ladder quietly not do what it says. None of
  # them stops planning; each is reported so an operator can see it.
  defp collect_step_diagnostics(steps) do
    diagnostics =
      empty_channel_diagnostics(steps) ++
        duplicate_step_diagnostics(steps) ++
        monotonicity_diagnostics(steps) ++
        condition_diagnostics(steps)

    {steps, diagnostics}
  end

  defp empty_channel_diagnostics(steps) do
    for %{channel_ids: []} = step <- steps,
        do: %{code: :step_without_channels, step_number: step.step_number}
  end

  defp duplicate_step_diagnostics(steps) do
    steps
    |> Enum.frequencies_by(& &1.step_number)
    |> Enum.filter(fn {_step_number, count} -> count > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {step_number, count} ->
      %{code: :duplicate_step_number, step_number: step_number, count: count}
    end)
  end

  defp monotonicity_diagnostics(steps) do
    steps
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [previous, current] -> current.delay_seconds < previous.delay_seconds end)
    |> Enum.map(fn [previous, current] ->
      %{
        code: :non_monotonic_delay,
        step_number: current.step_number,
        delay_seconds: current.delay_seconds,
        previous_step_number: previous.step_number,
        previous_delay_seconds: previous.delay_seconds
      }
    end)
  end

  defp condition_diagnostics(steps) do
    for step <- steps,
        not is_nil(step.raw_condition),
        step.raw_condition not in @conditions,
        do: %{
          code: :unknown_step_condition,
          step_number: step.step_number,
          condition: step.raw_condition
        }
  end

  # --- Repeats --------------------------------------------------------------

  # Acknowledgement halts repeats outright (spec: "Repeat stops on
  # acknowledgement"). An `:always` step inside a repeat cycle does not resurrect
  # the repeat, because the repeat itself is the human-escalation mechanism the
  # acknowledgement answered.
  defp repeat_plan(_context, _steps, true = _acknowledged?), do: {0, nil, []}

  defp repeat_plan(context, _steps, _acknowledged?) do
    policy = Map.get(context, :policy)
    repeat_count = repeat_count(field(policy, :repeat_count))
    configured = field(policy, :repeat_interval_seconds)
    floor = renotify_floor(context)

    cond do
      repeat_count == 0 ->
        {0, nil, []}

      not (is_integer(configured) and configured > 0) ->
        {0, nil, [%{code: :repeat_interval_missing, repeat_count: repeat_count}]}

      is_integer(floor) and floor > configured ->
        {repeat_count, floor,
         [
           %{
             code: :repeat_interval_clamped,
             configured_seconds: configured,
             floor_seconds: floor,
             effective_seconds: floor
           }
         ]}

      true ->
        {repeat_count, configured, []}
    end
  end

  defp repeat_count(value) when is_integer(value) and value > 0, do: value
  defp repeat_count(_value), do: 0

  defp renotify_floor(context) do
    case Map.get(context, :renotify_seconds) do
      value when is_integer(value) and value > 0 -> value
      _other -> field(Map.get(context, :rule), :renotify_seconds)
    end
  end

  # --- Alert state ----------------------------------------------------------

  defp acknowledged?(context, alert) do
    case Map.get(context, :acknowledged) do
      value when is_boolean(value) -> value
      _other -> Suppression.acknowledged?(alert)
    end
  end

  defp resolved?(context, alert) do
    case Map.get(context, :resolved) do
      value when is_boolean(value) -> value
      _other -> field(alert, :status) in [:resolved, :suppressed]
    end
  end

  # The expiry instant, or nil while the snooze is still running or was never
  # set. A snooze that has not expired leaves the origin at the fire time and
  # lets Suppression record `:snoozed` per dispatch.
  defp snooze_expiry(context, now) do
    snooze_until =
      case Map.fetch(context, :snooze_until) do
        {:ok, value} -> value
        :error -> field(Map.get(context, :alert), :snooze_until)
      end

    if match?(%DateTime{}, snooze_until) and DateTime.compare(snooze_until, now) != :gt do
      snooze_until
    end
  end

  # --- Small shared helpers -------------------------------------------------

  defp fetch_now!(context) do
    case Map.fetch(context, :now) do
      {:ok, %DateTime{} = now} ->
        now

      _other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} requires `:now` in the context as a DateTime; " <>
                "the evaluation instant is an input so a plan is reproducible"
    end
  end

  defp fetch_fire_time!(context) do
    alert = Map.get(context, :alert)

    [
      Map.get(context, :fire_time),
      field(alert, :triggered_at),
      field(alert, :created_at)
    ]
    |> Enum.find(&match?(%DateTime{}, &1))
    |> case do
      %DateTime{} = fire_time ->
        fire_time

      nil ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} requires the alert fire time as `:fire_time`, " <>
                "`alert.triggered_at`, or `alert.created_at`; every step delay is " <>
                "measured from it"
    end
  end

  defp latest(%DateTime{} = left, %DateTime{} = right) do
    if DateTime.before?(left, right), do: right, else: left
  end

  defp field(nil, _key), do: nil

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp field(_other, _key), do: nil
end
