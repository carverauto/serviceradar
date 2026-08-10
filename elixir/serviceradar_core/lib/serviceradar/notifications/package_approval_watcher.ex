defmodule ServiceRadar.Notifications.PackageApprovalWatcher do
  @moduledoc """
  Deactivates notification providers when the plugin package behind them stops
  being approved (tasks 3.3.2).

  Revoking a package is a security action: it says "stop running this code".
  A `NotificationProvider` bound to it is a live route from an alert to that
  code, so leaving it `:active` would leave the revocation half-applied - the
  UI would still offer the provider, channels would still bind to it, and only
  the dispatch would refuse.

  ## An Ash notifier, and what that does and does not guarantee

  This runs after `ServiceRadar.Plugins.PluginPackage`'s `:revoke` and `:deny`
  commit. A notifier is used rather than a change on the action because
  `:revoke` is atomic, and an `after_action` hook inside a change is the Ash
  trap that goes silently inert on an atomic update - the change never runs and
  nothing says so. A notifier is outside that path entirely and needs no
  `require_atomic? false`.

  What a notifier does NOT give is a guarantee. It is a signal: a bulk update
  that bypasses the action, a node that dies between commit and notify, or a
  future code path that writes `status` directly would all skip it. That is why
  the enforcing check lives at dispatch in
  `ServiceRadar.Notifications.PluginTarget`, which reads the package's status
  every time it resolves a target. This watcher makes the *state* consistent;
  `PluginTarget` makes the *behaviour* safe.

  Failures are logged and swallowed. A revocation must succeed even if the
  provider write does not - a package that stays revoked with a stale provider
  row is recoverable, and a revocation that rolls back because of a downstream
  bookkeeping error is not.
  """

  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Notifications.NotificationProvider

  require Ash.Query
  require Logger

  # The transitions that take a package out of `:approved`, plus `:deny`, which
  # cannot be reached from `:approved` today but is the other "this package is
  # not usable" verdict and costs nothing to cover.
  @deactivating_actions [:revoke, :deny]

  @impl Ash.Notifier
  def notify(%Notification{action: %{name: name}, data: %{id: package_id}})
      when name in @deactivating_actions do
    _ = disable_providers_for_package(package_id)
    :ok
  end

  def notify(_notification), do: :ok

  @doc """
  Disables every `:active` provider bound to `package_id`.

  `:draft` rows are deliberately left alone. A draft provider is already inert -
  `Suppression` withholds any dispatch to a channel whose provider is not
  `:active` - and `ServiceRadar.Notifications.Validations.ProviderPackageApproved`
  stops it being activated while the package is unapproved. Disabling it too
  would churn rows for no gain and would take away the operator's ability to
  disable it themselves, since `:disabled` has no outbound transition.

  Exposed so an operator task or a test can reconcile without staging a
  revocation. Returns the ids it disabled.
  """
  @spec disable_providers_for_package(binary(), keyword()) :: [binary()]
  def disable_providers_for_package(package_id, opts \\ []) do
    actor =
      Keyword.get_lazy(opts, :actor, fn -> SystemActor.system(:notification_package_approval) end)

    NotificationProvider
    |> Ash.Query.filter(plugin_package_id == ^package_id and status == :active)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, providers} ->
        Enum.flat_map(providers, &disable(&1, actor, package_id))

      {:error, reason} ->
        Logger.error("could not read notification providers for a revoked plugin package",
          plugin_package_id: to_string(package_id),
          reason: inspect(reason)
        )

        []
    end
  end

  defp disable(provider, actor, package_id) do
    provider
    |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
    |> Ash.update(actor: actor)
    |> case do
      {:ok, disabled} ->
        Logger.warning("disabled a notification provider whose plugin package lost approval",
          provider_id: disabled.id,
          provider_key: disabled.provider_key,
          plugin_package_id: to_string(package_id)
        )

        [disabled.id]

      {:error, reason} ->
        Logger.error("could not disable a notification provider after a package revocation",
          provider_id: provider.id,
          plugin_package_id: to_string(package_id),
          reason: inspect(reason)
        )

        []
    end
  end
end
