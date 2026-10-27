defmodule ServiceRadar.Inventory.Availability.Resolver do
  @moduledoc """
  The merged availability decision for one device (`add-merged-device-availability`,
  design Decisions 3, 5, 6 and 12). Pure: everything it needs is passed in.

  Inputs are the device's per-agent ledger rows (`active_probe`), its evidence records,
  its vantage expectations, its effective `availability_source_agent_id` pin and its
  previous decision. The resolver never branches on a source kind: precedence comes
  only from the authority class, freshness, confirmation, the pin and the expectations.

  1. Expired evidence and evidence from an ineligible reporter are ignored. A ledger row
     is fresh while `checked_at + ttl > now`; a row whose reporter expectation is
     `unexpected` or `unknown` is ineligible, except that the pinned agent's row is
     ineligible only when `unknown`.
  2. An agent a check expects to be blocked is a negative control: its fresh `down` row
     is a verified block and leaves the decision, its fresh `up` row stays in it as
     ordinary liveness and is counted as a policy violation, and no fresh row is an
     inconclusive control.
  3. With a pin, other agents' ledger rows leave the decision (they remain counted), and
     so does `operator_policy` evidence: the per-device pin outranks a composite check's
     policy (Open Question 5). A pin on a negative control is ignored and reported as
     invalid.
  4. An `up` row is decisive at once; a `down` row once its confirmations reach its
     class threshold.
  5. The governing class is the strongest class with any row left in the decision. Its
     decisive rows decide; with only pending rows the previous state holds.
  6. Within the deciding class any decisive `up` wins.
  7. With no row left the state is `unknown`.
  8. The previous decider stays the decider while it still agrees; otherwise the most
     recent agreeing row decides.
  9. `conflict` is set when fresh decisive evidence outside the deciding class, or a
     pinned-out agent or policy record, disagrees. Negative controls have their own counters.
  """

  alias ServiceRadar.Inventory.Availability.AuthorityClass

  @ledger_kind "agent_probe"
  @ineligible_expectations ["unexpected", "unknown"]

  defmodule Decision do
    @moduledoc "A resolved availability: what `Resolution` writes to the device row."

    @enforce_keys [:state, :decided_by, :conflict, :agents, :changed_at]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            state: :available | :unavailable | :unknown,
            decided_by: map(),
            conflict: boolean(),
            agents: map(),
            changed_at: DateTime.t()
          }
  end

  @type state :: :available | :unavailable | :unknown

  @type ledger_row :: %{
          required(:agent_id) => String.t(),
          required(:available?) => boolean(),
          required(:checked_at) => DateTime.t(),
          required(:consecutive_down) => non_neg_integer(),
          required(:ttl_seconds) => pos_integer(),
          optional(:sweep_group_id) => String.t() | nil,
          optional(:reporter_expectation) => String.t() | nil
        }

  @type evidence_row :: %{
          required(:source_kind) => String.t(),
          required(:source_instance) => String.t(),
          required(:reporter_agent_id) => String.t(),
          required(:authority_class) => AuthorityClass.t(),
          required(:state) => :up | :down,
          required(:observed_at) => DateTime.t(),
          required(:expires_at) => DateTime.t(),
          required(:confirmations) => pos_integer(),
          required(:reporter_eligible) => boolean()
        }

  @type previous :: %{state: state(), decided_by: map() | nil, changed_at: DateTime.t() | nil}

  @type device :: %{pin: String.t() | nil, previous: previous() | nil}

  @type inputs :: %{
          ledger: [ledger_row()],
          evidence: [evidence_row()],
          expectations: %{String.t() => :reachable | :blocked}
        }

  @doc "The source kind recorded when a per-agent ledger row decides."
  @spec ledger_kind() :: String.t()
  def ledger_kind, do: @ledger_kind

  @spec resolve(device(), inputs(), DateTime.t()) :: Decision.t()
  def resolve(device, inputs, now) do
    controls =
      for {agent_id, :blocked} <- Map.get(inputs, :expectations, %{}), into: MapSet.new() do
        agent_id
      end

    pin = blank_to_nil(Map.get(device, :pin))
    invalid_pin? = is_binary(pin) and MapSet.member?(controls, pin)
    pin = if invalid_pin?, do: nil, else: pin

    ledger = Enum.map(Map.get(inputs, :ledger, []), &ledger_candidate(&1, now, pin, controls))
    evidence = Enum.flat_map(Map.get(inputs, :evidence, []), &evidence_candidate(&1, now, pin))
    candidates = ledger ++ evidence

    previous = Map.get(device, :previous)
    {state, rule, governing, decider} = decide(candidates, previous)

    %Decision{
      state: state,
      decided_by:
        rule
        |> decided_by(decider, previous, state)
        |> Map.put("invalid_pin", invalid_pin?),
      conflict: conflict?(state, governing, candidates),
      agents: agents(ledger, controls),
      changed_at: changed_at(previous, state, now)
    }
  end

  # -- candidates ------------------------------------------------------------------------

  defp ledger_candidate(row, now, pin, controls) do
    fresh? = DateTime.after?(DateTime.shift(row.checked_at, second: row.ttl_seconds), now)
    control? = MapSet.member?(controls, row.agent_id)

    role =
      cond do
        not fresh? -> :stale
        control? and not row.available? -> :control_down
        not ledger_eligible?(row, pin) -> :ineligible
        is_binary(pin) and row.agent_id != pin -> :pinned_out
        true -> :decision
      end

    state = if row.available?, do: :up, else: :down

    %{
      key: {@ledger_kind, row |> Map.get(:sweep_group_id) |> text(), row.agent_id},
      class: :active_probe,
      state: state,
      at: row.checked_at,
      decisive?:
        state == :up or
          row.consecutive_down >= AuthorityClass.confirmation_threshold(:active_probe),
      role: role,
      control?: control?,
      fresh?: fresh?
    }
  end

  defp ledger_eligible?(row, pin) do
    case Map.get(row, :reporter_expectation) do
      "unknown" -> false
      expectation when expectation in @ineligible_expectations -> row.agent_id == pin
      _ -> true
    end
  end

  defp evidence_candidate(row, now, pin) do
    if row.reporter_eligible and DateTime.after?(row.expires_at, now) do
      [
        %{
          key: {row.source_kind, row.source_instance, row.reporter_agent_id},
          class: row.authority_class,
          state: row.state,
          at: row.observed_at,
          decisive?:
            row.state == :up or
              row.confirmations >= AuthorityClass.confirmation_threshold(row.authority_class),
          role: evidence_role(row.authority_class, pin)
        }
      ]
    else
      []
    end
  end

  # The per-device pin outranks operator policy (Open Question 5): a policy record leaves
  # the decision like a pinned-out agent and still counts as a conflict.
  defp evidence_role(:operator_policy, pin) when is_binary(pin), do: :pinned_out
  defp evidence_role(_class, _pin), do: :decision

  # -- decision --------------------------------------------------------------------------

  defp decide(candidates, previous) do
    case Enum.filter(candidates, &(&1.role == :decision)) do
      [] ->
        {:unknown, "no_evidence", nil, nil}

      decision_set ->
        governing =
          decision_set
          |> Enum.map(& &1.class)
          |> Enum.min_by(&AuthorityClass.rank/1)

        decisive = Enum.filter(decision_set, &(&1.class == governing and &1.decisive?))

        if decisive == [] do
          {previous_state(previous), "hysteresis_hold", governing, :previous}
        else
          state = if Enum.any?(decisive, &(&1.state == :up)), do: :available, else: :unavailable
          agreeing = Enum.filter(decisive, &(&1.state == agreeing_state(state)))
          {state, "highest_class", governing, decider(agreeing, previous)}
        end
    end
  end

  defp agreeing_state(:available), do: :up
  defp agreeing_state(:unavailable), do: :down

  defp previous_state(%{state: state}) when state in [:available, :unavailable, :unknown],
    do: state

  defp previous_state(_previous), do: :unknown

  # The previous decider keeps deciding while it is still among the agreeing decisive
  # rows of the deciding class, so a renewal by another agreeing source changes nothing.
  # Otherwise the most recent row decides; among equally recent rows the smallest key, so
  # the choice does not depend on input order.
  defp decider(agreeing, previous) do
    previous_key = previous_decider_key(previous)

    Enum.find(agreeing, &(&1.key == previous_key)) ||
      agreeing
      |> Enum.sort_by(& &1.key)
      |> Enum.max_by(&DateTime.to_unix(&1.at, :microsecond))
  end

  defp previous_decider_key(%{decided_by: %{"source_kind" => kind} = decided_by})
       when is_binary(kind) do
    {kind, Map.get(decided_by, "source_instance") || "",
     Map.get(decided_by, "reporter_agent_id") || ""}
  end

  defp previous_decider_key(_previous), do: nil

  defp decided_by(rule, :previous, previous, state) do
    source = (previous && previous.decided_by) || %{}

    rule
    |> base_decided_by(
      Map.get(source, "source_kind"),
      Map.get(source, "source_instance"),
      Map.get(source, "reporter_agent_id"),
      Map.get(source, "authority_class")
    )
    |> Map.put("previous", previous_entry(previous, state))
  end

  defp decided_by(rule, nil, previous, state) do
    rule
    |> base_decided_by(nil, nil, nil, nil)
    |> Map.put("previous", previous_entry(previous, state))
  end

  defp decided_by(rule, %{key: {kind, instance, reporter}, class: class}, previous, state) do
    rule
    |> base_decided_by(kind, instance, reporter, Atom.to_string(class))
    |> Map.put("previous", previous_entry(previous, state))
  end

  defp base_decided_by(rule, kind, instance, reporter, class) do
    %{
      "rule" => rule,
      "source_kind" => kind,
      "source_instance" => instance,
      "reporter_agent_id" => reporter,
      "authority_class" => class
    }
  end

  # The last decided state before this one. It changes only on a transition, so a
  # resolution that keeps the state rewrites nothing.
  defp previous_entry(nil, _state), do: nil

  defp previous_entry(%{state: state} = previous, state),
    do: get_in(previous, [:decided_by, "previous"])

  defp previous_entry(previous, _state) do
    %{
      "state" => Atom.to_string(previous.state),
      "changed_at" => iso8601(previous.changed_at)
    }
  end

  defp changed_at(%{state: state, changed_at: %DateTime{} = changed_at}, state, _now),
    do: changed_at

  defp changed_at(_previous, _state, now), do: now

  # -- conflict and counters -------------------------------------------------------------

  defp conflict?(:unknown, _governing, _candidates), do: false

  defp conflict?(state, governing, candidates) do
    disagreeing = if state == :available, do: :down, else: :up

    Enum.any?(candidates, fn candidate ->
      not Map.get(candidate, :control?, false) and candidate.decisive? and
        candidate.state == disagreeing and
        ((candidate.role == :decision and candidate.class != governing) or
           candidate.role == :pinned_out)
    end)
  end

  defp agents(ledger, controls) do
    counters =
      Enum.reduce(
        ledger,
        %{
          "up" => 0,
          "down" => 0,
          "stale" => 0,
          "total" => 0,
          "blocked_verified" => 0,
          "policy_violation" => 0,
          "inconclusive_control" => 0
        },
        &count_ledger_row/2
      )

    fresh_controls =
      for %{control?: true, fresh?: true, key: {_kind, _instance, agent_id}} <- ledger,
          into: MapSet.new(),
          do: agent_id

    Map.put(
      counters,
      "inconclusive_control",
      MapSet.size(MapSet.difference(controls, fresh_controls))
    )
  end

  defp count_ledger_row(%{control?: true, fresh?: true, state: :down}, acc),
    do: Map.update!(acc, "blocked_verified", &(&1 + 1))

  defp count_ledger_row(%{control?: true, fresh?: true, state: :up}, acc),
    do: Map.update!(acc, "policy_violation", &(&1 + 1))

  defp count_ledger_row(%{control?: true}, acc), do: acc

  defp count_ledger_row(row, acc) do
    bucket =
      cond do
        not row.fresh? -> "stale"
        row.state == :up -> "up"
        true -> "down"
      end

    acc
    |> Map.update!(bucket, &(&1 + 1))
    |> Map.update!("total", &(&1 + 1))
  end

  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso8601(_at), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
