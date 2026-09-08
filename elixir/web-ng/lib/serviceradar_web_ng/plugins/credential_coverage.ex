defmodule ServiceRadarWebNG.Plugins.CredentialCoverage do
  @moduledoc """
  Assignment-time credential-rule coverage checks.

  Plugin config schemas mark fields whose values arrive via credential-rule
  materialization with `x-serviceradar-credential-materialized: true`. For such
  plugins, this module derives the credential provider/purpose from approved
  package manifests (never per-plugin UI hardcoding) and answers whether any
  enabled credential rule currently covers a target agent.

  Reads go through the core materializer with a system actor: the result only
  exposes rule names/coverage, never secret material.
  """

  alias ServiceRadar.Credentials.PluginAssignmentMaterializer
  alias ServiceRadar.Plugins.IntegrationCatalog

  @annotation "x-serviceradar-credential-materialized"

  @typedoc "Coverage result for a plugin/agent pair."
  @type coverage :: %{
          state: :covered | :uncovered,
          provider: String.t(),
          purpose: String.t(),
          rules: [String.t()]
        }

  @doc "Names of schema properties annotated as credential-materialized."
  @spec materialized_fields(map() | nil) :: [String.t()]
  def materialized_fields(schema) when is_map(schema) do
    schema
    |> stringify_keys()
    |> Map.get("properties", %{})
    |> Enum.filter(fn {_name, prop} -> is_map(prop) and Map.get(prop, @annotation) == true end)
    |> Enum.map(fn {name, _prop} -> name end)
    |> Enum.sort()
  end

  def materialized_fields(_schema), do: []

  @doc """
  Coverage of a plugin's materialized inputs for a target agent.

  Returns `:not_applicable` when the plugin id maps to no provider profile,
  `{:ok, coverage}` otherwise. `opts` pass through to
  `PluginAssignmentMaterializer.covering_rules_for_agent/4` (`:actor`,
  `:rules` injection for tests).
  """
  @spec coverage(String.t() | nil, String.t() | nil, keyword()) ::
          :not_applicable | {:ok, coverage()} | {:error, term()}
  def coverage(plugin_id, agent_uid, opts \\ [])

  def coverage(plugin_id, agent_uid, opts) when is_binary(plugin_id) and is_binary(agent_uid) do
    case consumer_for_plugin_id(plugin_id, opts) do
      {:ok, {profile, consumer}} ->
        purpose = consumer["purpose"]

        case PluginAssignmentMaterializer.covering_rules_for_agent(
               profile,
               agent_uid,
               purpose,
               opts
             ) do
          {:ok, []} ->
            {:ok, %{state: :uncovered, provider: profile["provider"], purpose: purpose, rules: []}}

          {:ok, rules} ->
            {:ok,
             %{
               state: :covered,
               provider: profile["provider"],
               purpose: purpose,
               rules: Enum.map(rules, &rule_name/1)
             }}

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        :not_applicable

      {:error, reason} ->
        {:error, reason}
    end
  end

  def coverage(_plugin_id, _agent_uid, _opts), do: :not_applicable

  @doc "Human warning for an uncovered plugin/agent pair, nil otherwise."
  @spec warning_message(coverage() | term(), String.t()) :: String.t() | nil
  def warning_message(%{state: :uncovered, provider: provider, purpose: purpose}, agent_uid) do
    "No enabled #{provider} #{purpose} credential rule covers agent #{agent_uid}. " <>
      "Create the secret and rule in Settings -> Networks -> Credentials, then assign this plugin. " <>
      "Do not paste passwords into the plugin form."
  end

  def warning_message(_coverage, _agent_uid), do: nil

  defp rule_name(rule) when is_map(rule) do
    name = Map.get(rule, :name) || Map.get(rule, "name")
    id = Map.get(rule, :id) || Map.get(rule, "id")

    cond do
      is_binary(name) and name != "" -> name
      is_binary(id) -> id
      true -> to_string(id || "unnamed")
    end
  end

  defp consumer_for_plugin_id(plugin_id, opts) do
    case Keyword.get(opts, :integration_catalog) do
      nil -> IntegrationCatalog.consumer_for_plugin_id(plugin_id, opts)
      catalog -> consumer_from_catalog(plugin_id, catalog)
    end
  end

  defp consumer_from_catalog(plugin_id, %{credential_profiles: profiles}), do: consumer_from_profiles(plugin_id, profiles)

  defp consumer_from_catalog(plugin_id, %{"credential_profiles" => profiles}),
    do: consumer_from_profiles(plugin_id, profiles)

  defp consumer_from_catalog(plugin_id, profiles) when is_list(profiles), do: consumer_from_profiles(plugin_id, profiles)

  defp consumer_from_catalog(_plugin_id, _catalog), do: {:error, :invalid_plugin_integration_catalog}

  defp consumer_from_profiles(plugin_id, profiles) do
    Enum.find_value(profiles, :error, fn profile ->
      profile
      |> get_in(["provisioning", "consumers"])
      |> List.wrap()
      |> Enum.find_value(fn consumer ->
        if consumer["plugin_id"] == plugin_id, do: {:ok, {profile, consumer}}
      end)
    end)
  end

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
