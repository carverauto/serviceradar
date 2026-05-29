defmodule ServiceRadar.SweepJobs.Checks.EnablingBannerGrabWithoutPermission do
  @moduledoc """
  Forbids enabling or changing active banner grab unless the actor has the explicit permission.
  """

  use Ash.Policy.SimpleCheck

  alias Ash.Policy.Authorizer
  alias ServiceRadar.Identity.RBAC

  @permission "networks.sweeps.banner_grab"

  @impl true
  def describe(_opts), do: "actor lacks permission to change banner grab"

  @impl true
  def match?(actor, %Authorizer{} = authorizer, opts) when is_list(opts) do
    match?(actor, %{changeset: Map.get(authorizer, :changeset)}, opts)
  end

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, opts) do
    permission = Keyword.get(opts, :permission, @permission)

    banner_grab_changed_while_enabled?(changeset) and not actor_has_permission?(actor, permission)
  end

  def match?(_actor, _context, _opts), do: false

  defp banner_grab_changed_while_enabled?(%Ash.Changeset{} = changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :banner_grab) do
      prior_banner_grab = Map.get(changeset.data || %{}, :banner_grab)
      new_banner_grab = Ash.Changeset.get_attribute(changeset, :banner_grab)

      enabled?(new_banner_grab) and normalized(prior_banner_grab) != normalized(new_banner_grab)
    else
      false
    end
  end

  defp normalized(%_{} = banner_grab) do
    banner_grab
    |> Map.from_struct()
    |> Map.drop([:__metadata__, :__meta__, :aggregates, :calculations, :relationships])
    |> normalized()
  end

  defp normalized(%{} = banner_grab) do
    Map.new(banner_grab, fn {key, value} -> {to_string(key), normalized(value)} end)
  end

  defp normalized(values) when is_list(values), do: Enum.map(values, &normalized/1)
  defp normalized(value) when is_atom(value), do: Atom.to_string(value)
  defp normalized(value), do: value

  defp enabled?(%{enabled: true}), do: true
  defp enabled?(%{"enabled" => true}), do: true
  defp enabled?(_banner_grab), do: false

  defp actor_has_permission?(nil, _permission), do: false

  defp actor_has_permission?(%{permissions: %MapSet{} = permissions}, permission),
    do: MapSet.member?(permissions, permission)

  defp actor_has_permission?(actor, permission), do: RBAC.has_permission?(actor, permission)
end
