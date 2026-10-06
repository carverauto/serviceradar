defmodule ServiceRadar.Identity.Changes.RecordRoleChange do
  @moduledoc """
  Ash change that records user role and role profile changes in `platform.user_auth_events`.

  Appends an immutable audit event (`event_type: "role_change"`) whenever a user's
  role or role_profile_id changes.
  """
  use Ash.Resource.Change

  alias ServiceRadar.AshContext
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.UserAuthEvent

  require Logger

  @impl true
  def change(changeset, _opts, context) do
    if Map.get(changeset.context, :skip_role_change_audit) == true do
      changeset
    else
      Ash.Changeset.after_action(changeset, fn changeset, record ->
        old_role = if changeset.action_type == :create, do: nil, else: changeset.data.role
        new_role = record.role

        old_profile_id =
          if changeset.action_type == :create, do: nil, else: changeset.data.role_profile_id

        new_profile_id =
          case Map.fetch(changeset.context, :new_role_profile_id) do
            {:ok, id} -> id
            :error -> record.role_profile_id
          end

        role_changed? = not is_nil(new_role) and to_string(old_role) != to_string(new_role)
        profile_changed? = to_string(old_profile_id || "") != to_string(new_profile_id || "")

        if role_changed? or profile_changed? do
          actor = resolve_actor(context, changeset)

          actor_user_id = resolve_actor_user_id(actor)

          metadata =
            %{
              "old_role" => stringify(old_role),
              "new_role" => stringify(new_role)
            }
            |> maybe_put("old_role_profile_id", stringify(old_profile_id))
            |> maybe_put("new_role_profile_id", stringify(new_profile_id))
            |> maybe_put("actor", format_actor(actor))

          attrs = %{
            user_id: record.id,
            actor_user_id: actor_user_id,
            event_type: "role_change",
            metadata: metadata
          }

          system_actor = SystemActor.system(:user_auth_events)

          UserAuthEvent
          |> Ash.Changeset.for_create(:create, attrs, actor: system_actor)
          |> Ash.create()
          |> case do
            {:ok, _event} ->
              {:ok, record}

            {:error, reason} ->
              Logger.error(
                "Failed to record role_change audit event for user #{record.id}: #{inspect(reason)}"
              )

              {:error, reason}
          end
        else
          {:ok, record}
        end
      end)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp resolve_actor(context, changeset) do
    cond do
      is_struct(context) and Map.has_key?(context, :actor) and not is_nil(context.actor) ->
        context.actor

      is_map(context) and not is_nil(Map.get(context, :actor)) ->
        Map.get(context, :actor)

      not is_nil(AshContext.actor(changeset)) ->
        AshContext.actor(changeset)

      is_map(changeset.context) and not is_nil(Map.get(changeset.context, :scope)) ->
        Map.get(changeset.context, :scope)

      true ->
        nil
    end
  end

  defp resolve_actor_user_id(%{role: :system}), do: nil
  defp resolve_actor_user_id(%User{id: id}) when is_binary(id), do: check_uuid(id)
  defp resolve_actor_user_id(%{user: %User{id: id}}) when is_binary(id), do: check_uuid(id)
  defp resolve_actor_user_id(%{user: %{id: id}}) when is_binary(id), do: check_uuid(id)
  defp resolve_actor_user_id(%{id: id}) when is_binary(id), do: check_uuid(id)
  defp resolve_actor_user_id(_), do: nil

  defp check_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp format_actor(%User{email: email})
       when (is_binary(email) and email != "") or is_struct(email, Ash.CiString),
       do: to_string(email)

  defp format_actor(%User{id: id}), do: to_string(id)

  defp format_actor(%{user: %User{email: email}})
       when (is_binary(email) and email != "") or is_struct(email, Ash.CiString),
       do: to_string(email)

  defp format_actor(%{user: %User{id: id}}), do: to_string(id)

  defp format_actor(%{user: %{email: email}})
       when (is_binary(email) and email != "") or is_struct(email, Ash.CiString),
       do: to_string(email)

  defp format_actor(%{user: %{id: id}}), do: to_string(id)

  defp format_actor(%{role: :system, email: email})
       when (is_binary(email) and email != "") or is_struct(email, Ash.CiString),
       do: to_string(email)

  defp format_actor(%{role: :system, id: id}) when is_binary(id) and id != "", do: id

  defp format_actor(%{email: email})
       when (is_binary(email) and email != "") or is_struct(email, Ash.CiString),
       do: to_string(email)

  defp format_actor(%{id: id}) when is_binary(id), do: id
  defp format_actor(nil), do: "system"
  defp format_actor(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp format_actor(other), do: to_string(other)

  defp stringify(nil), do: nil
  defp stringify(val) when is_atom(val), do: Atom.to_string(val)
  defp stringify(val), do: to_string(val)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end
