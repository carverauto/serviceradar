defmodule ServiceRadar.NetworkConfig.PluginIngestor do
  @moduledoc """
  Ingests OpenText running-config plugin results into `network_config_revisions`.

  The plugin stages the running-config as an artifact and the result carries
  only a reference to it (`details.artifact`). The body is never read from the
  result details: those are persisted in `ServiceStatus.details`, which viewers
  can read, and running-configs routinely hold device secrets. This module
  fetches the artifact from the datasvc object store, checks it against the
  recorded SHA-256, and hands it to `NetworkConfig.Ingest`. It does not parse
  interface stanzas; the downparser runs inside `NetworkConfig.Ingest`.

  Options:

    * `:artifact_fetcher` - `(object_key -> {:ok, binary} | {:error, term})`.
      Defaults to the datasvc object-store download. Override in tests.
    * `:artifact_deleter` - deletes a staged object after every ingest attempt,
      including invalid results and failed downloads or parsing.
  """

  alias ServiceRadar.DataService.Client
  alias ServiceRadar.NetworkConfig.Ingest
  alias ServiceRadar.Sync.Client, as: SyncClient

  require Logger

  @artifact_timeout 30_000

  @spec supports?(map() | list(), map()) :: boolean()
  def supports?(payload, status \\ %{})

  def supports?(payload, status) when is_list(payload) do
    Enum.any?(payload, &supports?(&1, status))
  end

  def supports?(payload, _status) when is_map(payload) do
    kind?(payload)
  end

  def supports?(_payload, _status), do: false

  @spec ingest(map() | list(), map(), keyword()) :: :ok | {:error, term()}
  def ingest(payload, _status, opts \\ [])

  def ingest(payload, status, opts) when is_map(payload) or is_list(payload) do
    result =
      try do
        ingest_payload(payload, status, opts)
      rescue
        _error -> {:error, :running_config_ingest_failed}
      catch
        _kind, _reason -> {:error, :running_config_ingest_failed}
      end

    case discard_artifacts(payload, status, opts) do
      :ok -> result
      {:error, _reason} = error -> error
    end
  end

  defp ingest_payload(payload, status, opts) when is_list(payload) do
    payload
    |> Enum.filter(&supports?(&1, status))
    |> Enum.reduce_while(:ok, fn item, :ok ->
      case ingest_payload(item, status, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ingest_payload(payload, status, opts) do
    if details_map(payload)["complete"] == false do
      {:error, :running_config_result_incomplete}
    else
      payload
      |> config_entries()
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        case ingest_entry(entry, status, opts) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp ingest_entry(payload, status, opts) do
    with {:ok, ref} <- extract(payload),
         {:ok, body} <- fetch_body(ref, status, opts) do
      attrs =
        ref
        |> Map.take([:device_uid, :source, :config_kind])
        |> Map.put(:body, body)

      case Ingest.submit(attrs, Keyword.take(opts, [:actor, :parser, :projector])) do
        {:ok, _status, _revision} -> :ok
        {:ok, _status, _revision, _facts} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Deletes all owned NOM config artifacts, even when result validation fails."
  @spec discard_artifacts(map() | list(), map(), keyword()) :: :ok | {:error, term()}
  def discard_artifacts(payload, status, opts \\ []) do
    payload
    |> List.wrap()
    |> Enum.filter(&supports?(&1, status))
    |> Enum.flat_map(&config_entries/1)
    |> Enum.map(&{artifact_object_key(&1), assignment_id(&1)})
    |> Enum.reject(fn {key, _assignment} -> is_nil(key) end)
    |> Enum.uniq()
    |> Enum.reduce(:ok, fn {key, assignment}, result ->
      cleanup =
        with :ok <- authorize_object_key(key, assignment, status) do
          delete_artifact(key, opts)
        end

      case cleanup do
        :ok -> result
        {:error, _reason} ->
          Logger.warning("Staged running-config cleanup failed")
          {:error, :running_config_artifact_cleanup_failed}
      end
    end)
  end

  defp config_entries(payload) do
    case Map.fetch(details_map(payload), "running_configs") do
      :error -> [payload]
      {:ok, entries} when is_list(entries) and entries != [] ->
        Enum.map(entries, fn entry ->
          %{"labels" => Map.put(labels_map(payload), "kind", "running_config"), "details" => entry}
        end)
      {:ok, _invalid} -> [%{"details" => %{}}]
    end
  end

  defp delete_artifact(key, opts) do
    deleter = Keyword.get(opts, :artifact_deleter, &default_delete/1)

    case deleter.(key) do
      :ok -> :ok
      {:ok, _response} -> :ok
      _other -> {:error, :running_config_artifact_cleanup_failed}
    end
  rescue
    _error -> {:error, :running_config_artifact_cleanup_failed}
  catch
    _kind, _reason -> {:error, :running_config_artifact_cleanup_failed}
  end

  @doc """
  Extracts the device and artifact reference from a running-config result.
  The returned map never contains the config body.
  """
  @spec extract(map()) :: {:ok, map()} | {:error, term()}
  def extract(payload) when is_map(payload) do
    device_uid = extract_device_uid(payload)
    object_key = artifact_object_key(payload)
    sha256 = artifact_sha256(payload)

    if Enum.any?([device_uid, object_key, sha256], &(&1 in [nil, ""])) do
      {:error, :missing_running_config}
    else
      {:ok,
       %{
         device_uid: device_uid,
         source: "opentext-nom",
         config_kind: :running,
         object_key: object_key,
         assignment_id: assignment_id(payload),
         sha256: sha256
       }}
    end
  end

  @doc """
  Fetches the staged running-config for an extracted reference.

  The object key must lie under the reporting agent's artifact prefix, so a
  plugin result cannot point core at another agent's or assignment's objects.
  Assignment identity comes from labels overwritten by the agent host.
  """
  @spec fetch_body(map(), map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def fetch_body(%{object_key: object_key, sha256: sha256} = ref, status, opts \\ []) do
    fetcher = Keyword.get(opts, :artifact_fetcher, &default_fetch/1)

    with :ok <- authorize_object_key(object_key, Map.get(ref, :assignment_id), status),
         {:ok, body} <- normalize_fetch(fetcher.(object_key)) do
      verify_body(body, sha256)
    end
  end

  defp authorize_object_key(object_key, assignment, status) do
    agent_id = status_agent_id(status)

    cond do
      agent_id in [nil, ""] ->
        {:error, :running_config_artifact_agent_unknown}

      String.contains?(object_key, "..") ->
        {:error, :running_config_artifact_key_invalid}

      not String.starts_with?(object_key, "agent-artifacts/#{agent_id}/") ->
        {:error, :running_config_artifact_key_not_owned}

      is_nil(assignment) or not String.starts_with?(object_key, "agent-artifacts/#{agent_id}/#{assignment}/") ->
        {:error, :running_config_artifact_assignment_not_owned}

      not nom_config_key?(object_key) ->
        {:error, :running_config_artifact_key_invalid}

      true ->
        :ok
    end
  end

  defp nom_config_key?(key) do
    case String.split(key, "/") do
      ["agent-artifacts", agent, assignment, "opentext-nom", "running-config", device] ->
        nom_config_prefix?(agent, assignment) and legacy_nom_device?(device)
      ["agent-artifacts", agent, assignment, "opentext-nom", "running-config", device, attempt] ->
        nom_config_segments?(agent, assignment, device) and Regex.match?(~r/\A[0-9a-f]{32}\z/, attempt)
      _ -> false
    end
  end

  defp nom_config_segments?(agent, assignment, device) do
    nom_config_prefix?(agent, assignment) and
      Regex.match?(~r/\A[1-9][0-9]*\z/, device)
  end

  defp nom_config_prefix?(agent, assignment) do
    Enum.all?([agent, assignment], &Regex.match?(~r/\A[A-Za-z0-9._:-]+\z/, &1))
  end

  defp legacy_nom_device?(device) do
    device not in [".", ".."] and Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, device)
  end

  defp assignment_id(payload) do
    payload |> labels_map() |> Map.get("assignment_id") |> string_or_nil()
  end

  defp normalize_fetch({:ok, {_info, data}}) when is_binary(data), do: {:ok, data}
  defp normalize_fetch({:ok, data}) when is_binary(data), do: {:ok, data}

  defp normalize_fetch({:error, reason}),
    do: {:error, {:running_config_artifact_fetch_failed, reason}}

  defp normalize_fetch(other), do: {:error, {:running_config_artifact_fetch_failed, other}}

  defp verify_body(body, expected_sha256) do
    actual = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

    cond do
      actual != String.downcase(expected_sha256) ->
        {:error, :running_config_artifact_hash_mismatch}

      not String.valid?(body) ->
        {:error, :running_config_artifact_not_utf8}

      true ->
        {:ok, body}
    end
  end

  defp default_fetch(object_key) do
    Client.with_direct_channel(
      fn channel ->
        SyncClient.download_object(channel, object_key, timeout: @artifact_timeout)
      end,
      timeout: @artifact_timeout,
      connect_timeout_ms: @artifact_timeout
    )
  end

  defp default_delete(object_key) do
    Client.with_direct_channel(
      fn channel -> SyncClient.delete_object(channel, object_key, timeout: @artifact_timeout) end,
      timeout: @artifact_timeout,
      connect_timeout_ms: @artifact_timeout
    )
  end

  defp status_agent_id(status) when is_map(status) do
    value = Map.get(status, :agent_id) || Map.get(status, "agent_id")
    if is_binary(value), do: String.trim(value)
  end

  defp status_agent_id(_status), do: nil

  defp kind?(payload) do
    labels = labels_map(payload)
    details = details_map(payload)

    Map.get(labels, "kind") == "running_config" or
      Map.get(labels, :kind) == "running_config" or
      Map.get(details, "kind") == "running_config" or
      Map.get(details, "config_kind") == "running"
  end

  defp extract_device_uid(payload) do
    labels = labels_map(payload)
    details = details_map(payload)

    Map.get(labels, "device_uid") ||
      Map.get(labels, :device_uid) ||
      Map.get(details, "device_uid") ||
      Map.get(payload, "device_uid")
  end

  defp labels_map(payload) do
    case Map.get(payload, "labels") || Map.get(payload, :labels) do
      labels when is_map(labels) -> labels
      _ -> %{}
    end
  end

  defp artifact_object_key(payload) do
    payload |> artifact_meta() |> Map.get("object_key") |> string_or_nil()
  end

  defp artifact_sha256(payload) do
    # The plugin's digest is hex; object-store metadata can use another encoding.
    payload |> details_map() |> Map.get("content_hash") |> string_or_nil() ||
      payload |> artifact_meta() |> Map.get("sha256") |> string_or_nil()
  end

  defp artifact_meta(payload) do
    case Map.get(details_map(payload), "artifact") do
      artifact when is_map(artifact) -> artifact
      _ -> %{}
    end
  end

  defp string_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_or_nil(_value), do: nil

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
