defmodule ServiceRadar.Observability.ServiceStateRegistry.StatusNormalizer do
  @moduledoc false

  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  @streaming_plugin_capability "camera_media_stream"
  @streaming_plugin_output "serviceradar.camera_stream.v1"
  @plugin_result_output "serviceradar.plugin_result.v1"

  @doc false
  def attrs_from_status(status, actor, opts \\ []) do
    raw_message = fetch(status, :message)
    raw_details = fetch(status, :details) || raw_message
    message = normalize_message(raw_message)
    agent_id = normalize_string(fetch(status, :agent_id), "unknown")
    service_type = normalize_string(fetch(status, :service_type), "unknown")

    gateway_id =
      if Keyword.get(opts, :preserve_gateway?, false) do
        normalize_string(fetch(status, :gateway_id), "unknown")
      else
        canonical_gateway_id(status, agent_id, actor)
      end

    %{
      agent_id: agent_id,
      gateway_id: gateway_id,
      partition: resolve_partition(status),
      service_type: service_type,
      service_name: normalize_string(fetch(status, :service_name), "unknown"),
      available: normalize_available(fetch(status, :available)),
      message: normalize_message_value(message),
      details: normalize_details(raw_details),
      last_observed_at: resolve_observed_at(status),
      state: "active"
    }
  end

  @doc false
  def normalize_string(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: fallback, else: trimmed
  end

  def normalize_string(_value, fallback), do: fallback

  @doc false
  def fetch(status, key) when is_map(status) do
    case Map.fetch(status, key) do
      {:ok, value} -> value
      :error -> Map.get(status, Atom.to_string(key))
    end
  end

  @doc false
  def should_track_assignment_service?(
        %PluginAssignment{} = assignment,
        %PluginPackage{} = package
      ) do
    assignment.enabled == true and package.status == :approved and
      (streaming_plugin_package?(package) or plugin_result_package?(package))
  end

  @doc false
  def build_attrs_from_assignment(
        %PluginAssignment{} = assignment,
        agent,
        %PluginPackage{} = package
      ) do
    plugin_type = assignment_plugin_type(package)
    {available, message} = assignment_initial_state(plugin_type)

    agent
    |> identity_from_agent(package.name, "plugin", assignment.agent_uid)
    # `agent.metadata` is inventory-derived and can lag an enrollment or be
    # overwritten by a same-named agent in another partition. Assignment
    # placeholders instead inherit the immutable partition that was bound by
    # the authenticated edge control session at assignment creation.
    |> Map.put(:partition, normalize_string(assignment.partition_id, "default"))
    |> Map.merge(%{
      available: available,
      message: message,
      details:
        FieldParser.encode_json(%{
          "assignment_id" => to_string(assignment.id),
          "plugin_id" => package.plugin_id,
          "package_id" => package.id,
          "plugin_type" => plugin_type,
          "package_version" => package.version
        }),
      last_observed_at: DateTime.truncate(DateTime.utc_now(), :microsecond),
      state: "active"
    })
  end

  @doc false
  def identity_from_agent(agent, service_name, service_type, agent_id) do
    %{
      agent_id: agent_id,
      gateway_id: normalize_string(agent.gateway_id, "unknown"),
      partition: resolve_partition_from_agent(agent),
      service_type: service_type,
      service_name: normalize_string(service_name, "unknown")
    }
  end

  @doc false
  def logical_plugin_identity(identity) when is_map(identity) do
    PluginStateContract.logical_identity(identity)
  end

  @doc false
  def logical_state_rank(state), do: PluginStateContract.state_rank(state)

  @doc false
  def assignment_placeholder_state?(state), do: PluginStateContract.placeholder_state?(state)

  @doc false
  def streaming_plugin_package?(%PluginPackage{} = package) do
    package.outputs == @streaming_plugin_output or
      Enum.member?(effective_capabilities(package), @streaming_plugin_capability)
  end

  @doc false
  def plugin_result_package?(%PluginPackage{} = package) do
    package.outputs == @plugin_result_output
  end

  defp resolve_partition(status) do
    normalize_string(fetch(status, :partition) || fetch(status, :partition_id), "default")
  end

  defp normalize_available(true), do: true
  defp normalize_available(false), do: false
  defp normalize_available(1), do: true
  defp normalize_available(0), do: false
  defp normalize_available(_), do: false

  defp normalize_message(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, decoded} when is_map(decoded) ->
        decoded["summary"] || decoded["message"] || decoded["status"] || slice_message(message)

      {:ok, decoded} when is_list(decoded) ->
        normalize_message(decoded) || slice_message(message)

      _ ->
        slice_message(message)
    end
  end

  defp normalize_message(message) when is_map(message) do
    summary =
      Map.get(message, "summary") ||
        Map.get(message, :summary) ||
        Map.get(message, "message") ||
        Map.get(message, :message) ||
        Map.get(message, "status") ||
        Map.get(message, :status)

    if is_binary(summary) do
      slice_message(summary)
    else
      slice_message(FieldParser.encode_json(message))
    end
  end

  defp normalize_message(message) when is_list(message) do
    message
    |> Enum.find_value(&message_summary/1)
    |> case do
      summary when is_binary(summary) -> slice_message(summary)
      _ -> slice_message(FieldParser.encode_json(message))
    end
  end

  defp normalize_message(_), do: nil

  defp message_summary(message) when is_map(message) do
    Map.get(message, "summary") ||
      Map.get(message, :summary) ||
      Map.get(message, "message") ||
      Map.get(message, :message) ||
      Map.get(message, "status") ||
      Map.get(message, :status)
  end

  defp message_summary(_message), do: nil

  defp slice_message(nil), do: nil
  defp slice_message(message) when is_binary(message), do: String.slice(message, 0, 2048)

  defp normalize_message_value(value) when is_binary(value) or is_nil(value), do: value

  defp normalize_message_value(value) do
    FieldParser.encode_json(value) || inspect(value)
  end

  defp normalize_details(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        FieldParser.encode_json(decoded)

      _ ->
        nil
    end
  end

  defp normalize_details(message) when is_map(message) or is_list(message) do
    FieldParser.encode_json(message)
  end

  defp normalize_details(_message), do: nil

  defp resolve_observed_at(status) do
    raw =
      fetch(status, :agent_timestamp) || fetch(status, :timestamp) || fetch(status, :observed_at)

    case raw do
      %DateTime{} = timestamp ->
        DateTime.truncate(timestamp, :microsecond)

      %NaiveDateTime{} = timestamp ->
        timestamp
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.truncate(:microsecond)

      raw ->
        (%DateTime{} = timestamp) = FieldParser.parse_timestamp(raw)
        DateTime.truncate(timestamp, :microsecond)
    end
  rescue
    _ -> DateTime.truncate(DateTime.utc_now(), :microsecond)
  end

  defp effective_capabilities(%PluginPackage{} = package) do
    approved = package.approved_capabilities || []

    if approved == [] do
      manifest = package.manifest || %{}
      Map.get(manifest, "capabilities") || Map.get(manifest, :capabilities) || []
    else
      approved
    end
  end

  defp assignment_plugin_type(%PluginPackage{} = package) do
    cond do
      streaming_plugin_package?(package) -> "streaming"
      plugin_result_package?(package) -> "scheduled"
      true -> "plugin"
    end
  end

  defp assignment_initial_state("streaming"), do: {true, "streaming plugin ready"}
  defp assignment_initial_state(_), do: {false, "plugin assignment pending result"}

  defp resolve_partition_from_agent(agent) do
    metadata = agent.metadata || %{}

    normalize_string(metadata["partition_id"] || metadata["partition"], "default")
  end

  defp canonical_gateway_id(status, agent_id, actor) do
    raw_gateway_id = normalize_string(fetch(status, :gateway_id), "unknown")

    if normalize_string(fetch(status, :service_type), "unknown") == "plugin" do
      agent_gateway_id(agent_id, actor) || raw_gateway_id
    else
      raw_gateway_id
    end
  end

  defp agent_gateway_id(agent_id, actor)
       when is_binary(agent_id) and agent_id not in ["", "unknown"] do
    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, agent} -> normalize_string(agent.gateway_id, nil)
      _ -> nil
    end
  end

  defp agent_gateway_id(_agent_id, _actor), do: nil
end
