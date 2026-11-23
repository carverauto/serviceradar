defmodule ServiceRadarWebNGWeb.Plugs.ControlPlaneSettingsBackup do
  @moduledoc """
  Private control-plane endpoints for configuring the singleton settings backup
  destination and triggering on-demand settings exports on port 4001.

  Authenticated upstream by `ControlPlaneRuntimeAuth` (`:account` bearer token).
  """
  @behaviour Plug

  import Plug.Conn

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Jobs.SettingsBackupDestination
  alias ServiceRadar.JSONDocument
  alias ServiceRadar.Oban.Router, as: ObanRouter
  alias ServiceRadarWebNGWeb.ControlPlaneJSON

  @destination_body_limit 65_536
  @export_body_limit 16_384
  @allowed_reasons ~w(scheduled pre_resize manual)
  @allowed_destination_keys ~w(
    bucket
    endpoint
    region
    prefix
    access_key_id
    secret_access_key
    enabled
    schedule_cron
    provider
  )
  @allowed_export_keys ~w(reason idempotency_key)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case {conn.method, Enum.map(conn.path_info, &URI.decode/1)} do
      {"GET", ["v1", "settings-backup", "destination"]} -> get_destination(conn)
      {"PUT", ["v1", "settings-backup", "destination"]} -> put_destination(conn)
      {"POST", ["v1", "settings-backup", "export"]} -> post_export(conn)
      {_, ["v1", "settings-backup" | _]} -> respond(conn, 404, %{status: "not_found"})
      _ -> conn
    end
  end

  defp get_destination(conn) do
    case destination_module().get_singleton(actor: actor()) do
      {:ok, %{} = dest} ->
        respond(conn, 200, %{data: serialize_destination(dest)})

      {:ok, nil} ->
        respond(conn, 404, %{status: "not_found"})

      {:error, reason} ->
        if not_found_error?(reason) do
          respond(conn, 404, %{status: "not_found"})
        else
          respond(conn, 503, %{status: "storage_unavailable"})
        end
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      respond(conn, 503, %{status: "storage_unavailable"})
  end

  defp put_destination(conn) do
    case ControlPlaneJSON.read(conn, @destination_body_limit) do
      {:ok, document, conn} ->
        persist_destination(conn, document)

      {:error, status, reason, conn} ->
        respond(conn, status, %{status: reason})
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      respond(conn, 503, %{status: "storage_unavailable"})
  end

  defp persist_destination(conn, document) when is_map(document) do
    unknown_keys = Map.keys(document) -- @allowed_destination_keys

    if unknown_keys == [] do
      attrs = build_destination_attrs(document)

      case destination_module().upsert_destination(attrs, actor: actor()) do
        {:ok, :created, dest} ->
          respond(conn, 201, %{data: serialize_destination(dest)})

        {:ok, :updated, dest} ->
          respond(conn, 200, %{data: serialize_destination(dest)})

        {:error, %Invalid{} = err} ->
          respond(conn, 422, %{status: "validation_error", errors: format_ash_errors(err)})

        {:error, _reason} ->
          respond(conn, 503, %{status: "storage_unavailable"})
      end
    else
      respond(conn, 400, %{status: "invalid_request"})
    end
  end

  defp post_export(conn) do
    with {:ok, document, conn} <- read_optional_json_object(conn, @export_body_limit),
         {:ok, params} <- validate_export_params(document) do
      handle_enqueue_export(conn, params)
    else
      {:error, status, reason, conn} ->
        respond(conn, status, %{status: reason})

      {:error, :invalid_request} ->
        respond(conn, 400, %{status: "invalid_request"})
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      respond(conn, 503, %{status: "storage_unavailable"})
  end

  defp handle_enqueue_export(conn, params) do
    case destination_module().get_singleton(actor: actor()) do
      {:ok, %{} = dest} ->
        enqueue_for_destination(conn, dest, params)

      {:ok, nil} ->
        respond(conn, 409, %{status: "destination_not_configured"})

      {:error, reason} ->
        if not_found_error?(reason) do
          respond(conn, 409, %{status: "destination_not_configured"})
        else
          respond(conn, 503, %{status: "storage_unavailable"})
        end
    end
  end

  defp enqueue_for_destination(conn, dest, params) do
    cond do
      dest.enabled != true ->
        respond(conn, 409, %{status: "destination_disabled"})

      Map.get(dest, :credentials_configured) != true ->
        respond(conn, 409, %{status: "credentials_not_configured"})

      true ->
        case enqueuer_module().enqueue_export(dest, params) do
          {:ok, job} ->
            respond(conn, 202, %{
              data: %{
                status: "queued",
                job_id: job.id,
                requested_at: DateTime.to_iso8601(DateTime.utc_now())
              }
            })

          {:error, _reason} ->
            respond(conn, 503, %{status: "queue_unavailable"})
        end
    end
  end

  @doc false
  def enqueue_export(dest, params) do
    action_arguments =
      maybe_put(%{"manual" => true, "reason" => params.reason}, "idempotency_key", params.idempotency_key)

    dest
    |> AshOban.build_trigger(:export, action_arguments: action_arguments)
    |> ObanRouter.insert()
  end

  defp read_optional_json_object(conn, limit) do
    case read_body(conn, length: limit, read_length: limit, read_timeout: 5_000) do
      {:ok, "", conn} ->
        {:ok, %{}, conn}

      {:ok, body, conn} when byte_size(body) <= limit ->
        decode_nonempty_json_object(conn, body, limit)

      {:more, _body, conn} ->
        {:error, 413, :request_too_large, conn}

      {:ok, _body, conn} ->
        {:error, 413, :request_too_large, conn}

      {:error, _} ->
        {:error, 400, :invalid_request, conn}
    end
  end

  defp decode_nonempty_json_object(conn, body, limit) do
    if json_content_type?(conn) do
      case JSONDocument.decode_object(body, limit) do
        {:ok, document} -> {:ok, document, conn}
        {:error, :invalid_request} -> {:error, 400, :invalid_request, conn}
      end
    else
      {:error, 415, :unsupported_media_type, conn}
    end
  end

  defp json_content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [content_type] ->
        content_type
        |> String.split(";", parts: 2)
        |> hd()
        |> String.trim()
        |> String.downcase() == "application/json"

      _ ->
        false
    end
  end

  defp validate_export_params(document) when is_map(document) do
    unknown_keys = Map.keys(document) -- @allowed_export_keys
    reason = Map.get(document, "reason", "manual")
    idempotency_key = Map.get(document, "idempotency_key")

    cond do
      unknown_keys != [] ->
        {:error, :invalid_request}

      not (is_binary(reason) and reason in @allowed_reasons) ->
        {:error, :invalid_request}

      not valid_optional_idempotency_key?(idempotency_key) ->
        {:error, :invalid_request}

      true ->
        {:ok, %{reason: reason, idempotency_key: idempotency_key}}
    end
  end

  defp valid_optional_idempotency_key?(nil), do: true

  defp valid_optional_idempotency_key?(key) when is_binary(key) do
    trimmed = String.trim(key)
    trimmed != "" and byte_size(trimmed) <= 128
  end

  defp valid_optional_idempotency_key?(_), do: false

  defp build_destination_attrs(document) do
    Enum.reduce(@allowed_destination_keys, %{}, fn key, acc ->
      case Map.fetch(document, key) do
        {:ok, val} -> Map.put(acc, String.to_existing_atom(key), val)
        :error -> acc
      end
    end)
  end

  defp serialize_destination(dest) do
    %{
      id: dest.id,
      provider: dest.provider,
      endpoint: dest.endpoint,
      bucket: dest.bucket,
      region: dest.region,
      prefix: dest.prefix,
      enabled: dest.enabled,
      schedule_cron: dest.schedule_cron,
      credentials_configured: Map.get(dest, :credentials_configured) == true,
      next_run_at: format_datetime(dest.next_run_at),
      last_exported_at: format_datetime(dest.last_exported_at),
      last_export_status: dest.last_export_status,
      last_export_error: dest.last_export_error,
      last_export_object_key: dest.last_export_object_key,
      last_export_etag: dest.last_export_etag,
      last_export_sha256: dest.last_export_sha256,
      updated_at: format_datetime(dest.updated_at)
    }
  end

  defp format_ash_errors(%Invalid{errors: errors}) do
    Enum.map(errors, fn err ->
      %{
        field: err |> Map.get(:field) |> maybe_to_string(),
        message: Exception.message(err)
      }
    end)
  end

  defp not_found_error?(%Ash.Error.Query.NotFound{}), do: true

  defp not_found_error?(%Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &not_found_error?/1)
  end

  defp not_found_error?(:not_found), do: true
  defp not_found_error?(_), do: false

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(val), do: to_string(val)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_datetime(val), do: val

  defp actor, do: SystemActor.system(:settings_backup_control)

  defp destination_module do
    Application.get_env(
      :serviceradar_web_ng,
      :settings_backup_destination_module,
      SettingsBackupDestination
    )
  end

  defp enqueuer_module do
    Application.get_env(
      :serviceradar_web_ng,
      :settings_backup_enqueuer_module,
      __MODULE__
    )
  end

  defp respond(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
