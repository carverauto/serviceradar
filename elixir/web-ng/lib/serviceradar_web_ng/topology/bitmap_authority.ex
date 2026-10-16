defmodule ServiceRadarWebNG.Topology.BitmapAuthority do
  @moduledoc "Current inventory policy authority, including role-profile revisions."

  alias ServiceRadar.Identity.CurrentUserAuthority
  alias ServiceRadarWebNG.Accounts.Scope

  # Device and Interface read policies currently grant deployment-wide visibility
  # through devices.view. A future finer policy must change this projection before
  # it can enable bitmap APIs; the fingerprint alone is not a visibility filter.
  def current(%Scope{user: user} = scope) when not is_nil(user) do
    case CurrentUserAuthority.authorize(scope, ["analytics.view", "devices.view"]) do
      {:ok, authority} ->
        fingerprint =
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary(
              {
                :inventory_policy_v1,
                to_string(authority.user.id),
                Enum.sort(authority.permissions),
                Enum.sort(authority.profile_versions),
                scope.identity_claims
              },
              [:deterministic]
            )
          )

        {:ok, fingerprint}

      _ ->
        {:error, :forbidden}
    end
  end

  def current(_scope), do: {:error, :unauthorized}
end
