defmodule ServiceRadar.AnalyticsStore.Config do
  @moduledoc """
  Deployment-selected analytics-store driver and storage backend.

  Default is `:timescale` (today's CNPG hypertables). `:pg_duckdb` requires a
  complete S3 or filesystem backend and refuses to start otherwise — it must
  not silently write hypertables.

  Pass a loaded config into `ServiceRadar.AnalyticsStore` functions in tests;
  do not mutate application env.
  """

  alias ServiceRadar.ColdTier.Registry

  @type driver :: :timescale | :pg_duckdb
  @type storage :: :s3 | :filesystem | nil

  @type t :: %__MODULE__{
          driver: driver(),
          tables: MapSet.t(String.t()),
          dual_write: MapSet.t(String.t()),
          storage: storage(),
          s3_bucket_url: String.t() | nil,
          filesystem_path: String.t() | nil,
          head_host: String.t() | nil,
          head_port: pos_integer(),
          head_database: String.t() | nil,
          head_username: String.t() | nil,
          head_password: String.t() | nil,
          s3_endpoint: String.t() | nil,
          s3_region: String.t() | nil,
          s3_access_key_id: String.t() | nil,
          s3_secret_access_key: String.t() | nil,
          s3_url_style: String.t(),
          s3_use_ssl: boolean(),
          pool_size: pos_integer()
        }

  defstruct driver: :timescale,
            tables: MapSet.new(),
            dual_write: MapSet.new(),
            storage: nil,
            s3_bucket_url: nil,
            filesystem_path: nil,
            head_host: nil,
            head_port: 5432,
            head_database: "serviceradar",
            head_username: "serviceradar",
            head_password: nil,
            s3_endpoint: nil,
            s3_region: "us-ord",
            s3_access_key_id: nil,
            s3_secret_access_key: nil,
            s3_url_style: "path",
            s3_use_ssl: true,
            pool_size: 4

  @doc "Load from application env or an explicit keyword list."
  @spec load(keyword() | nil) :: t()
  def load(raw \\ nil) do
    raw = raw || Application.get_env(:serviceradar_core, ServiceRadar.AnalyticsStore, [])

    %__MODULE__{
      driver: parse_driver(raw[:driver]),
      tables: parse_tables(raw[:tables]),
      dual_write: parse_tables(raw[:dual_write] || raw[:dualWrite]),
      storage: parse_storage(raw[:storage]),
      s3_bucket_url: blank_to_nil(raw[:s3_bucket_url]),
      filesystem_path: blank_to_nil(raw[:filesystem_path]),
      head_host: blank_to_nil(raw[:head_host]),
      head_port: raw[:head_port] || 5432,
      head_database: blank_to_nil(raw[:head_database]) || "serviceradar",
      head_username: blank_to_nil(raw[:head_username]) || "serviceradar",
      head_password: blank_to_nil(raw[:head_password]),
      s3_endpoint: blank_to_nil(raw[:s3_endpoint]),
      s3_region: blank_to_nil(raw[:s3_region]) || "us-ord",
      s3_access_key_id: blank_to_nil(raw[:s3_access_key_id]),
      s3_secret_access_key: blank_to_nil(raw[:s3_secret_access_key]),
      s3_url_style: blank_to_nil(raw[:s3_url_style]) || "path",
      s3_use_ssl: parse_bool(raw[:s3_use_ssl], true),
      pool_size: positive_int(raw[:pool_size], 4)
    }
  end

  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n

  defp positive_int(n, default) when is_binary(n) do
    case Integer.parse(n) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp positive_int(_, default), do: default

  @doc "Return `:ok` or `{:error, reason}` for a loaded config."
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{driver: driver}) when driver not in [:timescale, :pg_duckdb] do
    {:error, {:unknown_driver, driver}}
  end

  def validate(%__MODULE__{driver: :timescale, dual_write: dual} = cfg) do
    if MapSet.size(dual) == 0 do
      :ok
    else
      with :ok <- validate_storage(cfg) do
        validate_head(cfg)
      end
    end
  end

  def validate(%__MODULE__{driver: :pg_duckdb} = cfg) do
    with :ok <- validate_storage(cfg) do
      validate_head(cfg)
    end
  end

  @doc "Postgrex options for the analytics head, or `:disabled`."
  @spec head_opts(t()) :: {:ok, keyword()} | :disabled
  def head_opts(%__MODULE__{head_host: host} = cfg) when is_binary(host) and host != "" do
    {:ok,
     [
       hostname: host,
       port: cfg.head_port || 5432,
       database: cfg.head_database || "serviceradar",
       username: cfg.head_username || "serviceradar",
       password: cfg.head_password || "",
       ssl: false,
       connect_timeout: 5_000,
       parameters: [statement_timeout: "0", application_name: "sr_analytics_store"],
       pool_size: 1
     ]}
  end

  def head_opts(%__MODULE__{}), do: :disabled

  defp validate_storage(%__MODULE__{storage: nil}), do: {:error, :storage_required}

  defp validate_storage(%__MODULE__{storage: storage}) when storage not in [:s3, :filesystem] do
    {:error, {:unknown_storage, storage}}
  end

  defp validate_storage(%__MODULE__{storage: :s3, s3_bucket_url: url} = cfg)
       when is_binary(url) and url != "" do
    if present?(cfg.s3_access_key_id) and present?(cfg.s3_secret_access_key) do
      :ok
    else
      {:error, {:incomplete_storage, :s3, :missing_credentials}}
    end
  end

  defp validate_storage(%__MODULE__{storage: :s3}) do
    {:error, {:incomplete_storage, :s3, :missing_bucket}}
  end

  defp validate_storage(%__MODULE__{storage: :filesystem, filesystem_path: path})
       when is_binary(path) and path != "" do
    :ok
  end

  defp validate_storage(%__MODULE__{storage: :filesystem}) do
    {:error, {:incomplete_storage, :filesystem, :missing_path}}
  end

  defp validate_head(%__MODULE__{head_host: host}) when is_binary(host) and host != "" do
    :ok
  end

  defp validate_head(%__MODULE__{}), do: {:error, :head_required}

  @doc "Raise if the config (or application env) is not boot-safe."
  @spec validate!(t() | nil) :: t()
  def validate!(cfg \\ nil) do
    cfg = cfg || load()

    case validate(cfg) do
      :ok ->
        cfg

      {:error, reason} ->
        raise ArgumentError,
              "analytics store config is invalid: #{inspect(reason)}"
    end
  end

  @doc "Registry entries flipped onto pg_duckdb under this config."
  @spec flipped_tables(t()) :: [Registry.Table.t()]
  def flipped_tables(%__MODULE__{driver: :timescale}), do: []

  def flipped_tables(%__MODULE__{driver: :pg_duckdb} = cfg) do
    Enum.filter(Registry.tables(), fn entry -> driver_for(cfg, entry.table) == :pg_duckdb end)
  end

  @doc "True when EventWriter must persist `table` to both drivers."
  @spec dual_write?(t(), String.t()) :: boolean()
  def dual_write?(%__MODULE__{dual_write: tables}, table) when is_binary(table) do
    MapSet.member?(tables, table)
  end

  @doc "Which driver owns `table` under this config."
  @spec driver_for(t(), String.t()) :: driver()
  def driver_for(%__MODULE__{driver: :timescale}, _table), do: :timescale

  def driver_for(%__MODULE__{driver: :pg_duckdb, tables: tables}, table) do
    flipped =
      if MapSet.size(tables) == 0 do
        registry_table_set()
      else
        tables
      end

    if MapSet.member?(flipped, table) do
      :pg_duckdb
    else
      :timescale
    end
  end

  defp registry_table_set do
    MapSet.new(Registry.tables(), & &1.table)
  end

  defp parse_driver(nil), do: :timescale
  defp parse_driver(""), do: :timescale
  defp parse_driver(:timescale), do: :timescale
  defp parse_driver(:pg_duckdb), do: :pg_duckdb
  defp parse_driver("timescale"), do: :timescale
  defp parse_driver("pg_duckdb"), do: :pg_duckdb
  defp parse_driver(other), do: other

  defp parse_storage(nil), do: nil
  defp parse_storage(""), do: nil
  defp parse_storage(:s3), do: :s3
  defp parse_storage(:filesystem), do: :filesystem
  defp parse_storage("s3"), do: :s3
  defp parse_storage("filesystem"), do: :filesystem
  defp parse_storage(other), do: other

  defp parse_tables(nil), do: MapSet.new()
  defp parse_tables(""), do: MapSet.new()

  defp parse_tables(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp parse_tables(csv) when is_binary(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_), do: false

  defp parse_bool(nil, default), do: default
  defp parse_bool(value, _default) when is_boolean(value), do: value
  defp parse_bool(value, _default) when value in ["true", "1", 1], do: true
  defp parse_bool(value, _default) when value in ["false", "0", 0], do: false
  defp parse_bool(_, default), do: default

  @doc "DuckDB S3 secret fields, or `:disabled` when storage is not s3."
  @spec s3_secret(t()) :: {:ok, map()} | :disabled
  def s3_secret(%__MODULE__{storage: :s3, s3_bucket_url: url} = cfg)
      when is_binary(url) and url != "" do
    endpoint =
      cfg.s3_endpoint
      |> to_string()
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("http://", "")

    {:ok,
     %{
       access_key_id: cfg.s3_access_key_id,
       secret_access_key: cfg.s3_secret_access_key,
       region: cfg.s3_region || "us-ord",
       endpoint: endpoint,
       url_style: cfg.s3_url_style || "path",
       use_ssl: cfg.s3_use_ssl != false,
       bucket_url: String.trim_trailing(url, "/")
     }}
  end

  def s3_secret(%__MODULE__{}), do: :disabled
end
