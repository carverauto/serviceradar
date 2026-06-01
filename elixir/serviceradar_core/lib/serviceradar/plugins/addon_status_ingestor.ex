defmodule ServiceRadar.Plugins.AddonStatusIngestor do
  @moduledoc """
  Ingests per-add-on status from the agent capability status payload (issue 3425,
  task 7.2).

  The agent reports each supervised add-on as an `addon:<id>` entry in the
  `sidecars` array of its `agent` capability status (service_name "agent"). This
  decodes that payload and upserts a ServiceRadar.Plugins.AddonStatus row per add-on
  so Edge Ops can reconcile desired assignments against observed state.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonStatus

  require Logger

  @addon_prefix "addon:"

  @doc """
  Ingests add-on statuses from a forwarded agent service status map (atom-keyed,
  as built by the agent gateway). A non-add-on or undecodable payload is a no-op.
  """
  @spec ingest(map()) :: :ok
  def ingest(status) when is_map(status) do
    agent_uid = status[:agent_id] || status["agent_id"]

    with true <- is_binary(agent_uid) and agent_uid != "",
         {:ok, payload} <- decode_message(status[:message] || status["message"]),
         sidecars when is_list(sidecars) <- Map.get(payload, "sidecars", []) do
      actor = SystemActor.system(:addon_status_ingestor)
      reported_at = DateTime.truncate(DateTime.utc_now(), :microsecond)

      sidecars
      |> Enum.filter(&addon_sidecar?/1)
      |> Enum.each(&upsert_addon_status(&1, agent_uid, reported_at, actor))

      :ok
    else
      _ -> :ok
    end
  rescue
    error ->
      Logger.warning("AddonStatusIngestor failed: #{inspect(error)}")
      :ok
  end

  def ingest(_status), do: :ok

  defp decode_message(message) when is_binary(message), do: Jason.decode(message)
  defp decode_message(message) when is_map(message), do: {:ok, message}
  defp decode_message(_message), do: :error

  defp addon_sidecar?(%{"name" => name}) when is_binary(name),
    do: String.starts_with?(name, @addon_prefix)

  defp addon_sidecar?(_sidecar), do: false

  defp upsert_addon_status(sidecar, agent_uid, reported_at, actor) do
    addon_id = sidecar |> Map.get("name", "") |> String.replace_prefix(@addon_prefix, "")
    state = sidecar |> Map.get("state", "") |> to_string()

    if addon_id != "" and state != "" do
      attrs = %{
        agent_uid: agent_uid,
        addon_id: addon_id,
        state: state,
        active: state == "running",
        degradation_reason: blank_to_nil(Map.get(sidecar, "last_error")),
        pid: positive_integer_or_nil(Map.get(sidecar, "pid")),
        restart_count: non_negative_integer(Map.get(sidecar, "restart_count")),
        last_health_at: unix_nanos_to_datetime(Map.get(sidecar, "last_health_at")),
        version: blank_to_nil(Map.get(sidecar, "version")),
        arch: blank_to_nil(Map.get(sidecar, "arch")),
        reported_at: reported_at
      }

      AddonStatus
      |> Ash.Changeset.for_create(:report, attrs, actor: actor)
      |> Ash.create(actor: actor)
      |> case do
        {:ok, _} ->
          :ok

        {:error, error} ->
          Logger.warning("AddonStatus upsert failed for #{addon_id}: #{inspect(error)}")
      end
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp positive_integer_or_nil(value) when is_integer(value) and value > 0, do: value
  defp positive_integer_or_nil(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp unix_nanos_to_datetime(value) when is_integer(value) and value > 0 do
    case DateTime.from_unix(value, :nanosecond) do
      {:ok, dt} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp unix_nanos_to_datetime(_value), do: nil
end
