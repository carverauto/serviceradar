defmodule ServiceRadar.Edge.ManagedComponentNatsPermissions do
  @moduledoc "Canonical subject grants for the fixed managed-service configuration."

  def for_component(%{component_type: "nats-leaf"}), do: %{publish: [">"], subscribe: [">"]}

  def for_component(component) do
    case transport(component.component_type) do
      nil ->
        nil

      %{subjects: subjects, stream: stream} ->
        apis =
          if Map.get(component, :edge_site_id), do: ["$JS.API", "$JS.edge.API"], else: ["$JS.API"]

        requests =
          for api <- apis,
              action <- ["INFO", "CREATE", "UPDATE"],
              do: "#{api}.STREAM.#{action}.#{stream}"

        %{publish: subjects ++ requests ++ ["$JS.ACK.>", "_INBOX.>"], subscribe: ["_INBOX.>"]}
    end
  end

  def transport("log-collector"),
    do: %{
      subjects: ["logs.syslog", "logs.otel", "otel.traces.>", "otel.metrics.>"],
      stream: "events"
    }

  def transport("flow-collector"),
    do: %{subjects: ["flows.raw.netflow", "flows.raw.sflow"], stream: "flows"}

  def transport("trapd"), do: %{subjects: ["logs.snmp"], stream: "events"}
  def transport("bmp-collector"), do: %{subjects: ["arancini.updates"], stream: "ARANCINI_CAUSAL"}
  def transport(_), do: nil

  def snapshot(components, certificates, allowed) do
    components = Map.new(components, &{&1.component_id, &1})
    allowed = MapSet.new(allowed)

    for certificate <- certificates,
        MapSet.member?(allowed, certificate.fingerprint),
        certificate.role != "local_server",
        permissions = for_component(Map.fetch!(components, certificate.component_id)),
        permissions != nil,
        into: %{},
        do: {certificate.fingerprint, permissions}
  end
end
