defmodule ServiceRadarWebNG.NetworkCredentials do
  @moduledoc """
  Web-facing operations for network credential secrets and rules.
  """

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Credentials.CredentialRotation
  alias ServiceRadar.Credentials.CredentialSecretBuilder
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Plugins.IntegrationCatalog

  require Ash.Query

  @default_limit 200
  @max_limit 500

  @spec list_secrets(keyword()) :: {:ok, [struct()]} | {:error, term()}
  def list_secrets(opts \\ []) do
    scope = Keyword.fetch!(opts, :scope)
    filters = Keyword.get(opts, :filters, %{})

    query =
      NetworkCredentialSecret
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> maybe_filter_provider(filters)
      |> maybe_filter_name(filters)
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.limit(normalize_limit(Map.get(filters, "limit") || Map.get(filters, :limit)))

    Ash.read(query, scope: scope)
  end

  @spec get_secret(String.t(), keyword()) ::
          {:ok, struct()} | {:error, :not_found} | {:error, term()}
  def get_secret(id, opts \\ []) when is_binary(id) do
    scope = Keyword.fetch!(opts, :scope)

    case NetworkCredentialSecret.get_by_id(id, scope: scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, secret} -> {:ok, secret}
      {:error, %NotFound{}} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  @spec create_secret(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def create_secret(attrs, opts \\ []) when is_map(attrs) do
    scope = Keyword.fetch!(opts, :scope)

    with_result =
      with {:ok, built} <- build_secret_attrs(attrs) do
        NetworkCredentialSecret.create_secret(built, scope: scope)
      end

    normalize_credential_error(with_result)
  end

  @spec update_secret_details(String.t(), map(), keyword()) ::
          {:ok, struct()} | {:error, :not_found} | {:error, term()}
  def update_secret_details(id, attrs, opts \\ []) when is_binary(id) and is_map(attrs) do
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, secret} <- get_secret(id, scope: scope) do
      NetworkCredentialSecret.edit_details(secret, drop_nils(attrs), scope: scope)
    end
  end

  @spec rotate_secret(String.t(), map(), keyword()) ::
          {:ok, struct()} | {:error, :not_found} | {:error, term()}
  def rotate_secret(id, values, opts \\ []) when is_binary(id) and is_map(values) do
    scope = Keyword.fetch!(opts, :scope)

    with_result =
      with {:ok, secret} <- get_secret(id, scope: scope) do
        CredentialRotation.rotate(secret, stringify_keys(values), scope)
      end

    normalize_credential_error(with_result)
  end

  @spec list_rules(keyword()) :: {:ok, [struct()]} | {:error, term()}
  def list_rules(opts \\ []) do
    scope = Keyword.fetch!(opts, :scope)
    filters = Keyword.get(opts, :filters, %{})

    query =
      NetworkCredentialRule
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> maybe_filter_provider(filters)
      |> maybe_filter_name(filters)
      |> maybe_filter_scope_type(filters)
      |> maybe_filter_scope_value(filters)
      |> maybe_filter_enabled(filters)
      |> Ash.Query.sort(priority: :asc, inserted_at: :asc)
      |> Ash.Query.limit(normalize_limit(Map.get(filters, "limit") || Map.get(filters, :limit)))

    Ash.read(query, scope: scope)
  end

  @spec get_rule(String.t(), keyword()) ::
          {:ok, struct()} | {:error, :not_found} | {:error, term()}
  def get_rule(id, opts \\ []) when is_binary(id) do
    scope = Keyword.fetch!(opts, :scope)

    case NetworkCredentialRule.get_by_id(id, scope: scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, rule} -> {:ok, rule}
      {:error, %NotFound{}} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  @spec create_rule(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def create_rule(attrs, opts \\ []) when is_map(attrs) do
    scope = Keyword.fetch!(opts, :scope)
    NetworkCredentialRule.create_rule(attrs, scope: scope)
  end

  @spec update_rule(String.t(), map(), keyword()) ::
          {:ok, struct()} | {:error, :not_found} | {:error, term()}
  def update_rule(id, attrs, opts \\ []) when is_binary(id) and is_map(attrs) do
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, rule} <- get_rule(id, scope: scope) do
      NetworkCredentialRule.update_rule(rule, attrs, scope: scope)
    end
  end

  @spec set_rule_enabled(String.t(), boolean(), keyword()) ::
          {:ok, struct()} | {:error, :not_found} | {:error, term()}
  def set_rule_enabled(id, enabled, opts \\ []) when is_binary(id) and is_boolean(enabled) do
    scope = Keyword.fetch!(opts, :scope)
    action = if enabled, do: :enable, else: :disable

    with {:ok, rule} <- get_rule(id, scope: scope) do
      rule
      |> Ash.Changeset.for_update(action, %{}, scope: scope)
      |> Ash.update(scope: scope)
    end
  end

  defp normalize_credential_error({:error, {:missing_credential_field, field}}) do
    {:error, :invalid_request, "missing credential field: #{field}"}
  end

  defp normalize_credential_error({:error, {:invalid_credential_field, field}}) do
    {:error, :invalid_request, "invalid credential field: #{field}"}
  end

  defp normalize_credential_error(result), do: result

  defp build_secret_attrs(attrs) do
    provider = required_string(attrs, "provider") || required_string(attrs, :provider)
    auth_method = required_string(attrs, "auth_method") || required_string(attrs, :auth_method)
    values = Map.get(attrs, "values") || Map.get(attrs, :values) || %{}

    common = %{
      name: required_string(attrs, "name") || required_string(attrs, :name),
      description: blank_to_nil(Map.get(attrs, "description") || Map.get(attrs, :description))
    }

    cond do
      is_nil(provider) or provider == "" ->
        {:error, :invalid_request, "provider is required"}

      is_nil(auth_method) or auth_method == "" ->
        {:error, :invalid_request, "auth_method is required"}

      is_nil(common.name) or common.name == "" ->
        {:error, :invalid_request, "name is required"}

      not is_map(values) ->
        {:error, :invalid_request, "values must be an object"}

      true ->
        with {:ok, profile} <- load_profile(provider) do
          CredentialSecretBuilder.build(profile, auth_method, stringify_keys(values), common)
        end
    end
  end

  defp load_profile(provider) do
    case IntegrationCatalog.profile_for(provider) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, :invalid_request, "unknown credential provider"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_filter_provider(query, filters) do
    case filter_string(filters, "provider") do
      nil -> query
      value -> Ash.Query.filter(query, provider == ^value)
    end
  end

  defp maybe_filter_name(query, filters) do
    case filter_string(filters, "name") do
      nil -> query
      value -> Ash.Query.filter(query, name == ^value)
    end
  end

  defp maybe_filter_scope_type(query, filters) do
    case filter_string(filters, "scope_type") do
      nil -> query
      value -> Ash.Query.filter(query, scope_type == ^value)
    end
  end

  defp maybe_filter_scope_value(query, filters) do
    case filter_string(filters, "scope_value") do
      nil -> query
      value -> Ash.Query.filter(query, scope_value == ^value)
    end
  end

  defp maybe_filter_enabled(query, filters) do
    case Map.get(filters, "enabled") || Map.get(filters, :enabled) do
      true -> Ash.Query.filter(query, enabled == true)
      false -> Ash.Query.filter(query, enabled == false)
      "true" -> Ash.Query.filter(query, enabled == true)
      "false" -> Ash.Query.filter(query, enabled == false)
      _ -> query
    end
  end

  defp filter_string(filters, key) do
    value = Map.get(filters, key) || Map.get(filters, String.to_atom(key))

    if is_binary(value) and String.trim(value) != "" do
      String.trim(value)
    end
  end

  defp normalize_limit(nil), do: @default_limit
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, ""} -> normalize_limit(parsed)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_), do: @default_limit

  defp drop_nils(attrs) when is_map(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp required_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
