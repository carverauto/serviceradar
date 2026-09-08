defmodule ServiceRadar.Notifications.Changes.ApplyProviderContract do
  @moduledoc """
  Resolves a `ServiceRadar.Notifications.NotificationChannel` against the
  contract published by its provider.

  Four things are settled here because all four need the same single provider
  read, and doing them in four places would mean four reads of the same row:

    * `max_attempts` defaults from the provider's `default_max_attempts`
      (design D4). The bound lives on the channel, so a paging channel and a
      chat channel backed by the same provider can differ; the provider default
      only makes a channel usable without tuning. It is applied on create and
      only when the caller did not supply a value, so an operator's explicit
      choice is never re-defaulted on a later edit.
    * `execution_route` must appear in the provider's `supported_routes` (D3).
      A provider that cannot run on the edge must not be bound to an edge
      channel, because that configuration fails at dispatch time - which is the
      moment a page is owed.
    * `config` is normalized and validated against the provider's
      `config_schema` with `ServiceRadar.Plugins.ConfigSchema`.
    * `secret_refs` is prepared with `ServiceRadar.Plugins.SecretRefs` so only
      references and their linked material persist. Raw secret values never
      reach the column, and a blank submission preserves the stored reference
      rather than clearing it.

  Validation runs against the union of `config` and the public part of
  `secret_refs`, because the provider's `config_schema` describes one
  configuration document: the `secretRef` properties are declared in the same
  schema as everything else, and validating the halves separately would reject
  a schema that marks a secret field `required`.

  The provider is read with a system actor rather than the calling operator:
  this is an internal consistency check, and holding
  `notifications.channels.manage` must not additionally require
  `notifications.providers.manage`.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.SecretRefs

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :provider_id) do
      nil -> changeset
      provider_id -> apply_contract(changeset, provider_id)
    end
  end

  # The provider read is Elixir-side work that produces plain attribute values,
  # so the change runs here and returns the resulting changeset. That keeps the
  # enclosing update atomic instead of requiring `require_atomic? false`.
  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp apply_contract(changeset, provider_id) do
    case load_provider(provider_id) do
      {:ok, provider} ->
        changeset
        |> apply_default_max_attempts(provider)
        |> validate_supported_route(provider)
        |> apply_configuration(provider)

      :error ->
        Ash.Changeset.add_error(changeset,
          field: :provider_id,
          message: "notification provider is unavailable"
        )
    end
  end

  defp load_provider(provider_id) do
    actor = SystemActor.system(:notification_channel_contract)

    case Ash.get(NotificationProvider, provider_id, actor: actor) do
      {:ok, nil} -> :error
      {:ok, provider} -> {:ok, provider}
      {:error, _reason} -> :error
    end
  end

  defp apply_default_max_attempts(changeset, provider) do
    if changeset.action_type == :create and not param_supplied?(changeset, :max_attempts) do
      case Map.get(provider, :default_max_attempts) do
        value when is_integer(value) and value >= 1 ->
          Ash.Changeset.force_change_attribute(changeset, :max_attempts, value)

        _other ->
          changeset
      end
    else
      changeset
    end
  end

  defp validate_supported_route(changeset, provider) do
    route = Ash.Changeset.get_attribute(changeset, :execution_route)
    supported = supported_routes(provider)

    if is_nil(route) or supported == [] or to_string(route) in supported do
      changeset
    else
      Ash.Changeset.add_error(changeset,
        field: :execution_route,
        message: "is not one of the routes supported by the selected provider"
      )
    end
  end

  defp supported_routes(provider) do
    provider
    |> Map.get(:supported_routes)
    |> List.wrap()
    |> Enum.filter(&(is_atom(&1) or is_binary(&1)))
    |> Enum.map(&to_string/1)
  end

  # Only touch the configuration columns when this action is actually setting
  # them. A partial update that changes, say, only `enabled` must not rewrite
  # `config` or `secret_refs` from whatever the changeset happens to expose.
  defp apply_configuration(changeset, provider) do
    if changeset.action_type == :create or
         Ash.Changeset.changing_attribute?(changeset, :config) or
         Ash.Changeset.changing_attribute?(changeset, :secret_refs) do
      do_apply_configuration(changeset, provider)
    else
      changeset
    end
  end

  defp do_apply_configuration(changeset, provider) do
    schema = schema_for(provider)
    config = attribute_map(changeset, :config)
    submitted_refs = attribute_map(changeset, :secret_refs)
    stored_refs = stored_map(changeset, :secret_refs)

    prepared_refs = SecretRefs.prepare_params_for_storage(schema, submitted_refs, stored_refs)
    normalized_config = normalize_config(schema, config)
    document = Map.merge(normalized_config, SecretRefs.public_params(prepared_refs))

    with :ok <- linkage_result(schema, prepared_refs),
         :ok <- document_result(schema, document) do
      changeset
      |> Ash.Changeset.force_change_attribute(:config, normalized_config)
      |> Ash.Changeset.force_change_attribute(:secret_refs, prepared_refs)
    else
      {:error, field, messages} ->
        Ash.Changeset.add_error(changeset, field: field, message: Enum.join(messages, "; "))
    end
  end

  defp linkage_result(schema, prepared_refs) do
    case SecretRefs.validate_secret_linkage(schema, prepared_refs) do
      :ok -> :ok
      {:error, errors} -> {:error, :secret_refs, errors}
    end
  end

  defp document_result(schema, document) do
    case ConfigSchema.validate_params(schema, document) do
      :ok -> :ok
      {:error, errors} -> {:error, :config, errors}
    end
  end

  defp normalize_config(schema, config) when map_size(schema) > 0 do
    ConfigSchema.normalize_params(schema, config)
  end

  defp normalize_config(_schema, config), do: config

  defp schema_for(provider) do
    case Map.get(provider, :config_schema) do
      schema when is_map(schema) -> schema
      _other -> %{}
    end
  end

  defp attribute_map(changeset, attribute) do
    case Ash.Changeset.get_attribute(changeset, attribute) do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  defp stored_map(changeset, attribute) do
    case Map.get(changeset.data || %{}, attribute) do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  defp param_supplied?(changeset, key) do
    params = changeset.params || %{}

    Map.has_key?(params, Atom.to_string(key)) or Map.has_key?(params, key)
  end
end
