defmodule ServiceRadar.Notifications.Dedupe do
  @moduledoc """
  Derives the deduplication key for an incident, and answers cadence questions
  about it (design D6).

  Pure functions over plain maps. No Ash, no repo, no process state, and `now`
  is always a parameter - a cadence decision that reads the clock cannot be
  replayed, and replaying one is what an operator asking "why did this page
  twice?" is doing.

  ## The incident identity already exists; this module consumes it

  Design D6 is explicit that the notification platform does not invent a second
  incident identity. The identity is the composite `{rule_id, group_key}`, where
  `group_key` is the `"field=value|field=value"` string built by
  `ServiceRadar.Observability.StatefulAlertEngine.Record.build_group/2` from
  `StatefulAlertRule.group_by`, made unique by
  `stateful_alert_rule_states_unique_state_index`. Both halves are already
  written onto the alert by
  `AlertLifecycle.merge_incident_metadata/5` as `alerts.metadata`
  `"incident_rule_id"` and `"incident_group_key"`, so this module reads them
  from there rather than re-deriving them from a record it does not have.

  The key format keeps that convention verbatim:

      rule=<rule_id>|group=<group_key>
      rule=8f1c...|group=device_id=abc|severity=high

  A rule with no `group_by` produces the group key `"global"`, which is what
  `build_group/2` returns for `nil` and `[]`. That constant is matched here, not
  reinvented.

  ## Alerts with no incident identity

  Two alert-creation paths bypass the stateful engine entirely and create alerts
  with no deduplication at all - `LogPromotion.update_alert_counts/2` and
  `TrivyReports.maybe_create_priority_alert/3` - and design D5 calls them out by
  name. Such an alert has no `{rule_id, group_key}`, so its identity is the
  alert itself and the key is `alert=<alert_id>`. That is the correct answer
  rather than a fallback: those paths create a fresh alert per occurrence, so
  each one genuinely is its own incident. An alert with neither identity yields
  `{:error, :no_incident_identity}` and never a guessed key, because a guessed
  key silently merges unrelated incidents.

  ## The route override

  `NotificationRoute.dedupe_key_template` is the only sanctioned deviation. It
  is rendered by `ServiceRadar.Notifications.Renderer.render_string/4` in
  `:plain` form - the same substitution engine that renders notification
  subjects and bodies, gated by the same
  `ServiceRadar.Notifications.Template.Syntax` validation. There is deliberately
  no second renderer here: a dedupe key rendered by a private engine would drift
  from the body rendered by the shared one, and the operator who wrote
  `{{ alert.severity | upper }}` in both places would eventually get two
  different answers.

  A template that renders to nothing is an error, not an empty key. An empty key
  collapses every incident in the deployment onto one dedupe identity, which
  suppresses every page after the first.

  ## Cadence: the rule is the floor

  `StatefulAlertRule.cooldown_seconds` and `renotify_seconds` are consumed as
  authored. `NotificationEscalationPolicy.repeat_interval_seconds` and
  `NotificationRoute.throttle_seconds` may only make an incident **quieter**, so
  the effective cadence is the maximum of whichever of the four are present.
  Taking the maximum is what makes "narrow only" structural: no combination of
  notification-layer configuration can page more often than the rule authorises.
  `check_cadence_floor/2` is the per-alert re-check that
  `ServiceRadar.Notifications.Validations.RepeatIntervalFloor` defers to it, for
  the two cases save-time validation cannot cover - a rule enabled or lowered
  after the policy was saved, and an alert from a path that bypasses the engine.

  A dispatch withheld by cadence is `{:withheld, :throttled, _}`, which is the
  `suppression_reason` the caller records.
  """

  alias ServiceRadar.Notifications.Renderer

  # `Record.build_group/2` returns this for a rule with no `group_by`. Matched,
  # not reinvented.
  @global_group_key "global"

  # Long enough for any realistic group key, short enough to stay readable in
  # the Delivery Log and index cheaply. Over the cap the key is truncated and
  # fingerprinted rather than cut, so two long keys that share a prefix stay
  # distinct.
  @max_key_bytes 512
  @digest_hex_length 16

  @type alert :: map()
  @type route :: map()
  @type identity :: {:incident, String.t(), String.t()} | {:alert, String.t()}

  @type cadence :: %{optional(atom()) => term()}

  @type cadence_decision ::
          {:due, %{effective_seconds: non_neg_integer(), next_eligible_at: DateTime.t() | nil}}
          | {:withheld, :throttled,
             %{effective_seconds: non_neg_integer(), next_eligible_at: DateTime.t()}}

  @doc """
  The group key used for an incident whose rule declares no `group_by`.
  """
  @spec global_group_key() :: String.t()
  def global_group_key, do: @global_group_key

  @doc """
  Extracts the incident identity from an alert.

  Prefers the `{rule_id, group_key}` composite written into `alerts.metadata` by
  the alert lifecycle, then a `rule_id` carried directly on the alert map, then
  the alert's own id. Returns `{:error, :no_incident_identity}` when the alert
  carries none of them.
  """
  @spec incident_identity(alert()) :: {:ok, identity()} | {:error, :no_incident_identity}
  def incident_identity(alert) when is_map(alert) do
    case {rule_id(alert), alert_id(alert)} do
      {rule_id, _alert_id} when is_binary(rule_id) ->
        {:ok, {:incident, rule_id, group_key(alert)}}

      {_rule_id, alert_id} when is_binary(alert_id) ->
        {:ok, {:alert, alert_id}}

      _neither ->
        {:error, :no_incident_identity}
    end
  end

  def incident_identity(_alert), do: {:error, :no_incident_identity}

  @doc """
  Formats an identity as the default dedupe key.

  The format follows `Record.build_group/2`'s `"field=value"` convention so the
  composite reads the same way the group key it embeds does.
  """
  @spec default_key(identity()) :: String.t()
  def default_key({:incident, rule_id, group_key}) do
    "rule=" <> rule_id <> "|group=" <> group_key
  end

  def default_key({:alert, alert_id}), do: "alert=" <> alert_id

  @doc """
  Derives the dedupe key for an alert, honouring a route's optional override.

  Options:

    * `:subject` - the substitution subject for `dedupe_key_template`. Defaults
      to `subject/1`, which exposes the incident identity under the catalog
      paths `alert.rule_id` and `alert.group_key` in addition to the alert's own
      attributes.

  Returns `{:error, {:invalid_template, message}}` for a template the grammar
  rejects, `{:error, :empty_dedupe_key}` for one that renders to nothing, and
  `{:error, :no_incident_identity}` when there is no template and no identity to
  fall back on.
  """
  @spec dedupe_key(alert(), route() | nil, keyword()) ::
          {:ok, String.t()}
          | {:error, :no_incident_identity | :empty_dedupe_key | {:invalid_template, String.t()}}
  def dedupe_key(alert, route \\ nil, opts \\ [])

  def dedupe_key(alert, route, opts) when is_map(alert) do
    case template(route) do
      nil -> default_dedupe_key(alert)
      template -> rendered_dedupe_key(template, Keyword.get(opts, :subject) || subject(alert))
    end
  end

  def dedupe_key(_alert, _route, _opts), do: {:error, :no_incident_identity}

  @doc """
  Builds the substitution subject for `dedupe_key_template`.

  `Template.Syntax` publishes `alert.rule_id` and `alert.group_key` in its
  variable catalog, but neither is an attribute of `ServiceRadar.Monitoring.Alert` -
  the lifecycle writes them into `alerts.metadata` under `incident_*` keys. The
  subject therefore overlays the resolved identity onto those catalog paths, so
  a template written against the published catalog resolves instead of silently
  rendering the empty string.
  """
  @spec subject(alert()) :: map()
  def subject(alert) when is_map(alert) do
    overlay = %{
      "rule_id" => rule_id(alert),
      "group_key" => group_key(alert)
    }

    %{"alert" => Map.merge(plain_map(alert), overlay)}
  end

  @doc """
  The idempotency key of a routing request (design D6, "Routing requests are
  idempotent").

  Keyed by `{alert_id, lifecycle_reason, step_number, dedupe_key}`. Re-emitting
  the same tuple - a duplicate lifecycle callback, an Oban retry, a scheduler
  tick that overlaps the previous one - resolves to the existing work rather
  than a second dispatch, which only holds if every emitter derives the key the
  same way. It is derived here, next to the dedupe key it embeds, so there is
  one derivation rather than one per emitter.

  `lifecycle_reason` records *why* the lifecycle emitted (fire, renotify,
  escalate, resolve) and is what distinguishes two otherwise identical requests
  for the same alert and step. A request missing `alert_id`,
  `lifecycle_reason`, or `dedupe_key` yields an error rather than a key with a
  hole in it: two different requests that collapse onto one key drop a page.
  `step_number` is genuinely optional - a first notification has no step - and
  renders as `-`.
  """
  @spec routing_request_key(map()) :: {:ok, String.t()} | {:error, :incomplete_routing_request}
  def routing_request_key(request) when is_map(request) do
    alert_id = normalize_id(lookup(request, :alert_id))
    reason = normalize_segment(lookup(request, :lifecycle_reason))
    dedupe_key = normalize_id(lookup(request, :dedupe_key))
    step = step_segment(lookup(request, :step_number))

    if is_nil(alert_id) or is_nil(reason) or is_nil(dedupe_key) do
      {:error, :incomplete_routing_request}
    else
      {:ok,
       bound(
         "alert=" <>
           alert_id <> "|reason=" <> reason <> "|step=" <> step <> "|dedupe=" <> dedupe_key
       )}
    end
  end

  def routing_request_key(_request), do: {:error, :incomplete_routing_request}

  defp step_segment(step) when is_integer(step), do: Integer.to_string(step)
  defp step_segment(step), do: normalize_segment(step) || "-"

  defp normalize_segment(value) when is_atom(value) and not is_nil(value) do
    Atom.to_string(value)
  end

  defp normalize_segment(value), do: normalize_id(value)

  # --- Cadence --------------------------------------------------------------

  @doc """
  The effective seconds between repeats for an incident.

  The maximum of `:cooldown_seconds`, `:renotify_seconds`, `:throttle_seconds`,
  and `:repeat_interval_seconds`, treating a missing, nil, non-integer, or
  negative value as zero. The maximum is what enforces design D6's precedence:
  the rule sets the floor and notification configuration can only be quieter.
  """
  @spec effective_cadence_seconds(cadence()) :: non_neg_integer()
  def effective_cadence_seconds(cadence) when is_map(cadence) do
    [:cooldown_seconds, :renotify_seconds, :throttle_seconds, :repeat_interval_seconds]
    |> Enum.map(&seconds(cadence, &1))
    |> Enum.max()
  end

  def effective_cadence_seconds(_cadence), do: 0

  @doc """
  The earliest instant a repeat may be dispatched.

  `nil` when the incident has never been notified, which is not "immediately in
  the past" but "no previous dispatch to measure from".
  """
  @spec next_eligible_at(DateTime.t() | nil, integer() | nil) :: DateTime.t() | nil
  def next_eligible_at(nil, _cadence_seconds), do: nil

  def next_eligible_at(%DateTime{} = last_notified_at, cadence_seconds) do
    DateTime.add(last_notified_at, normalize_seconds(cadence_seconds), :second)
  end

  @doc """
  Whether a repeat is due.

  An incident that has never been notified is always due. Otherwise the cadence
  must have fully elapsed; the boundary instant itself counts as elapsed, so a
  scheduler tick landing exactly on it does not defer a page by one whole tick.
  """
  @spec renotify_due?(DateTime.t() | nil, integer() | nil, DateTime.t()) :: boolean()
  def renotify_due?(last_notified_at, cadence_seconds, %DateTime{} = now) do
    case next_eligible_at(last_notified_at, cadence_seconds) do
      nil -> true
      due_at -> DateTime.compare(now, due_at) != :lt
    end
  end

  @doc """
  Decides whether a dispatch may proceed under the incident's cadence.

  `cadence` carries any of `:last_notified_at`, `:cooldown_seconds`,
  `:renotify_seconds`, `:throttle_seconds`, and `:repeat_interval_seconds`.
  A withheld decision names `:throttled`, which is the `suppression_reason` the
  caller records, and reports when the dispatch becomes eligible so the caller
  can schedule rather than poll.
  """
  @spec evaluate_cadence(cadence(), DateTime.t()) :: cadence_decision()
  def evaluate_cadence(cadence, %DateTime{} = now) do
    effective_seconds = effective_cadence_seconds(cadence)
    last_notified_at = datetime(cadence, :last_notified_at)

    case next_eligible_at(last_notified_at, effective_seconds) do
      nil ->
        {:due, %{effective_seconds: effective_seconds, next_eligible_at: nil}}

      due_at ->
        details = %{effective_seconds: effective_seconds, next_eligible_at: due_at}

        if DateTime.before?(now, due_at) do
          {:withheld, :throttled, details}
        else
          {:due, details}
        end
    end
  end

  @doc """
  Re-checks a configured cadence against the rule floor for one alert.

  `ServiceRadar.Notifications.Validations.RepeatIntervalFloor` enforces the
  strictest floor the deployment can present at save time and documents that the
  dispatcher re-checks per alert against the rule that actually fired. This is
  that check. A nil floor or a nil configured value is `:ok`: there is nothing
  to compare, and an alert from a path that bypasses the stateful engine has no
  rule floor at all.
  """
  @spec check_cadence_floor(integer() | nil, integer() | nil) ::
          :ok | {:error, {:below_cadence_floor, %{floor: integer(), configured: integer()}}}
  def check_cadence_floor(floor_seconds, configured_seconds)
      when is_integer(floor_seconds) and is_integer(configured_seconds) and
             configured_seconds < floor_seconds do
    {:error, {:below_cadence_floor, %{floor: floor_seconds, configured: configured_seconds}}}
  end

  def check_cadence_floor(_floor_seconds, _configured_seconds), do: :ok

  # --- Default key ----------------------------------------------------------

  defp default_dedupe_key(alert) do
    case incident_identity(alert) do
      {:ok, identity} -> {:ok, bound(default_key(identity))}
      {:error, reason} -> {:error, reason}
    end
  end

  # `:plain` is the right form for a key: its escape/1 is the identity, so the
  # rendered text is what the operator wrote rather than something HTML- or
  # JSON-escaped for a wire format the key never travels on.
  defp rendered_dedupe_key(template, subject) do
    case Renderer.render_string(template, subject, :plain, field: :dedupe_key_template) do
      {:ok, rendered, _unresolved} -> finish_rendered(rendered)
      {:error, {:invalid_template, %{message: message}}} -> {:error, {:invalid_template, message}}
      {:error, reason} -> {:error, {:invalid_template, Renderer.describe_error(reason)}}
    end
  end

  defp finish_rendered(rendered) do
    case String.trim(rendered || "") do
      "" -> {:error, :empty_dedupe_key}
      key -> {:ok, bound(key)}
    end
  end

  # Truncating alone would merge two long keys that share a prefix, which is the
  # exact failure a dedupe key exists to prevent, so the retained prefix carries
  # a digest of the whole key.
  defp bound(key) when byte_size(key) <= @max_key_bytes, do: key

  defp bound(key) do
    digest =
      :sha256
      |> :crypto.hash(key)
      |> Base.encode16(case: :lower)
      |> binary_part(0, @digest_hex_length)

    prefix_length = @max_key_bytes - @digest_hex_length - 1

    key
    |> binary_part(0, prefix_length)
    |> trim_to_valid()
    |> Kernel.<>("#" <> digest)
  end

  # A byte-boundary cut can land inside a UTF-8 codepoint, and the column is
  # text. Dropping the partial trailing bytes is safe: the digest, not the
  # prefix, is what keeps two long keys distinct.
  defp trim_to_valid(binary) do
    if String.valid?(binary) do
      binary
    else
      binary |> binary_part(0, byte_size(binary) - 1) |> trim_to_valid()
    end
  end

  # --- Identity extraction --------------------------------------------------

  defp rule_id(alert) do
    metadata = metadata(alert)

    Enum.find_value(
      [
        Map.get(metadata, "incident_rule_id"),
        Map.get(metadata, :incident_rule_id),
        lookup(alert, :rule_id)
      ],
      &normalize_id/1
    )
  end

  defp group_key(alert) do
    metadata = metadata(alert)

    [
      Map.get(metadata, "incident_group_key"),
      Map.get(metadata, :incident_group_key),
      lookup(alert, :group_key)
    ]
    |> Enum.find_value(&normalize_id/1)
    |> Kernel.||(@global_group_key)
  end

  defp alert_id(alert), do: normalize_id(lookup(alert, :id))

  defp metadata(alert) do
    case lookup(alert, :metadata) do
      metadata when is_map(metadata) -> metadata
      _other -> %{}
    end
  end

  defp normalize_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_id(_value), do: nil

  # --- Map access -----------------------------------------------------------

  defp template(nil), do: nil

  defp template(route) when is_map(route) do
    case lookup(route, :dedupe_key_template) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          _trimmed -> value
        end

      _other ->
        nil
    end
  end

  defp template(_route), do: nil

  defp seconds(cadence, key) do
    case lookup(cadence, key) do
      value when is_integer(value) and value > 0 -> value
      _other -> 0
    end
  end

  defp normalize_seconds(value) when is_integer(value) and value > 0, do: value
  defp normalize_seconds(_value), do: 0

  defp datetime(cadence, key) do
    case lookup(cadence, key) do
      %DateTime{} = value -> value
      _other -> nil
    end
  end

  # Alerts and routes arrive as Ash structs in production and as plain maps in
  # tests, seeds, and previews. Both are read, string key second so a struct's
  # real attribute always wins.
  defp lookup(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp lookup(_map, _key), do: nil

  defp plain_map(map) when is_struct(map), do: Map.from_struct(map)
  defp plain_map(map) when is_map(map), do: map
end
