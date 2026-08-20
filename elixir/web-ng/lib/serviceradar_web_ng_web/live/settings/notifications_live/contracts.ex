defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.Contracts do
  @moduledoc """
  Resolves the notification surfaces through the runtime contract mechanism.

  Three surfaces render from package-supplied contracts rather than from
  hardcoded field lists (tasks 3.5.4):

    * the channel configuration form, from the notifier's `config_schema` in the
      package's `notifications:` manifest block;
    * the Delivery Log detail pane, from a `notification_delivery` display
      contract;
    * channel health, from a `notification_channel_health` display contract.

  All three resolve at RUNTIME, from
  `ServiceRadarWebNG.Observability.ContractRegistry`, and all three degrade the
  same way: a package that ships no contract, and a package whose contract this
  release refuses, both render the generic view with a diagnostic beside it. A
  third party cannot break an operator's settings screen by shipping a bad
  contract - the worst it can do is render its own panel generically and say so.

  The config form's fallback is deliberately the schema stored on the provider
  row rather than an empty schema: an empty schema renders no inputs, and a form
  with no inputs is indistinguishable from a provider that needs no
  configuration. Falling back to the stored copy means the form is never worse
  than it was before this resolution existed.
  """

  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadarWebNG.Observability.ContractRegistry
  alias ServiceRadarWebNG.Observability.SignalDisplay

  @delivery_surface "notification_delivery"
  @health_surface "notification_channel_health"

  @type config_contract :: %{
          schema: map(),
          source: :package | :provider | :none,
          diagnostics: [String.t()]
        }

  @type view :: %{
          widgets: [map()],
          source: :contract | :generic,
          diagnostics: [String.t()]
        }

  @doc "The config schema the channel form renders, and where it came from."
  @spec config_contract(struct() | map() | nil) :: config_contract()
  def config_contract(nil), do: %{schema: %{}, source: :none, diagnostics: []}

  def config_contract(provider) do
    stored = stored_schema(provider)

    case package_config_schema(provider) do
      {:ok, schema} ->
        %{schema: schema, source: :package, diagnostics: []}

      {:error, reason} ->
        %{schema: stored, source: :provider, diagnostics: [reason]}

      :none ->
        %{schema: stored, source: :provider, diagnostics: []}
    end
  end

  @doc "The config schema alone, for callers that only need the shape."
  @spec config_schema(struct() | map() | nil) :: map()
  def config_schema(provider), do: config_contract(provider).schema

  @doc """
  The Delivery Log detail view for one delivery.

  The record rendered is the REDACTED `result_summary` the engine persisted, not
  the wire payload; a contract can only name paths into what was already deemed
  safe to store.
  """
  @spec delivery_view(map() | nil, struct() | map() | nil) :: view()
  def delivery_view(result_summary, provider) do
    render_surface(result_summary, provider, @delivery_surface, title: "Result detail")
  end

  @doc "The health detail view for one channel."
  @spec channel_health_view(struct() | map() | nil, struct() | map() | nil) :: view()
  def channel_health_view(nil, _provider), do: empty_view()

  def channel_health_view(channel, provider) do
    channel
    |> health_record()
    |> render_surface(provider, @health_surface, title: "Health detail")
  end

  @doc "Contracts installed packages shipped that this node refused."
  @spec registry_diagnostics() :: [map()]
  def registry_diagnostics, do: ContractRegistry.diagnostics()

  # --- resolution -----------------------------------------------------------

  defp render_surface(record, provider, surface, opts) when is_map(record) and record != %{} do
    contract = surface_contract(provider, surface)
    {widgets, diagnostics} = SignalDisplay.render_or_generic(record, contract, opts)

    %{
      widgets: widgets,
      source: if(contract && widgets != [], do: :contract, else: :generic),
      diagnostics: Enum.map(diagnostics, & &1.detail)
    }
  end

  defp render_surface(_record, _provider, _surface, _opts), do: empty_view()

  defp empty_view, do: %{widgets: [], source: :generic, diagnostics: []}

  defp surface_contract(provider, surface) do
    with {:ok, package_id, action_key} <- plugin_reference(provider),
         {:ok, {producer_id, producer_version}} <- ContractRegistry.package_identity(package_id),
         {:ok, contract} <-
           ContractRegistry.lookup_surface(producer_id, producer_version, surface, action_key) do
      contract
    else
      _other -> nil
    end
  end

  # The notifier's config schema comes from the package's CURRENT manifest, so a
  # package upgrade that adds a setting reaches the form without the operator
  # re-creating the provider row. It is re-validated here because the row it
  # came from may predate the current release's validator.
  defp package_config_schema(provider) do
    with {:ok, package_id, action_key} <- plugin_reference(provider),
         {:ok, entry} <- ContractRegistry.lookup_notifier(package_id, action_key) do
      case Map.get(entry, "config_schema") do
        schema when is_map(schema) and map_size(schema) > 0 ->
          case ConfigSchema.validate_schema(schema) do
            :ok ->
              {:ok, schema}

            {:error, errors} ->
              {:error,
               "The package's config schema for #{action_key} was refused (#{Enum.join(errors, "; ")}); " <>
                 "showing the schema stored on the provider."}
          end

        _other ->
          :none
      end
    else
      :not_plugin ->
        :none

      _other ->
        {:error,
         "This provider's package is not in the runtime contract index (it may not be approved); " <>
           "showing the schema stored on the provider."}
    end
  end

  defp plugin_reference(%{provider_type: :wasm_plugin} = provider) do
    package_id = Map.get(provider, :plugin_package_id)
    action_key = Map.get(provider, :action_key)

    if is_nil(package_id) or not is_binary(action_key) do
      :error
    else
      {:ok, package_id, action_key}
    end
  end

  defp plugin_reference(_provider), do: :not_plugin

  defp stored_schema(provider) do
    case Map.get(provider, :config_schema) do
      schema when is_map(schema) -> schema
      _other -> %{}
    end
  end

  defp health_record(channel) do
    %{
      "health" => stringify(Map.get(channel, :health)),
      "last_success_at" => stringify(Map.get(channel, :last_success_at)),
      "last_failure_at" => stringify(Map.get(channel, :last_failure_at)),
      "last_error" => stringify(Map.get(channel, :last_error))
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)
end
