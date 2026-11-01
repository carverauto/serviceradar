defmodule ServiceRadar.Edge.ManagedComponentNatsPermissions do
  @moduledoc "Canonical subject grants for the fixed managed-service configuration."

  def for_component(%{component_type: "nats-leaf"}), do: %{publish: [">"], subscribe: [">"]}

  def for_component(%{component_type: type, nats_permissions: permissions})
      when is_map(permissions) do
    if ServiceRadar.Edge.ManagedComponent.infrastructure_type?(type) do
      for key <- [:publish, :subscribe, :publish_deny, :subscribe_deny],
          value = Map.get(permissions, key, Map.get(permissions, Atom.to_string(key))),
          is_list(value),
          into: %{},
          do: {key, value}
    end
  end

  def for_component(component) do
    case transport(component.component_type) do
      nil ->
        nil

      %{subjects: subjects, stream: stream} ->
        apis =
          if Map.get(component, :edge_site_id),
            do: ["$JS.API", "$JS.#{jetstream_domain(component.edge_site_id)}.API"],
            else: ["$JS.API"]

        requests =
          for api <- apis,
              action <- ["INFO", "CREATE", "UPDATE"],
              do: "#{api}.STREAM.#{action}.#{stream}"

        %{publish: subjects ++ requests ++ ["$JS.ACK.>", "_INBOX.>"], subscribe: ["_INBOX.>"]}
    end
  end

  @doc "Stable JetStream domain for one edge site's independent persistence store."
  def jetstream_domain(edge_site_id) when is_binary(edge_site_id),
    do: "edge_" <> String.replace(edge_site_id, "-", "")

  def transport("log-collector"),
    do: %{
      subjects: ["logs.syslog", "logs.otel", "otel.traces.>", "otel.metrics.>"],
      stream: "events"
    }

  def transport("flow-collector"),
    do: %{subjects: ["flows.raw.netflow", "flows.raw.sflow"], stream: "flows"}

  def transport("trapd"), do: %{subjects: ["logs.snmp"], stream: "events"}

  def transport("bmp-collector"),
    do: %{subjects: ["arancini.updates.>"], stream: "ARANCINI_CAUSAL"}

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
