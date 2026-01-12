defmodule ServiceRadar.AgentConfig.Changes.CreateVersionHistory do
  @moduledoc """
  Creates a version history record when a config instance is updated.

  This captures the state before the update for audit and rollback purposes.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      # Only create history if the config content is actually changing
      if Ash.Changeset.changing_attribute?(changeset, :compiled_config) do
        create_history_record(changeset, context)
      else
        changeset
      end
    end)
  end

  defp create_history_record(changeset, context) do
    # Get current values before they're updated
    config_instance_id = Ash.Changeset.get_data(changeset, :id)
    current_version = Ash.Changeset.get_data(changeset, :version) || 0
    current_config = Ash.Changeset.get_data(changeset, :compiled_config) || %{}
    current_hash = Ash.Changeset.get_data(changeset, :content_hash) || ""
    current_source_ids = Ash.Changeset.get_data(changeset, :source_ids) || []
    tenant = changeset.tenant

    # Extract actor info if available
    {actor_id, actor_email} = extract_actor_info(context)

    if is_nil(tenant) do
      Ash.Changeset.add_error(changeset,
        field: :tenant_id,
        message: "tenant context is required to record config history"
      )
    else
      # Create the version record
      version_attrs = %{
        config_instance_id: config_instance_id,
        version: current_version,
        compiled_config: current_config,
        content_hash: current_hash,
        source_ids: current_source_ids,
        actor_id: actor_id,
        actor_email: actor_email,
        change_reason: "Config updated"
      }

      case create_version(version_attrs, tenant, context) do
        {:ok, _version} ->
          changeset

        {:error, error} ->
          Logger.warning("Failed to create config version history: #{inspect(error)}")
          # Don't fail the main operation if history creation fails
          changeset
      end
    end
  end

  defp extract_actor_info(context) do
    case Map.get(context, :actor) do
      %{id: id, email: email} -> {id, email}
      %{id: id} -> {id, nil}
      _ -> {nil, nil}
    end
  end

  defp create_version(attrs, tenant, context) do
    actor = Map.get(context, :actor)

    ServiceRadar.AgentConfig.ConfigVersion
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(authorize?: false, tenant: tenant, actor: actor)
  end
end
