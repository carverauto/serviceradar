defmodule ServiceRadar.Notifications.Router do
  @moduledoc """
  Pure route selection for an alert (design D6, and the "Notification routing
  rules" requirement).

  Given an alert, the enabled routes, and the instant the decision is being
  made, `match/3` answers which routes claim the alert and in what order. It is
  a pure function over plain maps: no Ash, no Ecto, no repo, no process state,
  and no `DateTime.utc_now/0`. `now` is a parameter because a routing decision
  that reads the clock cannot be replayed, and replaying a routing decision is
  exactly what an operator asking "why was I paged?" is doing.

  The caller loads routes, calls this, and persists what comes back. That split
  is what makes Alertmanager `continue` semantics, priority ordering, and the
  unrouted outcome testable with `async: true` and no database.

  ## Evaluation order

  Ascending `priority`, then ascending `id` as a stable tiebreak - the same
  order as the `:enabled` read action's sort and the partial index
  `notification_routes_priority_idx`. Two routes with the same priority and no
  id keep their input order, because `Enum.sort_by/2` is stable. Ordering is
  fixed rather than left to the database so a caller that assembled routes any
  other way still gets the documented order.

  ## Alertmanager `continue` semantics

  When a route matches and its `continue` is false - the default - evaluation
  **stops**. When `continue` is true, evaluation proceeds to the next route in
  order, so one alert can reach several ladders. This is deliberately the same
  knob Alertmanager exposes under the same name.

  Only enabled routes participate. A disabled route is not evaluated at all,
  which means a disabled route with `continue: false` stops nothing - its
  identifier is reported in `:disabled` so the caller can explain the shape of
  the decision without re-deriving it.

  ## Zero matches is an outcome, not an error and not a silence

  An alert matching no enabled route yields `outcome: :unrouted`. Per design D5
  and G10 the caller records that as a `NotificationDelivery` with
  `state: :suppressed` and `suppression_reason: :no_matching_route` - available
  from `suppression_reason/1` so the reason atom is not retyped at the call
  site. An unrouted alert is the one case that would otherwise silently produce
  nothing, which is exactly the failure operators cannot debug.

  Note that an `:unrouted` decision carrying a non-empty `errors` list means
  something different from an empty one: the alert was not routed because
  predicates failed, not because nothing claimed it. Both record
  `:no_matching_route` - the alert must stay visible either way - but a caller
  SHOULD log the errors, because a broken predicate is an operator-fixable
  configuration fault and an unclaimed alert is not.

  ## Nothing here crashes the pipeline

  A malformed `match_expression`, a predicate the grammar rejects, or a route
  map missing fields yields an entry in `errors` and evaluation continues with
  the next route. A route whose predicate errored is treated as **not matching**
  and specifically does not halt evaluation: letting a broken predicate consume
  the alert via `continue: false` would convert one bad route into a
  deployment-wide page outage.

  ## The matchable surface

  Predicates are evaluated by `ServiceRadar.Notifications.MatchExpression.Evaluator`
  against the subject built by `subject/1`, which namespaces the alert under
  `"alert"`. The paths a route may name are published by
  `ServiceRadar.Notifications.MatchExpression.Fields`, which is the *same*
  module `NotificationRoute` builds its save-time allow-list from. That is not a
  convenience: a path the validator admits but the evaluator cannot resolve is a
  route that saves cleanly and matches nothing, forever, silently.
  """

  alias ServiceRadar.Notifications.MatchExpression.Evaluator
  alias ServiceRadar.Notifications.MatchExpression.Fields

  # Mirrors NotificationRoute.priority's default, so a route map assembled
  # without it sorts where the resource would have put it.
  @default_priority 100

  @unrouted_reason :no_matching_route

  @type alert :: map()
  @type route :: map()

  @type match :: %{
          route: route(),
          route_id: term(),
          priority: integer(),
          continue: boolean(),
          escalation_policy_id: term(),
          schedule_id: term() | nil,
          dedupe_key_template: String.t() | nil,
          order: non_neg_integer()
        }

  @type error :: %{route: route(), route_id: term(), reason: String.t()}

  @type decision :: %{
          outcome: :routed | :unrouted,
          matched: [match()],
          errors: [error()],
          disabled: [term()],
          considered: non_neg_integer(),
          halted_by: term() | nil,
          evaluated_at: DateTime.t()
        }

  @doc """
  Selects the routes that claim `alert`, in evaluation order.

  `routes` is the candidate set in any order; ordering and the enabled filter
  are applied here. `now` is stamped onto the decision as `evaluated_at` and is
  never read from the clock.
  """
  @spec match(alert(), [route()], DateTime.t()) :: decision()
  def match(alert, routes, %DateTime{} = now) when is_map(alert) and is_list(routes) do
    subject = subject(alert)
    disabled = routes |> Enum.reject(&enabled?/1) |> Enum.map(&route_id/1)

    routes
    |> evaluation_order()
    |> Enum.with_index()
    |> Enum.reduce_while(initial(now, disabled), fn {route, index}, acc ->
      step(route, index, subject, acc)
    end)
    |> finalize()
  end

  @doc """
  The enabled routes in the order `match/3` will evaluate them.

  Exposed so a UI can show an operator the evaluation order it is configuring,
  and so a test can assert ordering independently of matching.
  """
  @spec evaluation_order([route()]) :: [route()]
  def evaluation_order(routes) when is_list(routes) do
    routes
    |> Enum.filter(&enabled?/1)
    |> Enum.sort_by(&sort_key/1)
  end

  @doc """
  Whether a route participates in evaluation.

  Only an explicit `false` disables a route. A route map that does not carry
  `enabled` at all is treated as participating, because the column is `NOT NULL`
  with a default of `true` and the alternative - silently dropping every route
  whose `enabled` was not selected - would turn a caller's `select` mistake into
  a deployment-wide page outage that reports itself as `:no_matching_route`.
  """
  @spec enabled?(route()) :: boolean()
  def enabled?(route) when is_map(route), do: fetch(route, :enabled) != false
  def enabled?(_route), do: false

  @doc """
  Evaluates one route's predicate against an alert, ignoring `enabled`.

  This is the "test this route against this alert" primitive. It deliberately
  does not consult `enabled`, because an operator testing a route they have not
  turned on yet still wants the answer.
  """
  @spec evaluate_route(route(), alert()) :: {:ok, boolean()} | {:error, String.t()}
  def evaluate_route(route, alert) when is_map(route) and is_map(alert) do
    Evaluator.evaluate(fetch(route, :match_expression), subject(alert))
  end

  @doc """
  Builds the evaluation subject for an alert.

  Route field paths are rooted at `alert.`, so the subject namespaces the alert
  under `"alert"`. Any other evaluation context that reuses the route grammar -
  silence matchers, for one - should build its subject the same way for the
  namespaces it publishes, or its paths resolve to nothing.
  """
  @spec subject(alert()) :: map()
  def subject(alert) when is_map(alert), do: %{"alert" => alert}

  @doc """
  Whether a decision routed the alert nowhere.
  """
  @spec unrouted?(decision()) :: boolean()
  def unrouted?(%{outcome: outcome}), do: outcome == :unrouted

  @doc """
  The suppression reason a caller records for a decision.

  `:no_matching_route` for an unrouted decision, `nil` otherwise. Returning the
  atom from here rather than retyping it at the call site keeps the recorded
  reason and the routing outcome from drifting apart.
  """
  @spec suppression_reason(decision()) :: :no_matching_route | nil
  def suppression_reason(decision) do
    if unrouted?(decision), do: @unrouted_reason
  end

  @doc """
  The routes a decision selected, without the surrounding audit detail.
  """
  @spec matched_routes(decision()) :: [route()]
  def matched_routes(%{matched: matched}), do: Enum.map(matched, & &1.route)

  @doc """
  The exact field paths a route's `match_expression` may name.
  """
  @spec matchable_fields() :: [String.t()]
  defdelegate matchable_fields(), to: Fields, as: :route_fields

  @doc """
  The field path prefixes a route's `match_expression` may name under.
  """
  @spec matchable_field_prefixes() :: [String.t()]
  defdelegate matchable_field_prefixes(), to: Fields, as: :route_field_prefixes

  # --- Evaluation -----------------------------------------------------------

  defp initial(now, disabled) do
    %{
      outcome: :unrouted,
      matched: [],
      errors: [],
      disabled: disabled,
      considered: 0,
      halted_by: nil,
      evaluated_at: now
    }
  end

  defp step(route, index, subject, acc) do
    acc = %{acc | considered: acc.considered + 1}

    case Evaluator.evaluate(fetch(route, :match_expression), subject) do
      {:ok, true} -> matched(route, index, acc)
      {:ok, false} -> {:cont, acc}
      {:error, reason} -> {:cont, record_error(route, reason, acc)}
    end
  end

  defp matched(route, index, acc) do
    acc = %{acc | matched: [build_match(route, index) | acc.matched]}

    if continue?(route) do
      {:cont, acc}
    else
      {:halt, %{acc | halted_by: route_id(route)}}
    end
  end

  defp record_error(route, reason, acc) do
    error = %{route: route, route_id: route_id(route), reason: reason}
    %{acc | errors: [error | acc.errors]}
  end

  defp finalize(acc) do
    matched = Enum.reverse(acc.matched)

    %{
      acc
      | matched: matched,
        errors: Enum.reverse(acc.errors),
        outcome: if(matched == [], do: :unrouted, else: :routed)
    }
  end

  defp build_match(route, index) do
    %{
      route: route,
      route_id: route_id(route),
      priority: priority(route),
      continue: continue?(route),
      escalation_policy_id: fetch(route, :escalation_policy_id),
      schedule_id: fetch(route, :schedule_id),
      dedupe_key_template: fetch(route, :dedupe_key_template),
      order: index
    }
  end

  # --- Route field access ---------------------------------------------------

  defp sort_key(route), do: {priority(route), to_string(route_id(route))}

  defp priority(route) do
    case fetch(route, :priority) do
      value when is_integer(value) -> value
      _other -> @default_priority
    end
  end

  defp continue?(route), do: fetch(route, :continue) == true

  defp route_id(route) when is_map(route), do: fetch(route, :id)
  defp route_id(_route), do: nil

  # Routes arrive as Ash structs from the `:enabled` read action, and as plain
  # maps from tests, seeds, and preview surfaces. Both are read, string key
  # second so a struct's real attribute always wins.
  defp fetch(route, key) when is_map(route) and is_atom(key) do
    case Map.fetch(route, key) do
      {:ok, value} -> value
      :error -> Map.get(route, Atom.to_string(key))
    end
  end

  defp fetch(_route, _key), do: nil
end
