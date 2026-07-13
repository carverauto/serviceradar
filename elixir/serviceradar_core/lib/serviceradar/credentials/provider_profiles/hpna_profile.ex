defmodule ServiceRadar.Credentials.ProviderProfiles.HpnaProfile do
  @moduledoc """
  Credential and public configuration profile for HPNA inventory collection.

  HPNA is action-only: a selected agent receives a direct plugin assignment,
  while AshOban dispatches collection through the package producer schedule.
  Long-lived credentials are referenced by the schedule and resolved into
  short-lived endpoint-scoped grants for each invocation.
  """

  @behaviour ServiceRadar.Credentials.CredentialProviderProfile

  alias ServiceRadar.Credentials.RuleAccessors
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Plugins.ValueUtils

  @provider "hpna"
  @plugin_id "hpna-inventory"
  @purpose :device_inventory
  @schedule_id "hpna.inventory.refresh"
  @default_queries [%{"name" => "switches", "parameters" => %{"type" => "Switch"}}]
  @string_filters ~w(software vendor type model family group hierarchy host ip realm vtpdomain context)
  @boolean_filters ~w(disabled pollexcluded)
  @allowed_filters MapSet.new(@string_filters ++ @boolean_filters ++ ["ids"])

  @impl true
  def provider, do: @provider

  @impl true
  def purposes, do: [@purpose]

  @impl true
  def plugin_id(_purpose), do: @plugin_id

  @impl true
  def host_source, do: :static_endpoint_metadata

  @impl true
  def secret_ref_fields, do: []

  @impl true
  def resolve_username?(_purpose, _rule), do: false

  @impl true
  def rule_has_purpose?(rule, @purpose) do
    @purpose |> Atom.to_string() |> Kernel.in(RuleAccessors.rule_purposes(rule))
  end

  def rule_has_purpose?(_rule, _purpose), do: false

  @impl true
  def grant_spec(_purpose, rule, secret_id, agent_id) do
    attrs = %{
      secret_id: secret_id,
      secret_ref: SecretRefs.network_credential_ref(secret_id),
      credential_rule_id: RuleAccessors.value_string(rule, [:id, "id"]),
      grant_type: "hpna_oauth_password",
      consumer_kind: :plugin,
      consumer_id: @plugin_id,
      purpose: "device_inventory_token",
      agent_id: agent_id,
      resolution_location: :agent,
      ttl_seconds: RuleAccessors.metadata_int(rule, "timeout_seconds", 900)
    }

    {attrs, %{}}
  end

  @impl true
  def params_template(_purpose, rule, _secret_id, _ctx), do: assignment_params(rule)

  @doc "Build validated, non-secret direct assignment and schedule input values."
  @spec assignment_params(map()) :: {:ok, map()} | {:error, term()}
  def assignment_params(rule) when is_map(rule) do
    metadata = RuleAccessors.metadata(rule)

    params = %{
      "instance_id" => metadata_string(metadata, "instance_id"),
      "token_url" => metadata_string(metadata, "token_url"),
      "api_url" => metadata_string(metadata, "api_url"),
      "queries" => metadata_queries(metadata),
      "page_size" => metadata_int(metadata, "page_size", 1_000),
      "max_rows" => metadata_int(metadata, "max_rows", 25_000),
      "max_result_bytes" => metadata_int(metadata, "max_result_bytes", 10_485_760),
      "request_timeout_seconds" => metadata_int(metadata, "request_timeout_seconds", 30),
      "max_retries" => metadata_int(metadata, "max_retries", 2)
    }

    with :ok <- validate_identifier(params["instance_id"]),
         :ok <- validate_https_url("token_url", params["token_url"]),
         :ok <- validate_https_url("api_url", params["api_url"]),
         :ok <- validate_queries(params["queries"]),
         :ok <- validate_integer("page_size", params["page_size"], 1, 5_000),
         :ok <- validate_integer("max_rows", params["max_rows"], params["page_size"], 100_000),
         :ok <-
           validate_integer("max_result_bytes", params["max_result_bytes"], 65_536, 12_582_912),
         :ok <-
           validate_integer(
             "request_timeout_seconds",
             params["request_timeout_seconds"],
             1,
             300
           ),
         :ok <- validate_integer("max_retries", params["max_retries"], 0, 5) do
      {:ok, params}
    end
  end

  def assignment_params(_rule), do: {:error, :invalid_hpna_rule}

  @doc "The package-owned producer schedule identifier."
  @spec schedule_id() :: String.t()
  def schedule_id, do: @schedule_id

  @doc "Whether the operator has enabled recurring collection on the rule."
  @spec schedule_enabled?(map()) :: boolean()
  def schedule_enabled?(rule), do: RuleAccessors.metadata_bool(rule, "schedule_enabled", false)

  @doc "Validated recurring cadence in seconds."
  @spec cadence_seconds(map()) :: pos_integer()
  def cadence_seconds(rule), do: RuleAccessors.metadata_int(rule, "cadence_seconds", 86_400)

  defp metadata_queries(metadata) do
    case ValueUtils.list_value(metadata, ["queries", :queries]) do
      queries when is_list(queries) and queries != [] -> stringify(queries)
      _ -> @default_queries
    end
  end

  defp metadata_string(metadata, key) do
    metadata
    |> ValueUtils.string_value([key])
    |> case do
      nil -> ""
      value -> String.trim(value)
    end
  end

  defp metadata_int(metadata, key, default), do: ValueUtils.int_value(metadata, [key], default)

  defp stringify(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp validate_identifier(value) when is_binary(value) do
    if String.match?(value, ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/) do
      :ok
    else
      {:error, {:invalid_hpna_setting, "instance_id"}}
    end
  end

  defp validate_identifier(_value), do: {:error, {:invalid_hpna_setting, "instance_id"}}

  defp validate_https_url(field, value) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme == "https" and valid_endpoint_host?(uri.host) and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
         is_integer(uri.port || 443) and (uri.port || 443) in 1..65_535 and
         is_binary(uri.path) and uri.path not in ["", "/"] and
         not String.ends_with?(uri.path, "/") do
      :ok
    else
      {:error, {:invalid_hpna_setting, field}}
    end
  end

  defp validate_https_url(field, _value), do: {:error, {:invalid_hpna_setting, field}}

  defp valid_endpoint_host?(host) when is_binary(host) do
    host == String.trim(host) and host != "" and
      String.match?(host, ~r/^[A-Za-z0-9._:-]+$/)
  end

  defp valid_endpoint_host?(_host), do: false

  defp validate_queries(queries) when is_list(queries) and length(queries) in 1..8 do
    queries
    |> Enum.reduce_while({:ok, MapSet.new()}, fn query, {:ok, names} ->
      with {:ok, name, _parameters} <- validate_query(query),
           false <- MapSet.member?(names, name) do
        {:cont, {:ok, MapSet.put(names, name)}}
      else
        true -> {:halt, {:error, {:invalid_hpna_setting, "queries.duplicate_name"}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _names} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_queries(_queries), do: {:error, {:invalid_hpna_setting, "queries"}}

  defp validate_query(%{} = query) do
    query = stringify(query)
    name = Map.get(query, "name")
    parameters = Map.get(query, "parameters")

    cond do
      MapSet.new(Map.keys(query)) != MapSet.new(["name", "parameters"]) ->
        {:error, {:invalid_hpna_setting, "queries.fields"}}

      not (is_binary(name) and String.match?(name, ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/)) ->
        {:error, {:invalid_hpna_setting, "queries.name"}}

      not (is_map(parameters) and map_size(parameters) in 1..16) ->
        {:error, {:invalid_hpna_setting, "queries.parameters"}}

      true ->
        with :ok <- validate_query_parameters(parameters) do
          {:ok, name, parameters}
        end
    end
  end

  defp validate_query(_query), do: {:error, {:invalid_hpna_setting, "queries"}}

  defp validate_query_parameters(parameters) do
    parameters
    |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
      key = to_string(key)

      result =
        cond do
          not MapSet.member?(@allowed_filters, key) ->
            {:error, {:invalid_hpna_setting, "queries.parameters.#{key}"}}

          key in @string_filters ->
            validate_filter_string(key, value)

          key in @boolean_filters and is_boolean(value) ->
            :ok

          key in @boolean_filters ->
            {:error, {:invalid_hpna_setting, "queries.parameters.#{key}"}}

          key == "ids" ->
            validate_ids(value)
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> validate_context_dependency(parameters)
      {:error, _reason} = error -> error
    end
  end

  defp validate_filter_string(key, value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= 512 and String.printable?(value) and
         not String.match?(value, ~r/[\x00-\x1F\x7F]/u) do
      :ok
    else
      {:error, {:invalid_hpna_setting, "queries.parameters.#{key}"}}
    end
  end

  defp validate_filter_string(key, _value),
    do: {:error, {:invalid_hpna_setting, "queries.parameters.#{key}"}}

  defp validate_ids(values) when is_list(values) and length(values) in 1..1_000 do
    if Enum.all?(values, &(is_integer(&1) and &1 > 0)) and
         length(Enum.uniq(values)) == length(values) do
      :ok
    else
      {:error, {:invalid_hpna_setting, "queries.parameters.ids"}}
    end
  end

  defp validate_ids(_values), do: {:error, {:invalid_hpna_setting, "queries.parameters.ids"}}

  defp validate_context_dependency(parameters) do
    if Map.has_key?(parameters, "context") and not Map.has_key?(parameters, "ip") do
      {:error, {:invalid_hpna_setting, "queries.parameters.context"}}
    else
      :ok
    end
  end

  defp validate_integer(_field, value, minimum, maximum)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: :ok

  defp validate_integer(field, _value, _minimum, _maximum),
    do: {:error, {:invalid_hpna_setting, field}}
end
