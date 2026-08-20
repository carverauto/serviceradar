defmodule ServiceRadarWebNGWeb.Api.ValidationRunController do
  @moduledoc """
  REST API for NCO composite-check validation runs.

  * `POST /api/v1/validation-runs` — resolve IP+partition, start a run
  * `GET  /api/v1/validation-runs/:id` — poll status
  * `GET  /api/v1/validation-runs/:id/results` — per-device verdicts
  """
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.Validation.Orchestrator
  alias ServiceRadar.CompositeChecks.ValidationRun
  alias ServiceRadarWebNG.RBAC

  def create(conn, params) do
    scope = conn.assigns[:current_scope]

    case require_permission(scope, "validation_runs.execute") do
      :ok ->
        params = Map.put(params, "requested_by", requested_by(scope))

        case Orchestrator.start(params, actor: SystemActor.system(:validation_run_api)) do
          {:ok, run} ->
            conn
            |> put_status(:accepted)
            |> json(%{
              "id" => run.id,
              "status" => to_string(run.status),
              "check" => run.check_slug,
              "devices" => Enum.map(run.devices, &device_preview/1)
            })

          {:error, reason} ->
            render_error(conn, reason)
        end

      {:error, :forbidden} ->
        render_error(conn, :forbidden)
    end
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns[:current_scope]

    with :ok <- require_permission(scope, "validation_runs.read"),
         {:ok, run} <- fetch_run(id) do
      json(conn, %{"data" => run_to_map(run)})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def results(conn, %{"id" => id}) do
    scope = conn.assigns[:current_scope]

    with :ok <- require_permission(scope, "validation_runs.read"),
         {:ok, run} <- fetch_run(id) do
      json(conn, %{"data" => Enum.map(run.devices, &device_result/1)})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp fetch_run(id) do
    case ValidationRun.get_by_id(id, actor: SystemActor.system(:validation_run_api)) do
      {:ok, run} -> {:ok, run}
      {:error, _} -> {:error, :run_not_found}
    end
  end

  defp require_permission(scope, permission) do
    if RBAC.can?(scope, permission) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp requested_by(%{user: %{email: email}}) when is_binary(email), do: email
  defp requested_by(%{user: %{id: id}}) when not is_nil(id), do: to_string(id)
  defp requested_by(_), do: nil

  defp device_preview(device) do
    %{
      "ip" => device.ip,
      "partition" => device.partition,
      "uid" => device.device_uid
    }
  end

  defp run_to_map(run) do
    %{
      "id" => run.id,
      "status" => to_string(run.status),
      "check" => run.check_slug,
      "deadline_at" => run.deadline_at && DateTime.to_iso8601(run.deadline_at),
      "error" => run.error,
      "devices" => Enum.map(run.devices || [], &device_result/1)
    }
  end

  defp device_result(device) do
    %{
      "ip" => device.ip,
      "partition" => device.partition,
      "uid" => device.device_uid,
      "coverage" => device.coverage,
      "verdict" => device.verdict,
      "status" => device.verdict_status && to_string(device.verdict_status),
      "inputs" => device.inputs,
      "evaluated_at" => device.evaluated_at && DateTime.to_iso8601(device.evaluated_at),
      "error" => device.error
    }
  end

  defp render_error(conn, :forbidden) do
    conn
    |> put_status(:forbidden)
    |> json(%{"error" => "forbidden", "message" => "missing validation_runs.execute or validation_runs.read"})
  end

  defp render_error(conn, :run_not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{"error" => "not_found", "message" => "validation run not found"})
  end

  defp render_error(conn, :check_not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{"error" => "check_not_found", "message" => "composite check not found"})
  end

  defp render_error(conn, :check_not_enabled) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "check_not_enabled", "message" => "composite check is not enabled"})
  end

  defp render_error(conn, :check_required) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "check_required", "message" => "check slug is required"})
  end

  defp render_error(conn, :empty_devices) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "empty_devices", "message" => "at least one device ip is required"})
  end

  defp render_error(conn, :too_many_devices) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "too_many_devices", "message" => "at most 128 devices per run"})
  end

  defp render_error(conn, :invalid_ip) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "invalid_ip", "message" => "ip is not a valid address"})
  end

  defp render_error(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{"error" => "device_not_found", "message" => "no live device for that ip and partition"})
  end

  defp render_error(conn, {:ambiguous, uids}) do
    conn
    |> put_status(:conflict)
    |> json(%{"error" => "ambiguous", "uids" => uids})
  end

  defp render_error(conn, {:mac_ip_conflict, ip_uid, mac_uid}) do
    conn
    |> put_status(:conflict)
    |> json(%{"error" => "mac_ip_conflict", "ip_uid" => ip_uid, "mac_uid" => mac_uid})
  end

  defp render_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => "invalid_request", "message" => inspect(reason)})
  end
end
