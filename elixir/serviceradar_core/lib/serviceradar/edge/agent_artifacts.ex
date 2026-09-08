defmodule ServiceRadar.Edge.AgentArtifacts do
  @moduledoc """
  Runtime publication registry for agent-gateway-served artifacts.

  Producers publish logical artifacts here with a token id and object key. The
  agent-gateway later presents the signed token to core, and core authorizes the
  exact published token/object pair before the gateway streams bytes from
  DataService.
  """

  use GenServer

  alias ServiceRadar.Plugins.StorageToken

  @type publication :: %{
          required(:token_id) => String.t(),
          required(:object_key) => String.t(),
          optional(:file_name) => String.t(),
          optional(:content_type) => String.t(),
          optional(:metadata) => map(),
          optional(:published_at) => DateTime.t()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(state), do: {:ok, state}

  @spec token_id(term(), term(), term()) :: String.t()
  def token_id(source_type, source_id, artifact_name) do
    [source_type, source_id, artifact_name]
    |> Enum.map(&safe_token_segment/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(":")
  end

  @spec publish(map() | keyword()) :: {:ok, publication()} | {:error, term()}
  def publish(attrs) do
    with {:ok, publication} <- normalize_publication(attrs),
         {:ok, pid} <- registry_pid() do
      GenServer.call(pid, {:publish, publication})
    end
  end

  @spec publish_catalog(map() | keyword()) :: {:ok, publication()} | {:error, term()}
  def publish_catalog(attrs) do
    attrs = Map.new(attrs)

    attrs
    |> put_new_value(:source_type, "catalog-source")
    |> put_new_value(:artifact_name, "active")
    |> put_new_value(:content_type, "application/json")
    |> put_new_value(:file_name, catalog_file_name(attrs))
    |> publish()
  end

  @spec publish_catalog_assignment(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def publish_catalog_assignment(attrs) do
    attrs = Map.new(attrs)

    with {:ok, publication} <- publish_catalog(attrs) do
      {:ok, catalog_assignment(attrs, publication)}
    end
  end

  @spec unpublish(String.t()) :: :ok | {:error, term()}
  def unpublish(token_id) when is_binary(token_id) do
    with {:ok, pid} <- registry_pid() do
      GenServer.call(pid, {:unpublish, token_id})
    end
  end

  def unpublish(_token_id), do: {:error, :invalid_token_id}

  @spec authorize_download(String.t(), String.t()) :: {:ok, publication()} | {:error, term()}
  def authorize_download(token_id, object_key)
      when is_binary(token_id) and is_binary(object_key) do
    with {:ok, publication} <- lookup(token_id),
         true <- same_object_key?(publication.object_key, object_key) do
      {:ok, publication}
    else
      false -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  def authorize_download(_token_id, _object_key), do: {:error, :unauthorized}

  @spec lookup(String.t()) :: {:ok, publication()} | {:error, :not_found | :unavailable}
  def lookup(token_id) when is_binary(token_id) do
    with {:ok, pid} <- registry_pid() do
      GenServer.call(pid, {:lookup, token_id})
    end
  end

  def lookup(_token_id), do: {:error, :not_found}

  @spec list() :: [publication()]
  def list do
    case registry_pid() do
      {:ok, pid} -> GenServer.call(pid, :list)
      {:error, _reason} -> []
    end
  end

  @spec clear() :: :ok | {:error, term()}
  def clear do
    with {:ok, pid} <- registry_pid() do
      GenServer.call(pid, :clear)
    end
  end

  @spec download_request(publication() | nil) :: %{url: String.t(), token: String.t()} | nil
  def download_request(%{token_id: token_id, object_key: object_key}) do
    StorageToken.download_agent_artifact_request(token_id, object_key)
  end

  def download_request(_publication), do: nil

  @impl true
  def handle_call({:publish, publication}, _from, state) do
    {:reply, {:ok, publication}, Map.put(state, publication.token_id, publication)}
  end

  def handle_call({:unpublish, token_id}, _from, state) do
    {:reply, :ok, Map.delete(state, token_id)}
  end

  def handle_call({:lookup, token_id}, _from, state) do
    case Map.fetch(state, token_id) do
      {:ok, publication} -> {:reply, {:ok, publication}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state), state}
  end

  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{}}
  end

  defp normalize_publication(attrs) do
    attrs = Map.new(attrs)

    token_id =
      map_value(attrs, :token_id) ||
        token_id(
          map_value(attrs, :source_type),
          map_value(attrs, :source_id),
          map_value(attrs, :artifact_name)
        )

    object_key = map_value(attrs, :object_key)

    cond do
      blank?(token_id) -> {:error, :invalid_token_id}
      blank?(object_key) -> {:error, :invalid_object_key}
      true -> {:ok, publication(attrs, token_id, object_key)}
    end
  end

  defp publication(attrs, token_id, object_key) do
    %{
      token_id: token_id,
      object_key: object_key,
      file_name: map_value(attrs, :file_name) || "artifact",
      content_type: map_value(attrs, :content_type) || "application/octet-stream",
      metadata: map_value(attrs, :metadata) || %{},
      published_at: DateTime.utc_now()
    }
  end

  defp registry_pid do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :unavailable}
    end
  end

  defp map_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp put_new_value(map, key, value) do
    if map_value(map, key) do
      map
    else
      Map.put(map, key, value)
    end
  end

  defp catalog_assignment(attrs, publication) do
    maybe_put_download_request(
      %{
        "schema_version" =>
          map_value(attrs, :schema_version) || "serviceradar.catalog_assignment.v1",
        "snapshot_ref" => map_value(attrs, :snapshot_ref),
        "catalog_version" => map_value(attrs, :catalog_version),
        "source_revision" => map_value(attrs, :source_revision),
        "object_key" => publication.object_key,
        "sha256" => map_value(attrs, :sha256),
        "size_bytes" => map_value(attrs, :size_bytes),
        "promoted_at" => iso8601_or_nil(map_value(attrs, :promoted_at))
      },
      download_request(publication)
    )
  end

  defp maybe_put_download_request(config, %{url: url, token: token})
       when is_binary(url) and is_binary(token) do
    config
    |> Map.put("download_url", url)
    |> Map.put("download_token", token)
  end

  defp maybe_put_download_request(config, _download), do: config

  defp catalog_file_name(attrs) do
    version = map_value(attrs, :catalog_version) || map_value(attrs, :snapshot_ref)
    "catalog-#{safe_token_segment(version || "artifact")}.json"
  end

  defp iso8601_or_nil(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601_or_nil(value) when is_binary(value), do: value
  defp iso8601_or_nil(_value), do: nil

  defp safe_token_segment(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> String.trim("-")
  end

  defp safe_token_segment(nil), do: ""

  defp safe_token_segment(value) when is_atom(value),
    do: safe_token_segment(Atom.to_string(value))

  defp safe_token_segment(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_token_segment(value), do: value |> inspect() |> safe_token_segment()

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp same_object_key?(expected, actual)
       when is_binary(expected) and is_binary(actual) and byte_size(expected) == byte_size(actual) do
    Plug.Crypto.secure_compare(expected, actual)
  end

  defp same_object_key?(_expected, _actual), do: false
end
