defmodule ServiceRadar.Notifications.Validations.ProviderActionKeyDeclared do
  @moduledoc """
  Binds a `:wasm_plugin` provider's `action_key` to a notifier its package
  actually ships (design D2, tasks 3.1.1b).

  `NotificationProvider` already enforces the shape of the plugin reference: a
  `:wasm_plugin` row carries both `plugin_package_id` and `action_key`, and no
  other tier carries either. That is the half Phase 1 could enforce with no
  manifest block to consult. This validation is the other half - the `action_key`
  must name a `key` in the referenced package's validated `notifications:` block.

  Without it, `action_key` is free text. A typo saves cleanly, activates cleanly,
  and then fails on the agent at the worst possible moment: the first page. The
  cost of catching it here is one read of a row the operator just chose.

  ## Why the manifest is re-validated rather than trusted

  `PluginPackage.manifest` was validated by whatever release imported it. A
  package imported before the `notifications:` block existed has no block; one
  imported by an older release may have a block this release would now reject.
  `ServiceRadar.Plugins.Manifest.notification_keys/1` re-runs the current
  validator, so the answer is always "what THIS release can resolve", and an
  unreadable block is reported rather than silently treated as "declares
  nothing".

  ## Missing package

  A package that cannot be read is deliberately NOT reported here. The
  `plugin_package_id` foreign key raises that, and reporting it from this
  validation would mask the real cause behind a message about action keys. This
  mirrors `ServiceRadar.Notifications.Validations.ChannelFallbackChain`.

  ## Atomicity

  `plugin_package_id` and `action_key` are create-only on `NotificationProvider`
  (they are absent from its `@updatable_fields`), so there is nothing for this
  validation to re-check on an update and it does no database work there. The
  lookup yields a decision rather than an attribute, so `atomic/3` reports that
  decision directly and the enclosing update stays atomic instead of needing
  `require_atomic? false`.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadar.Plugins.PluginPackage

  @impl true
  def validate(changeset, _opts, _context) do
    with :wasm_plugin <- pending(changeset, :provider_type),
         true <- plugin_reference_changing?(changeset),
         action_key when is_binary(action_key) <- pending(changeset, :action_key),
         package_id when not is_nil(package_id) <- pending(changeset, :plugin_package_id) do
      validate_declared(package_id, action_key)
    else
      _not_applicable -> :ok
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  # On an update neither field can change, so the stored pair was already
  # checked by the action that wrote it and a second database read would buy
  # nothing. On a create both are always present as changes.
  defp plugin_reference_changing?(changeset) do
    changing?(changeset, :action_key) or changing?(changeset, :plugin_package_id)
  end

  defp changing?(changeset, field) do
    Keyword.has_key?(changeset.atomics, field) or
      match?({:ok, _value}, Ash.Changeset.fetch_change(changeset, field))
  end

  defp validate_declared(package_id, action_key) do
    actor = SystemActor.system(:notification_provider_action_key)

    case Ash.get(PluginPackage, package_id, actor: actor) do
      {:ok, package} -> validate_against_manifest(package, action_key)
      _unreadable -> :ok
    end
  end

  defp validate_against_manifest(package, action_key) do
    case Manifest.notification_keys(package.manifest || %{}) do
      {:ok, []} ->
        {:error,
         field: :action_key,
         message: "package #{package_label(package)} declares no notifications entries"}

      {:ok, keys} ->
        if action_key in keys do
          :ok
        else
          {:error,
           field: :action_key,
           message:
             "package #{package_label(package)} declares no notifier with this key; declared keys: #{Enum.join(keys, ", ")}"}
        end

      {:error, errors} ->
        {:error,
         field: :action_key,
         message:
           "package #{package_label(package)} has an unreadable notifications block: #{Enum.join(errors, "; ")}"}
    end
  end

  defp package_label(%{plugin_id: plugin_id, version: version})
       when is_binary(plugin_id) and is_binary(version) do
    "#{plugin_id}@#{version}"
  end

  defp package_label(%{id: id}), do: to_string(id)

  # Resolve the value this action is about to persist.
  #
  # In an atomic update the casted value lives in `changeset.atomics` rather
  # than in `changeset.attributes`, so reading only the attributes would see a
  # stale value. `Ash.Changeset.get_attribute/2` is deliberately NOT used: it
  # falls through to `get_data/2`, which RAISES when the changeset carries
  # `%OriginalDataNotAvailable{}` - exactly the case a bulk atomic update hits.
  defp pending(changeset, field) do
    with :error <- Keyword.fetch(changeset.atomics, field),
         :error <- Ash.Changeset.fetch_change(changeset, field) do
      original(changeset, field)
    else
      {:ok, value} -> value
    end
  end

  defp original(changeset, field) do
    case changeset.data do
      %{^field => value} -> value
      _other -> nil
    end
  end
end
