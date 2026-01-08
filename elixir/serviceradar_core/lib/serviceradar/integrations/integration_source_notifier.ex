defmodule ServiceRadar.Integrations.IntegrationSourceNotifier do
  @moduledoc """
  Ash notifier for IntegrationSource lifecycle events.

  Writes OCSF Event Log Activity events directly to the ocsf_events table
  when integration sources are created, updated, enabled, disabled, or deleted.
  These events provide an audit trail visible in the UI.
  """

  use Ash.Notifier

  require Logger

  alias ServiceRadar.EventWriter.OCSF

  @impl Ash.Notifier
  def notify(%Ash.Notifier.Notification{
        resource: ServiceRadar.Integrations.IntegrationSource,
        action: %{name: action_name, type: action_type},
        data: record,
        changeset: changeset
      }) do
    actor = get_actor(changeset)
    {activity_id, activity_name, action_verb} = activity_for_action(action_name, action_type)

    Task.start(fn ->
      write_ocsf_event(record, activity_id, activity_name, action_verb, actor)
    end)

    :ok
  end

  def notify(_notification), do: :ok

  defp write_ocsf_event(record, activity_id, activity_name, action_verb, actor) do
    tenant_id = record.tenant_id
    now = DateTime.utc_now()

    message = build_message(record, action_verb, actor)

    event = %{
      id: UUID.uuid4(),
      time: now,
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
      activity_id: activity_id,
      activity_name: activity_name,
      severity_id: OCSF.severity_informational(),
      severity: "Informational",
      message: message,
      status_id: OCSF.status_success(),
      status: "Success",
      status_code: nil,
      status_detail: nil,
      metadata: OCSF.build_metadata(
        version: "1.7.0",
        product_name: "ServiceRadar Core",
        correlation_uid: "integration_source:#{record.id}"
      ),
      observables: build_observables(record),
      trace_id: nil,
      span_id: nil,
      actor: build_actor(actor),
      device: nil,
      src_endpoint: nil,
      log_name: "integration_sources",
      log_provider: "serviceradar.core",
      log_level: "info",
      log_version: nil,
      unmapped: build_unmapped(record, action_verb),
      raw_data: nil,
      tenant_id: tenant_id,
      created_at: now
    }

    case ServiceRadar.Repo.insert_all("ocsf_events", [event], on_conflict: :nothing) do
      {1, _} ->
        :ok

      {0, _} ->
        Logger.warning("Failed to insert OCSF event for integration source #{record.id}")
        :ok
    end
  rescue
    e ->
      Logger.error("Error writing OCSF event: #{inspect(e)}")
      :ok
  end

  defp build_message(record, action_verb, nil) do
    "Integration source '#{record.name}' #{action_verb}"
  end

  defp build_message(record, action_verb, actor) do
    actor_email = Map.get(actor, :email, "unknown")
    "Integration source '#{record.name}' #{action_verb} by #{actor_email}"
  end

  defp build_observables(record) do
    observables = []

    observables =
      if record.name do
        [%{name: record.name, type: "Resource Name", type_id: 99} | observables]
      else
        observables
      end

    observables =
      if record.endpoint do
        [%{name: record.endpoint, type: "URL String", type_id: 6} | observables]
      else
        observables
      end

    observables
  end

  defp build_actor(nil), do: nil

  defp build_actor(actor) when is_map(actor) do
    user =
      %{}
      |> maybe_put(:uid, Map.get(actor, :id) |> to_string_or_nil())
      |> maybe_put(:email_addr, Map.get(actor, :email))
      |> maybe_put(:name, Map.get(actor, :email))

    if map_size(user) > 0 do
      %{user: user}
    else
      nil
    end
  end

  defp build_actor(_), do: nil

  defp build_unmapped(record, action_verb) do
    %{
      "resource_type" => "integration_source",
      "resource_id" => to_string(record.id),
      "action" => action_verb,
      "integration_source" => %{
        "id" => to_string(record.id),
        "name" => record.name,
        "source_type" => record.source_type && Atom.to_string(record.source_type),
        "endpoint" => record.endpoint,
        "enabled" => record.enabled,
        "agent_id" => record.agent_id,
        "partition" => record.partition
      }
    }
  end

  defp activity_for_action(:create, _), do: {OCSF.activity_log_create(), "Create", "created"}
  defp activity_for_action(:update, _), do: {OCSF.activity_log_update(), "Update", "updated"}
  defp activity_for_action(:enable, _), do: {OCSF.activity_log_update(), "Update", "enabled"}
  defp activity_for_action(:disable, _), do: {OCSF.activity_log_update(), "Update", "disabled"}
  defp activity_for_action(:delete, _), do: {OCSF.activity_log_delete(), "Delete", "deleted"}
  defp activity_for_action(_, :destroy), do: {OCSF.activity_log_delete(), "Delete", "deleted"}
  defp activity_for_action(action, _), do: {OCSF.activity_log_update(), "Update", Atom.to_string(action)}

  defp get_actor(%Ash.Changeset{context: %{private: %{actor: actor}}}), do: actor
  defp get_actor(%Ash.Changeset{context: %{actor: actor}}), do: actor
  defp get_actor(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)
end
