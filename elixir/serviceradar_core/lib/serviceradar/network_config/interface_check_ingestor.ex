defmodule ServiceRadar.NetworkConfig.InterfaceCheckIngestor do
  @moduledoc """
  Records interface config check verdicts (`serviceradar.interface_config_check.v1`)
  on the checked devices.

  Each verdict becomes two top-level metadata keys on the device:

    * `config_check_<check>` - `compliant`, `non_compliant` or `unknown`. A
      scalar, so SRQL can filter on it: `metadata.config_check_nac:non_compliant`.
      SRQL reads only top-level metadata keys, which is why the status is not
      nested.
    * `config_check_<check>_detail` - `checked_at`, `switch`, `interface`,
      `reason` and `missing`, for display.

  Writes go through `Device.merge_metadata`: one atomic top-level merge that
  leaves every other key untouched and never creates a device. A verdict for a
  UID that does not exist is skipped and counted. Only `config_check_*` keys are
  ever written, so a plugin result cannot reach any other metadata.

  Options:

    * `:device_store` - module with `fetch(uid, actor)` and
      `merge(device, patch, actor)`. Defaults to the Device resource. Override
      in tests.
  """

  alias ServiceRadar.Actors.SystemActor

  require Logger

  @schema "serviceradar.interface_config_check.v1"
  @statuses ~w(compliant non_compliant unknown)
  @check_name ~r/^[a-z][a-z0-9_]{0,43}$/
  @max_verdicts 10_000
  @max_missing 32
  @max_text 512

  defmodule DeviceStore do
    @moduledoc false
    alias ServiceRadar.Inventory.Device

    def fetch(uid, actor) do
      case Device.get_by_uid(uid, false, actor: actor) do
        {:ok, %Device{} = device} -> {:ok, device}
        {:ok, nil} -> :not_found
        {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} -> :not_found
        {:error, reason} -> {:error, reason}
      end
    end

    def merge(device, patch, actor) do
      device
      |> Ash.Changeset.for_update(:merge_metadata, %{metadata_patch: patch})
      |> Ash.update(actor: actor)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec supports?(map() | list(), map()) :: boolean()
  def supports?(payload, status \\ %{})

  def supports?(payload, status) when is_list(payload),
    do: Enum.any?(payload, &supports?(&1, status))

  def supports?(payload, _status) when is_map(payload),
    do: Map.get(details_map(payload), "schema") == @schema

  def supports?(_payload, _status), do: false

  @spec ingest(map() | list(), map(), keyword()) :: :ok | {:error, term()}
  def ingest(payload, status, opts \\ [])

  def ingest(payload, status, opts) when is_list(payload) do
    payload
    |> Enum.filter(&supports?(&1, status))
    |> Enum.reduce_while(:ok, fn item, :ok ->
      case ingest(item, status, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def ingest(payload, _status, opts) when is_map(payload) do
    store = Keyword.get(opts, :device_store, DeviceStore)
    actor = Keyword.get(opts, :actor) || SystemActor.system(:plugin_result_ingestor)

    with {:ok, patches} <- patches_by_device(details_map(payload)) do
      patches
      |> Enum.reduce(%{recorded: 0, skipped: 0, errors: []}, fn {uid, patch}, acc ->
        record(store, uid, patch, actor, acc)
      end)
      |> finish()
    end
  end

  @doc false
  @spec patches_by_device(map()) :: {:ok, %{String.t() => map()}} | {:error, term()}
  def patches_by_device(%{"verdicts" => verdicts}) when is_list(verdicts) do
    if length(verdicts) > @max_verdicts do
      {:error, :interface_check_too_many_verdicts}
    else
      {:ok,
       Enum.reduce(verdicts, %{}, fn verdict, acc ->
         case normalize_verdict(verdict) do
           {:ok, uid, check, entry} ->
             Map.update(
               acc,
               uid,
               entry_patch(check, entry),
               &Map.merge(&1, entry_patch(check, entry))
             )

           :invalid ->
             acc
         end
       end)}
    end
  end

  def patches_by_device(_details), do: {:error, :interface_check_invalid_result}

  defp normalize_verdict(%{"device_uid" => uid, "check" => check, "status" => status} = verdict)
       when is_binary(uid) and is_binary(check) and status in @statuses do
    uid = String.trim(uid)

    if uid != "" and Regex.match?(@check_name, check) do
      detail =
        Map.reject(
          %{
            "checked_at" => text(verdict["checked_at"]),
            "switch" => text(verdict["switch"]),
            "interface" => text(verdict["interface"]),
            "reason" => text(verdict["reason"]),
            "missing" => missing(verdict["missing"])
          },
          fn {_key, value} -> value in [nil, "", []] end
        )

      {:ok, uid, check, %{status: status, detail: detail}}
    else
      :invalid
    end
  end

  defp normalize_verdict(_verdict), do: :invalid

  defp entry_patch(check, %{status: status, detail: detail}) do
    %{"config_check_#{check}" => status, "config_check_#{check}_detail" => detail}
  end

  defp record(store, uid, patch, actor, acc) do
    case store.fetch(uid, actor) do
      {:ok, device} ->
        case store.merge(device, patch, actor) do
          :ok -> %{acc | recorded: acc.recorded + 1}
          {:error, reason} -> %{acc | errors: [{uid, reason} | acc.errors]}
        end

      :not_found ->
        %{acc | skipped: acc.skipped + 1}

      {:error, reason} ->
        %{acc | errors: [{uid, reason} | acc.errors]}
    end
  end

  defp finish(%{errors: [], skipped: skipped}) do
    if skipped > 0,
      do:
        Logger.info("Interface config check verdicts skipped for unknown devices",
          skipped: skipped
        )

    :ok
  end

  defp finish(%{errors: errors} = result) do
    Logger.warning("Interface config check verdicts failed to record",
      failed: length(errors),
      recorded: result.recorded
    )

    {:error, {:interface_check_record_failed, length(errors)}}
  end

  defp text(value) when is_binary(value), do: value |> String.trim() |> String.slice(0, @max_text)
  defp text(_value), do: nil

  defp missing(values) when is_list(values) do
    values |> Enum.filter(&is_binary/1) |> Enum.take(@max_missing) |> Enum.map(&text/1)
  end

  defp missing(_values), do: []

  defp details_map(payload) do
    case Map.get(payload, "details") || Map.get(payload, :details) do
      details when is_map(details) ->
        details

      details when is_binary(details) ->
        case Jason.decode(details) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end
end
