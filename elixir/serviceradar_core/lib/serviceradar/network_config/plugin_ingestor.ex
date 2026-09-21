defmodule ServiceRadar.NetworkConfig.PluginIngestor do
  @moduledoc """
  Ingests OpenText running-config plugin results into `network_config_revisions`.

  The plugin submits the body as an artifact/result; this module does not
  parse interface stanzas. Downparser runs inside `NetworkConfig.Ingest`.
  """

  alias ServiceRadar.NetworkConfig.Ingest

  @spec supports?(map() | list(), map()) :: boolean()
  def supports?(payload, status \\ %{})

  def supports?(payload, status) when is_list(payload) do
    Enum.any?(payload, &supports?(&1, status))
  end

  def supports?(payload, _status) when is_map(payload) do
    kind?(payload) and extract_body(payload) not in [nil, ""]
  end

  def supports?(_payload, _status), do: false

  @spec ingest(map() | list(), map(), keyword()) :: :ok | {:error, term()}
  def ingest(payload, _status, opts \\ [])

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

  @spec extract(map()) :: {:ok, map()} | {:error, term()}
  def extract(payload) when is_map(payload) do
    device_uid = extract_device_uid(payload)
    body = extract_body(payload)

    if device_uid in [nil, ""] or body in [nil, ""] do
      {:error, :missing_running_config}
    else
      {:ok,
       %{
         device_uid: device_uid,
         source: "opentext-nom",
         config_kind: :running,
         body: body
       }}
    end
  end

  def ingest(payload, _status, opts) when is_map(payload) do
    case extract(payload) do
      {:error, reason} ->
        {:error, reason}

      {:ok, attrs} ->
        case Ingest.submit(
               attrs,
               Keyword.take(opts, [:actor, :parser, :projector])
             ) do
          {:ok, _status, _revision} -> :ok
          {:ok, _status, _revision, _facts} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp kind?(payload) do
    labels = Map.get(payload, "labels") || Map.get(payload, :labels) || %{}
    details = details_map(payload)

    Map.get(labels, "kind") == "running_config" or
      Map.get(labels, :kind) == "running_config" or
      Map.get(details, "kind") == "running_config" or
      Map.get(details, "config_kind") == "running"
  end

  defp extract_device_uid(payload) do
    labels = Map.get(payload, "labels") || Map.get(payload, :labels) || %{}
    details = details_map(payload)

    Map.get(labels, "device_uid") ||
      Map.get(labels, :device_uid) ||
      Map.get(details, "device_uid") ||
      Map.get(payload, "device_uid")
  end

  defp extract_body(payload) do
    details = details_map(payload)
    Map.get(details, "body") || Map.get(payload, "body")
  end

  defp details_map(payload) do
    case Map.get(payload, "details") || Map.get(payload, :details) do
      details when is_map(details) -> details
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
