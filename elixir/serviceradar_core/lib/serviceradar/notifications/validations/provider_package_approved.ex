defmodule ServiceRadar.Notifications.Validations.ProviderPackageApproved do
  @moduledoc """
  A plugin-backed provider may only be ACTIVATED while its package is approved
  (tasks 3.3.2).

  ## Why activation and not creation

  A `NotificationProvider` starts `:draft` and reaches `:active` only when an
  operator says so, and the two states mean different things about the package
  underneath. Registering a provider against a package still in review is a
  normal workflow - the reviewer approves the package, then the provider is
  activated - so `create` deliberately does not require approval. What must not
  happen is a provider that is *usable* while its package is not, and the state
  transition is exactly that moment.

  ## Why this is not the whole of 3.3.2

  It is the operator-facing half. The enforcing half is at dispatch:
  `ServiceRadar.Notifications.PluginTarget` refuses to resolve a target for an
  unapproved package, so a revocation that happens between activation and a page
  still cannot deliver. Both are needed, because they fail at different times
  and only one of them can explain itself in a form:

    * a provider whose package was revoked cannot be re-activated, and the
      operator is told why;
    * a provider already active when the revocation lands is deactivated by
      `ServiceRadar.Notifications.PackageApprovalWatcher`, and even if that
      signal is missed the dispatch still refuses.

  `:disable` is deliberately NOT validated. Turning off a provider whose package
  was revoked is the correct response to a revocation, and a validation that
  blocked it would trap exactly the rows an operator most needs to clean up.

  ## Atomicity

  The check yields a decision rather than an attribute, so `atomic/3` reports
  that decision directly and the enclosing update stays atomic instead of
  needing `require_atomic? false`. `plugin_package_id` is create-only on
  `NotificationProvider`, so the value read here is always the stored one on the
  activation path.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginPackage

  @impl true
  def validate(changeset, _opts, _context) do
    with :wasm_plugin <- pending(changeset, :provider_type),
         package_id when not is_nil(package_id) <- pending(changeset, :plugin_package_id) do
      validate_approved(package_id)
    else
      _not_applicable -> :ok
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  defp validate_approved(package_id) do
    actor = SystemActor.system(:notification_provider_package_approval)

    case Ash.get(PluginPackage, package_id, actor: actor) do
      {:ok, %{status: :approved}} ->
        :ok

      {:ok, %{status: status} = package} ->
        {:error,
         field: :plugin_package_id,
         message:
           "plugin package #{label(package)} is #{status}; only an approved package may back an active notification provider"}

      # A package that cannot be read is reported by the foreign key, not here.
      # Mirrors ServiceRadar.Notifications.Validations.ProviderActionKeyDeclared.
      _unreadable ->
        :ok
    end
  end

  defp label(%{plugin_id: plugin_id, version: version})
       when is_binary(plugin_id) and is_binary(version),
       do: "#{plugin_id}@#{version}"

  defp label(%{id: id}), do: to_string(id)

  # Resolve the value this action is about to persist. `Ash.Changeset.get_attribute/2`
  # is deliberately not used: it falls through to `get_data/2`, which RAISES on
  # `%OriginalDataNotAvailable{}` - the case a bulk atomic update hits.
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
