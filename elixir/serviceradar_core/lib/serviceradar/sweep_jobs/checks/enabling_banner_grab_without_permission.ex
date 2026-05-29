defmodule ServiceRadar.SweepJobs.Checks.EnablingBannerGrabWithoutPermission do
  @moduledoc """
  Forbids enabling active banner grab unless the actor has the explicit permission.
  """

  use Ash.Policy.SimpleCheck

  alias Ash.Policy.Authorizer
  alias ServiceRadar.Identity.RBAC

  @permission "networks.sweeps.banner_grab"

  @impl true
  def describe(_opts), do: "actor lacks permission to enable banner grab"

  @impl true
  def match?(actor, %Authorizer{} = authorizer, opts) when is_list(opts) do
    match?(actor, %{changeset: Map.get(authorizer, :changeset)}, opts)
  end

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, opts) do
    permission = Keyword.get(opts, :permission, @permission)

    enabling_banner_grab?(changeset) and not actor_has_permission?(actor, permission)
  end

  def match?(_actor, _context, _opts), do: false

  defp enabling_banner_grab?(%Ash.Changeset{} = changeset) do
    prior_enabled? =
      if changeset.action_type == :create do
        false
      else
        enabled?(Map.get(changeset.data || %{}, :banner_grab))
      end

    new_enabled? = enabled?(Ash.Changeset.get_attribute(changeset, :banner_grab))

    not prior_enabled? and new_enabled?
  end

  defp enabled?(%{enabled: true}), do: true
  defp enabled?(%{"enabled" => true}), do: true
  defp enabled?(_banner_grab), do: false

  defp actor_has_permission?(nil, _permission), do: false

  defp actor_has_permission?(%{permissions: %MapSet{} = permissions}, permission),
    do: MapSet.member?(permissions, permission)

  defp actor_has_permission?(actor, permission), do: RBAC.has_permission?(actor, permission)
end
