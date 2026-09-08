defmodule ServiceRadar.Inventory.SourceFacts.Events do
  @moduledoc """
  OCSF timeline events for source-fact disagreement open/change/clear.

  The durable report is `platform.source_fact_disagreements`. Events are
  emitted only on state changes.
  """

  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Repo

  require Logger

  @spec emit(atom(), map()) :: :ok
  def emit(kind, disagreement)
      when kind in [:opened, :changed, :cleared] and is_map(disagreement) do
    now = DateTime.utc_now()
    activity_id = activity_id(kind)
    class_uid = OCSF.class_event_log_activity()
    event_uuid = Ecto.UUID.generate()

    row = %{
      id: Ecto.UUID.dump!(event_uuid),
      time: now,
      class_uid: class_uid,
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(class_uid, activity_id),
      activity_id: activity_id,
      activity_name: activity_name(kind),
      severity_id: if(kind == :cleared, do: 1, else: 2),
      severity: if(kind == :cleared, do: "Info", else: "Low"),
      message: message(kind, disagreement),
      status_id: if(kind == :cleared, do: 1, else: 2),
      status: if(kind == :cleared, do: "Success", else: "Other"),
      status_detail: to_string(kind),
      metadata: %{
        "product" => %{"name" => "ServiceRadar", "vendor_name" => "Carver Automation"},
        "version" => OCSF.schema_version(),
        "log_name" => "source_fact_disagreement",
        "log_provider" => "source_facts"
      },
      observables: [],
      actor: %{},
      device: %{"uid" => disagreement[:device_uid] || disagreement["device_uid"]},
      src_endpoint: %{},
      dst_endpoint: %{},
      log_name: "source_fact_disagreement",
      log_provider: "source_facts",
      log_level: "INFO",
      unmapped: %{
        "fact_key" => disagreement[:fact_key] || disagreement["fact_key"],
        "disagreement_id" => disagreement[:id] || disagreement["id"],
        "values" => disagreement[:values] || disagreement["values"],
        "configuration_conflict" =>
          disagreement[:configuration_conflict] || disagreement["configuration_conflict"] || false
      },
      raw_data: %{}
    }

    Repo.insert_all("ocsf_events", [row],
      prefix: "platform",
      on_conflict: :nothing,
      conflict_target: [:time, :id],
      returning: false
    )

    :ok
  rescue
    error ->
      Logger.warning("Source fact disagreement event failed: #{Exception.message(error)}")
      :ok
  end

  def emit(_kind, _disagreement), do: :ok

  defp activity_id(:opened), do: OCSF.activity_log_create()
  defp activity_id(:changed), do: OCSF.activity_log_update()
  defp activity_id(:cleared), do: OCSF.activity_log_delete()

  defp activity_name(:opened), do: "Create"
  defp activity_name(:changed), do: "Update"
  defp activity_name(:cleared), do: "Delete"

  defp message(kind, disagreement) do
    fact_key = disagreement[:fact_key] || disagreement["fact_key"] || "fact"
    device_uid = disagreement[:device_uid] || disagreement["device_uid"] || "unknown"
    "#{kind} source fact disagreement #{fact_key} on #{device_uid}"
  end
end
