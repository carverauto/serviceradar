defmodule ServiceRadarWebNGWeb.DeviceLive.CompositeVerdictData do
  @moduledoc """
  Composite check verdicts recorded for one device.

  Sits beside the per-agent availability section, which is where the verdict
  belongs: the availability rows are the raw signal, and the verdict is what a
  check concluded from them. Reading them apart is how an operator ends up
  trusting a verdict without seeing that one vantage point never reported.

  Loads are batched across the device's results — one read per resource, not one
  per check — because a device can be in scope for several checks at once and
  this runs inside the device page's supplemental task fan-out.
  """

  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadarWebNGWeb.CompositeChecks.Snapshot

  require Ash.Query

  @type entry :: %{
          check_id: Ash.UUID.t(),
          check_name: String.t(),
          check_slug: String.t(),
          check_state: atom(),
          verdict: String.t(),
          verdict_label: String.t(),
          explanation: String.t() | nil,
          status: atom(),
          evaluated_at: DateTime.t(),
          changed_at: DateTime.t() | nil,
          inputs: [Snapshot.view()]
        }

  @doc """
  Verdicts recorded for `device_uid`.

  `opts` are Ash options — `scope:` from a LiveView, `actor:` elsewhere — plus
  an optional `:now` for the rendered ages.
  """
  @spec load(String.t() | nil, keyword()) :: [entry()]
  def load(device_uid, opts \\ [])

  def load(nil, _opts), do: []

  def load(device_uid, opts) when is_binary(device_uid) do
    {now, ash_opts} = Keyword.pop(opts, :now, DateTime.utc_now())

    case DeviceCompositeCheckResult.list_by_device(device_uid, ash_opts) do
      {:ok, []} -> []
      {:ok, results} -> build(results, ash_opts, now)
      {:error, _reason} -> []
    end
  end

  def load(_device_uid, _opts), do: []

  defp build(results, ash_opts, now) do
    check_ids = results |> Enum.map(& &1.check_id) |> Enum.uniq()

    checks = by_id(CompositeCheck, check_ids, ash_opts)
    inputs = inputs_by_check(check_ids, ash_opts)
    rules = rules_by_id(results, ash_opts)

    results
    |> Enum.flat_map(fn result ->
      case Map.get(checks, result.check_id) do
        nil -> []
        check -> [entry(result, check, Map.get(inputs, result.check_id, []), rules, now)]
      end
    end)
    |> Enum.sort_by(& &1.check_name)
  end

  defp entry(result, check, inputs, rules, now) do
    matched = Map.get(rules, result.matched_rule_id)

    %{
      check_id: check.id,
      check_name: check.name,
      check_slug: check.slug,
      check_state: check.state,
      verdict: result.verdict,
      verdict_label: (matched && matched.verdict_label) || result.verdict,
      explanation: matched && matched.verdict_description,
      status: result.status,
      evaluated_at: result.evaluated_at,
      changed_at: result.changed_at,
      inputs: input_views(result, inputs, now)
    }
  end

  # Driven by the check's inputs, not by the snapshot's keys. An input the
  # evaluator recorded nothing for must still appear — as unknown — because a
  # silently absent row is exactly how an operator misses that a vantage point
  # never reported.
  #
  # A snapshot key with no matching input is the reverse case: the input was
  # removed after this result was written. It is shown too, marked as no longer
  # part of the check, rather than dropped as though the verdict had not used it.
  defp input_views(result, inputs, now) do
    declared = Enum.map(inputs, &Snapshot.view(&1, Map.get(result.inputs, &1.key), now))
    known = MapSet.new(inputs, & &1.key)

    orphans =
      result.inputs
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.sort()
      |> Enum.map(fn key ->
        %{kind: :removed, key: key, label: key, expected: nil}
        |> Snapshot.view(Map.get(result.inputs, key), now)
        |> Map.put(:removed, true)
      end)

    Enum.map(declared, &Map.put(&1, :removed, false)) ++ orphans
  end

  defp by_id(resource, ids, ash_opts) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(ash_opts)
    |> case do
      {:ok, records} -> Map.new(records, &{&1.id, &1})
      {:error, _reason} -> %{}
    end
  end

  defp inputs_by_check(check_ids, ash_opts) do
    CompositeCheckInput
    |> Ash.Query.filter(check_id in ^check_ids)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read(ash_opts)
    |> case do
      {:ok, inputs} -> Enum.group_by(inputs, & &1.check_id)
      {:error, _reason} -> %{}
    end
  end

  defp rules_by_id(results, ash_opts) do
    case results |> Enum.map(& &1.matched_rule_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> %{}
      ids -> by_id(CompositeCheckRule, ids, ash_opts)
    end
  end
end
