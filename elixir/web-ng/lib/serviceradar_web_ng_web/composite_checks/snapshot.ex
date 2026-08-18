defmodule ServiceRadarWebNGWeb.CompositeChecks.Snapshot do
  @moduledoc """
  Renders one composite check input snapshot for display.

  A snapshot is what the evaluator recorded for an input: `%{"value",
  "observed_at", "stale", "reason"}`, keyed by input key. Both the authoring
  preview and the device detail page render the same shape, and both are bound
  by the same rule — an input with no result reads `unknown` with its reason,
  never blank and never raw JSON. Keeping that rule in one module is what stops
  the two surfaces from disagreeing about what "no data" looks like.
  """

  @type view :: %{
          key: String.t(),
          label: String.t(),
          kind: atom(),
          expected: String.t() | nil,
          value: String.t(),
          observed_at: DateTime.t() | nil,
          age: String.t(),
          stale: boolean(),
          reason: String.t() | nil
        }

  @doc """
  A display row for `input`, given the snapshot recorded for it.

  `now` is the reference the age is measured against. The preview passes the
  evaluation's own `now` so the rendered age cannot disagree with the resolver's
  staleness verdict; device detail passes the wall clock, because the result it
  is rendering was recorded some time ago.
  """
  @spec view(struct() | map(), map() | nil, DateTime.t()) :: view()
  def view(input, snapshot, now) do
    observed_at = observed_at(snapshot)

    %{
      key: input.key,
      label: input.label || input.key,
      kind: input.kind,
      expected: input.expected,
      value: value(snapshot),
      observed_at: observed_at,
      age: age(observed_at, now),
      stale: stale?(snapshot),
      reason: reason(snapshot)
    }
  end

  @doc """
  The recorded value, or `"unknown"` when there is none.

  A blank cell reads as "nothing to say". `unknown` is the actual state, and it
  is the state that keeps a check from being enabled.
  """
  @spec value(map() | nil) :: String.t()
  def value(nil), do: "unknown"

  def value(snapshot) do
    case Map.get(snapshot, "value") do
      value when is_binary(value) and value != "" -> value
      _other -> "unknown"
    end
  end

  @spec reason(map() | nil) :: String.t() | nil
  def reason(nil), do: nil
  def reason(snapshot), do: Map.get(snapshot, "reason")

  @spec stale?(map() | nil) :: boolean()
  def stale?(nil), do: false
  def stale?(snapshot), do: Map.get(snapshot, "stale") == true

  @doc "The snapshot's observation time, or nil when it never reported."
  @spec observed_at(map() | nil) :: DateTime.t() | nil
  def observed_at(nil), do: nil

  def observed_at(snapshot) do
    case Map.get(snapshot, "observed_at") do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _error -> nil
        end

      %DateTime{} = datetime ->
        datetime

      _other ->
        nil
    end
  end

  @doc """
  A relative age, or `"never"` when there is no observation.

  `"never"` rather than a dash: it is the reason the input is unknown, and a
  dash would read as missing formatting rather than missing data.
  """
  @spec age(DateTime.t() | nil, DateTime.t()) :: String.t()
  def age(nil, _now), do: "never"

  def age(observed_at, now) do
    case DateTime.diff(now, observed_at, :second) do
      seconds when seconds < 0 -> "just now"
      seconds when seconds < 60 -> "#{seconds}s ago"
      seconds when seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds -> "#{div(seconds, 86_400)}d ago"
    end
  end
end
