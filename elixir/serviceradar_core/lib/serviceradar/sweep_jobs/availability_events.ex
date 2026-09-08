defmodule ServiceRadar.SweepJobs.AvailabilityEvents do
  @moduledoc """
  Emits internal sweep logs when a device's inventory availability flips.

  Downstream EventRules promote these logs to OCSF events. A seeded
  StatefulAlertRule opens on `device.unavailable` and clears on
  `device.available`.
  """

  alias ServiceRadar.Events.InternalLogPublisher

  require Logger

  @type transition ::
          {:unavailable, map()}
          | {:available, map()}

  @spec transitions_from_rows(list()) :: [transition()]
  def transitions_from_rows(rows) when is_list(rows) do
    Enum.flat_map(rows, &row_transition/1)
  end

  def transitions_from_rows(_), do: []

  @spec emit([transition()], map()) :: :ok
  def emit([], _context), do: :ok

  def emit(transitions, context) when is_list(transitions) and is_map(context) do
    publisher = Map.get(context, :publisher, &default_publish/2)

    Enum.each(transitions, fn {kind, device} ->
      payload = payload(kind, device, context)

      case publisher.("sweep", payload) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Sweep availability event publish failed",
            device_uid: device[:uid],
            kind: kind,
            reason: inspect(reason)
          )
      end
    end)

    :ok
  end

  defp row_transition([uid, was_available, is_available, hostname, ip]) do
    cond do
      truthy?(is_available) and not truthy?(was_available) ->
        [{:available, device_info(uid, hostname, ip)}]

      not truthy?(is_available) and truthy?(was_available) ->
        [{:unavailable, device_info(uid, hostname, ip)}]

      true ->
        []
    end
  end

  defp row_transition(_), do: []

  defp device_info(uid, hostname, ip) do
    %{
      uid: to_string(uid),
      hostname: blank_to_nil(hostname),
      ip: blank_to_nil(ip)
    }
  end

  defp payload(kind, device, context) do
    event_type = event_type(kind)
    uid = device[:uid]
    label = device[:hostname] || device[:ip] || uid

    %{
      "event_type" => event_type,
      "severity" => severity(kind),
      "message" => message(kind, label),
      "device_uid" => uid,
      "attributes" => %{
        "event_type" => event_type,
        "device_uid" => uid,
        "device" => %{"uid" => uid},
        "hostname" => device[:hostname],
        "ip" => device[:ip],
        "sweep_group_id" => context[:sweep_group_id],
        "sweep_group_name" => context[:sweep_group_name],
        "agent_id" => context[:agent_id],
        "execution_id" => context[:execution_id]
      }
    }
  end

  defp event_type(:unavailable), do: "device.unavailable"
  defp event_type(:available), do: "device.available"

  defp severity(:unavailable), do: "warning"
  defp severity(:available), do: "info"

  defp message(:unavailable, label), do: "Device #{label} is unreachable from sweep checks"
  defp message(:available, label), do: "Device #{label} recovered on sweep checks"

  defp default_publish(subject, payload), do: InternalLogPublisher.publish(subject, payload)

  defp truthy?(true), do: true
  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?(value) when is_binary(value), do: String.downcase(value) in ["t", "true", "1"]
  defp truthy?(_), do: false

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: to_string(value)
end
