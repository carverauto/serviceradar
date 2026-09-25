defmodule ServiceRadar.Inventory.Identity.DecisionLog do
  @moduledoc """
  Writes identity decisions to `platform.identity_decisions`
  (`ServiceRadar.Inventory.IdentityDecision`).

  Every path that blocks, declines or overrides a merge calls this next to its telemetry, so
  the decision can be reviewed and acted on later instead of living only in a log line
  (requirement "Identity Decisions Are Never Silent").

  Recording is best-effort by design: the decision itself has already been made (the merge
  did not happen, the alias is stale), and failing the ingest because its audit row could not
  be written would drop the device update as well. A failed write is logged and counted
  (`[:serviceradar, :identity_reconciler, :decision, :record_failed]`), so the failure is not
  silent either.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.IdentityDecision

  require Logger

  @type decision :: %{
          required(:kind) => atom(),
          required(:reason) => String.t(),
          required(:device_uids) => [String.t()],
          optional(:subject) => String.t() | nil,
          optional(:source) => String.t() | nil,
          optional(:evidence) => map()
        }

  @doc """
  Records one decision. `opts`: `:subject` (the address the decision is about), `:source` (the
  code path) and `:evidence` (a JSON-encodable map).

  A decision naming no device is not recorded: there is nothing to review.
  """
  @spec record(atom(), String.t(), [String.t()], keyword()) :: :ok
  def record(kind, reason, device_uids, opts \\ []) do
    record_many([
      %{
        kind: kind,
        reason: reason,
        device_uids: device_uids,
        subject: Keyword.get(opts, :subject),
        source: Keyword.get(opts, :source),
        evidence: Keyword.get(opts, :evidence, %{})
      }
    ])
  end

  @doc "Records several decisions in one bulk write."
  @spec record_many([decision()]) :: :ok
  def record_many(decisions) when is_list(decisions) do
    inputs =
      decisions
      |> Enum.map(&to_input/1)
      |> Enum.reject(&is_nil/1)
      # One row per key: a batch naming the same decision twice would otherwise ask the
      # upsert to touch one row twice in one statement.
      |> Enum.uniq_by(&input_key/1)

    case inputs do
      [] -> :ok
      inputs -> write(inputs)
    end
  end

  defp write(inputs) do
    result =
      Ash.bulk_create(inputs, IdentityDecision, :record,
        actor: SystemActor.system(:identity_decisions),
        return_errors?: true,
        stop_on_error?: false,
        return_records?: false
      )

    case result do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{errors: errors} ->
        record_failed(inputs, errors)
    end
  rescue
    e -> record_failed(inputs, e)
  end

  defp record_failed(inputs, error) do
    Logger.warning(
      "Failed to record #{length(inputs)} identity decision(s) " <>
        "#{inspect(Enum.map(inputs, &{&1.decision_kind, &1.device_uids}))}: #{inspect(error)}"
    )

    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :decision, :record_failed],
      %{count: length(inputs)},
      %{kinds: inputs |> Enum.map(& &1.decision_kind) |> Enum.uniq()}
    )

    :ok
  end

  defp to_input(%{kind: kind, reason: reason, device_uids: uids} = decision)
       when is_atom(kind) and is_binary(reason) and is_list(uids) do
    case IdentityDecision.normalize_uids(uids) do
      [] ->
        nil

      uids ->
        %{
          decision_kind: kind,
          reason: reason,
          device_uids: uids,
          subject: blank_to_nil(Map.get(decision, :subject)),
          source: blank_to_nil(Map.get(decision, :source)),
          evidence: json_safe(Map.get(decision, :evidence) || %{})
        }
    end
  end

  defp to_input(_decision), do: nil

  defp input_key(input) do
    IdentityDecision.decision_key(
      input.decision_kind,
      input.reason,
      input.device_uids,
      input.subject
    )
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  # Evidence comes from callers as maps with atom keys, tuples and structs. Store what JSON can
  # carry and stringify the rest, so a caller's shape can never fail the write.
  @doc false
  def json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def json_safe(%{__struct__: _} = value), do: inspect(value)

  def json_safe(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {json_key(k), json_safe(v)} end)
  end

  def json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  def json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  def json_safe(value) when is_boolean(value) or is_nil(value), do: value
  def json_safe(value) when is_atom(value), do: Atom.to_string(value)
  def json_safe(value) when is_binary(value) or is_number(value), do: value
  def json_safe(value), do: inspect(value)

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: inspect(key)
end
