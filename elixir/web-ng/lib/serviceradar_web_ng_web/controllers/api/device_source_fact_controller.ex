defmodule ServiceRadarWebNGWeb.Api.DeviceSourceFactController do
  @moduledoc """
  Source-facts API: an external system reports, or withdraws, its own value for a
  platform inventory fact (`switch_port_attachment` or `vlan_uid`) on a device.

  A reported value is compared with every other source that reports the same
  fact, exactly like one from an integration
  (`ServiceRadar.Inventory.SourceFacts.Reports`). The caller needs `devices.view`
  to address the device and `devices.source_facts.write` to report.
  """

  use ServiceRadarWebNGWeb, :controller

  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias ServiceRadar.Inventory.Device

  require Logger

  @doc "Reports the caller's value for one fact key: `PUT /api/devices/:uid/source-facts/:fact_key`."
  def update(conn, %{"uid" => uid, "fact_key" => fact_key} = params) do
    arguments = %{fact_key: fact_key, source: params["source"], value: params["value"]}
    run(conn, uid, :report_source_fact, arguments, [:source, :value])
  end

  @doc "Withdraws the caller's value: `DELETE /api/devices/:uid/source-facts/:fact_key?source=`."
  def delete(conn, %{"uid" => uid, "fact_key" => fact_key} = params) do
    arguments = %{fact_key: fact_key, source: params["source"]}
    run(conn, uid, :retract_source_fact, arguments, [:source])
  end

  defp run(conn, uid, action, arguments, required) do
    scope = conn.assigns[:current_scope]

    with :ok <- require_present(arguments, required),
         {:ok, parsed_uid} <- parse_uid(uid),
         {:ok, device} <- fetch_device(parsed_uid, scope) do
      Device
      |> Ash.ActionInput.for_action(action, Map.put(arguments, :device_uid, device.uid))
      |> Ash.run_action(scope: scope)
      |> respond(conn)
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "device not found"})

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => reason})
    end
  end

  defp require_present(arguments, required) do
    case Enum.find(required, &(Map.get(arguments, &1) in [nil, ""])) do
      nil -> :ok
      missing -> {:error, "#{missing} is required"}
    end
  end

  defp parse_uid(value) do
    case ServiceRadarWebNG.Api.Access.parse_uid(value) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, {:invalid, reason}} -> {:error, reason}
    end
  end

  defp fetch_device(uid, scope) do
    case Device.get_by_uid(uid, false, scope: scope) do
      {:ok, device} -> {:ok, device}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp respond({:ok, result}, conn) do
    json(conn, %{
      "data" => %{
        "uid" => result.uid,
        "fact_key" => result.fact_key,
        "source" => result.source,
        "source_instance" => result.source_instance,
        "reported" => render_reported(result.fact),
        "canonical" => result.canonical,
        "disagreement_open" => result.disagreement_open
      }
    })
  end

  defp respond({:error, %Forbidden{}}, conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{"error" => "not authorized to report device source facts"})
  end

  defp respond({:error, %Invalid{errors: errors}}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => Enum.map_join(errors, "; ", &error_message/1)})
  end

  defp respond({:error, error}, conn) do
    Logger.warning("Device source fact request failed: #{error_message(error)}")

    conn
    |> put_status(:internal_server_error)
    |> json(%{"error" => "the source fact could not be recorded"})
  end

  defp render_reported(nil), do: nil

  defp render_reported(fact) do
    %{
      "value" => fact.value,
      "present" => fact.present,
      "observed_at" => fact.observed_at && DateTime.to_iso8601(fact.observed_at)
    }
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(error), do: inspect(error)
end
