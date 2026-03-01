defmodule ServiceRadar.Identity.Changes.RevokeUserAccess do
  @moduledoc """
  Revokes user access by disabling API tokens and OAuth clients.

  Intended for use when a user is deactivated.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.ApiToken
  alias ServiceRadar.Identity.OAuthClient

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user, context ->
      actor = get_actor(context)
      revoke_user_access(user, actor)
      {:ok, user}
    end)
  end

  @doc """
  Revokes API tokens and OAuth clients for the given user.
  """
  @spec revoke_user_access(map(), map() | nil) :: :ok
  def revoke_user_access(user, actor) do
    revoked_by = actor_email(actor) || "system"
    policy_actor = SystemActor.system(:revoke_user_access)

    revoke_api_tokens(user.id, policy_actor, revoked_by)
    revoke_oauth_clients(user.id, policy_actor)

    :ok
  end

  defp revoke_api_tokens(user_id, actor, revoked_by) do
    ApiToken
    |> Ash.Query.for_read(:by_user, %{user_id: user_id}, actor: actor)
    |> Ash.read()
    |> case do
      {:ok, tokens} ->
        Enum.each(tokens, fn token ->
          token
          |> Ash.Changeset.for_update(:revoke, %{revoked_by: revoked_by}, actor: actor)
          |> Ash.update()
        end)

      {:error, _} ->
        :ok
    end
  end

  defp revoke_oauth_clients(user_id, actor) do
    OAuthClient
    |> Ash.Query.for_read(:by_user, %{user_id: user_id}, actor: actor)
    |> Ash.read()
    |> case do
      {:ok, clients} ->
        Enum.each(clients, fn client ->
          client
          |> Ash.Changeset.for_update(:revoke, %{}, actor: actor)
          |> Ash.update()
        end)

      {:error, _} ->
        :ok
    end
  end

  defp get_actor(%{private: %{actor: actor}}), do: actor
  defp get_actor(%{actor: actor}), do: actor
  defp get_actor(_), do: nil

  defp actor_email(%{email: email}) when is_binary(email), do: email
  defp actor_email(_), do: nil
end
