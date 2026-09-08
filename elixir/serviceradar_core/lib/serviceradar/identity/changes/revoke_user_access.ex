defmodule ServiceRadar.Identity.Changes.RevokeUserAccess do
  @moduledoc """
  Revokes user access by disabling API tokens and OAuth clients.

  Intended for use when a user is deactivated.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AshContext
  alias ServiceRadar.Changes.AfterAction
  alias ServiceRadar.Identity.ApiToken
  alias ServiceRadar.Identity.OAuthClient

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    actor = AshContext.actor(context)

    AfterAction.after_action(changeset, fn user ->
      revoke_user_access(user, actor)
    end)
  end

  @doc """
  Revokes API tokens and OAuth clients for the given user.
  """
  @spec revoke_user_access(map(), map() | nil) :: :ok
  def revoke_user_access(user, actor) do
    revoked_by = actor_email(actor) || "system"
    policy_actor = SystemActor.system(:revoke_user_access)

    revoke_owned_credentials(ApiToken, user.id, policy_actor, %{revoked_by: revoked_by})
    revoke_owned_credentials(OAuthClient, user.id, policy_actor, %{})

    :ok
  end

  defp revoke_owned_credentials(resource, user_id, actor, attrs) do
    resource
    |> Ash.Query.for_read(:by_user, %{user_id: user_id}, actor: actor)
    |> Ash.read()
    |> case do
      {:ok, records} ->
        Enum.each(records, fn record ->
          record
          |> Ash.Changeset.for_update(:revoke, attrs, actor: actor)
          |> Ash.update()
        end)

      {:error, _} ->
        :ok
    end
  end

  defp actor_email(%{email: email}) when is_binary(email), do: email
  defp actor_email(_), do: nil
end
