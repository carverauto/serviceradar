defmodule ServiceRadarWebNGWeb.Api.DeviceController do
  @moduledoc """
  Device API controller using Ash resources.
  """
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Inventory.BumblebeeDevicePosture
  alias ServiceRadar.Inventory.BumblebeeFinding
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceRiskContribution

  require Ash.Query
  require Logger

  @default_limit 100
  @max_limit 500
  @max_offset 100_000
  @bumblebee_posture_limit 8
  @bumblebee_finding_limit 25
  @risk_contribution_limit 20

  def index(conn, params) do
    case parse_index_params(params) do
      {:ok, opts} ->
        devices = ServiceRadarWebNG.Api.Access.list_devices(get_scope(conn), opts)

        json(conn, %{
          "data" => Enum.map(devices, &device_to_map/1),
          "pagination" => build_pagination(devices, opts)
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => reason})
    end
  end

  def show(conn, %{"uid" => uid}) do
    scope = get_scope(conn)

    case ServiceRadarWebNG.Api.Access.get_device(scope, uid) do
      {:ok, device} ->
        json(conn, %{"data" => device_to_map(device, scope)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "device not found"})

      {:error, {:invalid, reason}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => reason})
    end
  end

  def show(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "missing required path param: uid"})
  end

  @doc """
  Export devices in OCSF v1.7.0 Device object format.
  Supports filtering by type_id, time range, and pagination.

  Query params:
  - type_id: Filter by OCSF device type_id (integer)
  - first_seen_after: Filter devices first seen after this ISO8601 timestamp
  - last_seen_after: Filter devices last seen after this ISO8601 timestamp
  - limit: Max devices to return (default 100, max 1000)
  - offset: Pagination offset (default 0)
  """
  def ocsf_export(conn, params) do
    case parse_export_params(params) do
      {:ok, opts} ->
        devices = list_devices_for_export(conn, opts)

        json(conn, %{
          "ocsf_version" => "1.7.0",
          "class_uid" => 5001,
          "class_name" => "Device Inventory Info",
          "devices" => Enum.map(devices, &device_to_ocsf_export/1),
          "count" => length(devices),
          "pagination" => build_export_pagination(devices, opts)
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => reason})
    end
  end

  defp parse_export_params(params) when is_map(params) do
    with {:ok, limit} <- parse_export_limit(Map.get(params, "limit"), 100, 1000),
         {:ok, offset} <- parse_offset_value(Map.get(params, "offset", 0)),
         {:ok, type_id} <- parse_optional_int(Map.get(params, "type_id")),
         {:ok, first_seen_after} <- parse_optional_datetime(Map.get(params, "first_seen_after")),
         {:ok, last_seen_after} <- parse_optional_datetime(Map.get(params, "last_seen_after")) do
      {:ok,
       %{
         limit: limit,
         offset: offset,
         type_id: type_id,
         first_seen_after: first_seen_after,
         last_seen_after: last_seen_after
       }}
    end
  end

  defp parse_export_params(_), do: {:error, "invalid query params"}

  defp parse_export_limit(nil, default, _max), do: {:ok, default}
  defp parse_export_limit("", default, _max), do: {:ok, default}

  defp parse_export_limit(limit, _default, max) when is_integer(limit) and limit > 0 do
    {:ok, min(limit, max)}
  end

  defp parse_export_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {value, ""} when value > 0 -> parse_export_limit(value, default, max)
      _ -> {:error, "invalid limit"}
    end
  end

  defp parse_export_limit(_limit, _default, _max), do: {:error, "invalid limit"}

  defp parse_optional_int(nil), do: {:ok, nil}
  defp parse_optional_int(""), do: {:ok, nil}

  defp parse_optional_int(value) when is_integer(value), do: {:ok, value}

  defp parse_optional_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, "invalid integer value"}
    end
  end

  defp parse_optional_int(_), do: {:error, "invalid integer value"}

  defp parse_optional_datetime(nil), do: {:ok, nil}
  defp parse_optional_datetime(""), do: {:ok, nil}

  defp parse_optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, "invalid datetime format (use ISO8601)"}
    end
  end

  defp parse_optional_datetime(_), do: {:error, "invalid datetime value"}

  defp list_devices_for_export(conn, opts) do
    scope = get_scope(conn)

    Device
    |> Ash.Query.sort(last_seen_time: :desc)
    |> maybe_filter_type_id(opts.type_id)
    |> maybe_filter_first_seen_after(opts.first_seen_after)
    |> maybe_filter_last_seen_after(opts.last_seen_after)
    # The Device :read action requires keyset pagination, so Ash.read! returns an
    # Ash.Page.* struct (not a list) and query-level limit is ignored. Use the
    # page option for exact offset paging and unwrap .results — the list the
    # callers (Enum.map/length) expect.
    |> Ash.read!(scope: scope, page: [limit: opts.limit, offset: opts.offset])
    |> Map.fetch!(:results)
  end

  defp maybe_filter_type_id(query, nil), do: query
  defp maybe_filter_type_id(query, type_id), do: Ash.Query.filter(query, type_id == ^type_id)

  defp maybe_filter_first_seen_after(query, nil), do: query

  defp maybe_filter_first_seen_after(query, dt), do: Ash.Query.filter(query, first_seen_time >= ^dt)

  defp maybe_filter_last_seen_after(query, nil), do: query
  defp maybe_filter_last_seen_after(query, dt), do: Ash.Query.filter(query, last_seen_time >= ^dt)

  defp build_export_pagination(devices, %{limit: limit, offset: offset}) do
    next_offset = if length(devices) >= limit, do: offset + limit

    %{
      "limit" => limit,
      "offset" => offset,
      "next_offset" => next_offset
    }
  end

  defp device_to_ocsf_export(device) do
    %{
      # OCSF Core Identity
      "uid" => device.uid,
      "type_id" => device.type_id,
      "type" => device.type,
      "name" => device.name,
      "hostname" => device.hostname,
      "ip" => device.ip,
      "mac" => device.mac,
      # OCSF Extended Identity
      "uid_alt" => device.uid_alt,
      "vendor_name" => device.vendor_name,
      "model" => device.model,
      "domain" => device.domain,
      "zone" => device.zone,
      "subnet_uid" => device.subnet_uid,
      "vlan_uid" => device.vlan_uid,
      "switch_port_attachment" => device.switch_port_attachment,
      "region" => device.region,
      # OCSF Temporal
      "first_seen_time" => normalize_value(device.first_seen_time),
      "last_seen_time" => normalize_value(device.last_seen_time),
      "created_time" => normalize_value(device.created_time),
      "modified_time" => normalize_value(device.modified_time),
      # OCSF Risk and Compliance
      "risk_level_id" => device.risk_level_id,
      "risk_level" => device.risk_level,
      "risk_score" => device.risk_score,
      "is_managed" => device.is_managed,
      "is_compliant" => device.is_compliant,
      "is_trusted" => device.is_trusted,
      # OCSF Nested Objects
      "os" => device.os,
      "hw_info" => device.hw_info,
      "network_interfaces" => device.network_interfaces,
      "owner" => device.owner,
      "org" => device.org,
      "groups" => device.groups,
      "agent_list" => device.agent_list
    }
  end

  @doc """
  Sets bounded scalar facts on a device's metadata.

  Phase-1 ingress for external validation tools such as OpenText Network
  Automation. The value is written plainly so existing metadata consumers see
  it, and server-stamped provenance is recorded alongside so composite checks
  can enforce a maximum age. Caller-supplied timestamps are ignored.
  """
  def update_metadata(conn, %{"uid" => uid} = params) do
    scope = get_scope(conn)

    # The lookup and the write are handled separately on purpose. Ash returns a
    # bare Ash.Error.Invalid ("record not found") for a missing device, which is
    # indistinguishable from a rejected fact if both flow through one `else`.
    with {:ok, parsed_uid} <- parse_uid(uid),
         {:ok, facts} <- parse_facts(Map.get(params, "facts")),
         {:ok, device} <- fetch_device(parsed_uid, scope) do
      apply_facts(conn, device, facts, scope)
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

  defp fetch_device(uid, scope) do
    case Device.get_by_uid(uid, false, scope: scope) do
      {:ok, device} -> {:ok, device}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp apply_facts(conn, device, facts, scope) do
    device
    |> Ash.Changeset.for_update(:write_facts, %{facts: facts}, scope: scope)
    |> Ash.update()
    |> case do
      {:ok, updated} ->
        json(conn, %{"data" => %{"uid" => updated.uid, "facts" => rendered_facts(updated)}})

      {:error, %Ash.Error.Forbidden{}} ->
        conn
        |> put_status(:forbidden)
        |> json(%{"error" => "not authorized to write device facts"})

      {:error, error} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => Exception.message(error)})
    end
  end

  defp parse_facts(facts) when is_map(facts) and map_size(facts) > 0, do: {:ok, facts}
  defp parse_facts(facts) when is_map(facts), do: {:error, "facts must not be empty"}
  defp parse_facts(_facts), do: {:error, "facts must be an object"}

  # Only externally written facts are echoed back. Reporting the whole metadata
  # map would leak internal enrichment to a caller that only holds
  # devices.facts.write.
  defp rendered_facts(device) do
    metadata = device.metadata || %{}
    provenance = Map.get(metadata, "__fact_provenance", %{})

    Map.new(provenance, fn {key, entry} ->
      {key,
       %{
         "value" => Map.get(metadata, key),
         "source" => Map.get(entry, "source"),
         "updated_at" => Map.get(entry, "updated_at")
       }}
    end)
  end

  defp get_scope(conn) do
    conn.assigns[:current_scope]
  end

  defp parse_index_params(params) when is_map(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit"), @default_limit),
         {:ok, offset} <- parse_offset(params, limit),
         {:ok, search} <- parse_optional_string(Map.get(params, "search")),
         {:ok, status} <- parse_status(Map.get(params, "status")),
         {:ok, gateway_id} <- parse_optional_string(Map.get(params, "gateway_id")),
         {:ok, device_type} <- parse_optional_string(Map.get(params, "device_type")) do
      {:ok,
       %{
         limit: limit,
         offset: offset,
         search: search,
         status: status,
         gateway_id: gateway_id,
         device_type: device_type
       }}
    end
  end

  defp parse_index_params(_), do: {:error, "invalid query params"}

  defp parse_limit(nil, default), do: {:ok, default}
  defp parse_limit("", default), do: {:ok, default}

  defp parse_limit(limit, _default) when is_integer(limit) and limit > 0 do
    {:ok, min(limit, @max_limit)}
  end

  defp parse_limit(limit, default) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {value, ""} when value > 0 -> parse_limit(value, default)
      _ -> {:error, "invalid limit"}
    end
  end

  defp parse_limit(_limit, _default), do: {:error, "invalid limit"}

  defp parse_offset(params, limit) when is_map(params) and is_integer(limit) do
    offset = Map.get(params, "offset")
    page = Map.get(params, "page")

    cond do
      not is_nil(offset) ->
        parse_offset_value(offset)

      not is_nil(page) ->
        with {:ok, page} <- parse_page(page) do
          parse_offset_value((page - 1) * limit)
        end

      true ->
        {:ok, 0}
    end
  end

  defp parse_offset(_params, _limit), do: {:error, "invalid pagination params"}

  defp parse_offset_value(value) when is_integer(value) and value >= 0 do
    if value <= @max_offset, do: {:ok, value}, else: {:error, "offset too large"}
  end

  defp parse_offset_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {value, ""} -> parse_offset_value(value)
      _ -> {:error, "invalid offset"}
    end
  end

  defp parse_offset_value(_), do: {:error, "invalid offset"}

  defp parse_page(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, "invalid page"}
    end
  end

  defp parse_page(_), do: {:error, "invalid page"}

  defp parse_optional_string(nil), do: {:ok, nil}

  defp parse_optional_string(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.slice(0, 200)

    if value == "", do: {:ok, nil}, else: {:ok, value}
  end

  defp parse_optional_string(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp parse_optional_string(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp parse_optional_string(_), do: {:error, "invalid string param"}

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(""), do: {:ok, nil}

  defp parse_status(value) when is_binary(value) do
    value = value |> String.downcase() |> String.trim()

    case value do
      "online" -> {:ok, :online}
      "offline" -> {:ok, :offline}
      "available" -> {:ok, :online}
      "unavailable" -> {:ok, :offline}
      other -> {:error, "invalid status: #{other}"}
    end
  end

  defp parse_status(_), do: {:error, "invalid status"}

  defp parse_uid(value) do
    case ServiceRadarWebNG.Api.Access.parse_uid(value) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, {:invalid, reason}} -> {:error, reason}
    end
  end

  defp build_pagination(devices, %{limit: limit, offset: offset}) do
    next_offset = if length(devices) >= limit, do: offset + limit

    %{
      "limit" => limit,
      "offset" => offset,
      "next_offset" => next_offset
    }
  end

  defp device_to_map(device, scope \\ nil) do
    maybe_put_bumblebee_exposure(
      %{
        "uid" => device.uid,
        "type_id" => device.type_id,
        "type" => device.type,
        "name" => device.name,
        "hostname" => device.hostname,
        "ip" => device.ip,
        "mac" => device.mac,
        "uid_alt" => device.uid_alt,
        "vendor_name" => device.vendor_name,
        "model" => device.model,
        "domain" => device.domain,
        "zone" => device.zone,
        "subnet_uid" => device.subnet_uid,
        "vlan_uid" => device.vlan_uid,
        "switch_port_attachment" => device.switch_port_attachment,
        "region" => device.region,
        "first_seen_time" => normalize_value(device.first_seen_time),
        "last_seen_time" => normalize_value(device.last_seen_time),
        "first_seen" => normalize_value(device.first_seen_time),
        "last_seen" => normalize_value(device.last_seen_time),
        "created_time" => normalize_value(device.created_time),
        "modified_time" => normalize_value(device.modified_time),
        "risk_level_id" => device.risk_level_id,
        "risk_level" => device.risk_level,
        "risk_score" => device.risk_score,
        "is_managed" => device.is_managed,
        "is_compliant" => device.is_compliant,
        "is_trusted" => device.is_trusted,
        "os" => device.os,
        "hw_info" => device.hw_info,
        "network_interfaces" => device.network_interfaces,
        "owner" => device.owner,
        "org" => device.org,
        "groups" => device.groups,
        "agent_list" => device.agent_list,
        "gateway_id" => device.gateway_id,
        "agent_id" => device.agent_id,
        "discovery_sources" => device.discovery_sources,
        "is_available" => device.is_available,
        "metadata" => device.metadata
      },
      scope,
      device.uid
    )
  end

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_value(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_value(%Time{} = value), do: Time.to_iso8601(value)
  defp normalize_value(value), do: value

  defp maybe_put_bumblebee_exposure(data, nil, _device_uid), do: data

  defp maybe_put_bumblebee_exposure(data, scope, device_uid) do
    Map.put(data, "bumblebee", bumblebee_exposure_to_map(scope, device_uid))
  end

  defp bumblebee_exposure_to_map(scope, device_uid) do
    with {:ok, postures} <- read_bumblebee_postures(scope, device_uid),
         {:ok, findings} <- read_bumblebee_findings(scope, device_uid),
         {:ok, contributions} <- read_device_risk_contributions(scope, device_uid) do
      bumblebee_exposure_map(postures, findings, contributions)
    else
      {:error, reason} ->
        Logger.warning("Failed to load API Bumblebee exposure for #{device_uid}: #{inspect(reason)}")

        %{
          "summary" => bumblebee_empty_summary(),
          "postures" => [],
          "active_findings" => [],
          "risk_contribution" => nil,
          "error" => "bumblebee exposure unavailable"
        }
    end
  end

  defp read_bumblebee_postures(scope, device_uid) do
    BumblebeeDevicePosture
    |> Ash.Query.for_read(:by_device, %{device_uid: device_uid}, scope: scope)
    |> Ash.Query.limit(@bumblebee_posture_limit)
    |> Ash.read(scope: scope)
    |> normalize_ash_list_result()
  end

  defp read_bumblebee_findings(scope, device_uid) do
    BumblebeeFinding
    |> Ash.Query.for_read(:active_by_device, %{device_uid: device_uid}, scope: scope)
    |> Ash.Query.limit(@bumblebee_finding_limit)
    |> Ash.read(scope: scope)
    |> normalize_ash_list_result()
  end

  defp read_device_risk_contributions(scope, device_uid) do
    DeviceRiskContribution
    |> Ash.Query.for_read(:by_device, %{device_uid: device_uid}, scope: scope)
    |> Ash.Query.limit(@risk_contribution_limit)
    |> Ash.read(scope: scope)
    |> normalize_ash_list_result()
  end

  defp normalize_ash_list_result({:ok, %Ash.Page.Keyset{results: results}}), do: {:ok, results}
  defp normalize_ash_list_result({:ok, results}) when is_list(results), do: {:ok, results}
  defp normalize_ash_list_result({:error, reason}), do: {:error, reason}

  defp bumblebee_exposure_map(postures, findings, contributions) do
    contribution =
      Enum.find(contributions, &(resource_value(&1, :source) == "bumblebee" and resource_value(&1, :active) != false))

    %{
      "summary" => bumblebee_summary(postures, findings, contribution),
      "postures" => Enum.map(postures, &bumblebee_posture_to_map/1),
      "active_findings" => Enum.map(findings, &bumblebee_finding_to_map/1),
      "risk_contribution" => risk_contribution_to_map(contribution)
    }
  end

  defp bumblebee_summary([], findings, contribution) do
    bumblebee_empty_summary()
    |> Map.put("active_finding_count", length(findings))
    |> Map.put("finding_count", length(findings))
    |> Map.put("risk_score", resource_value(contribution, :score) || 0)
    |> Map.put("risk_level", resource_value(contribution, :risk_level))
    |> Map.put("risk_reason", resource_value(contribution, :reason))
  end

  defp bumblebee_summary(postures, findings, contribution) do
    latest = List.first(postures)
    skipped_roots = Enum.flat_map(postures, &(resource_value(&1, :skipped_roots) || []))
    active_count = max(sum_resource_int(postures, :active_finding_count), length(findings))

    %{
      "state" => resource_value(latest, :state) || "not_scanned",
      "coverage_state" => resource_value(latest, :coverage_state) || "not_scanned",
      "catalog_snapshot_ref" => resource_value(latest, :catalog_snapshot_ref),
      "catalog_version" => bumblebee_catalog_version(latest),
      "last_scan_time" => normalize_value(resource_value(latest, :last_scan_at)),
      "last_successful_scan_time" => normalize_value(resource_value(latest, :last_successful_scan_at)),
      "active_finding_count" => active_count,
      "skipped_root_count" => sum_resource_int(postures, :skipped_root_count),
      "skipped_roots" => skipped_roots,
      "posture_count" => length(postures),
      "finding_count" => length(findings),
      "risk_score" => resource_value(contribution, :score) || resource_value(latest, :risk_score) || 0,
      "risk_level" => resource_value(contribution, :risk_level),
      "risk_reason" => resource_value(contribution, :reason)
    }
  end

  defp bumblebee_empty_summary do
    %{
      "state" => "not_scanned",
      "coverage_state" => "not_scanned",
      "catalog_snapshot_ref" => nil,
      "catalog_version" => nil,
      "last_scan_time" => nil,
      "last_successful_scan_time" => nil,
      "active_finding_count" => 0,
      "skipped_root_count" => 0,
      "skipped_roots" => [],
      "posture_count" => 0,
      "finding_count" => 0,
      "risk_score" => 0,
      "risk_level" => nil,
      "risk_reason" => nil
    }
  end

  defp bumblebee_posture_to_map(posture) do
    %{
      "agent_id" => resource_value(posture, :agent_id),
      "run_id" => resource_value(posture, :run_id),
      "catalog_snapshot_ref" => resource_value(posture, :catalog_snapshot_ref),
      "catalog_version" => bumblebee_catalog_version(posture),
      "scanner_version" => resource_value(posture, :scanner_version),
      "state" => resource_value(posture, :state),
      "coverage_state" => resource_value(posture, :coverage_state),
      "attempted_root_count" => resource_value(posture, :attempted_root_count) || 0,
      "scanned_root_count" => resource_value(posture, :scanned_root_count) || 0,
      "skipped_root_count" => resource_value(posture, :skipped_root_count) || 0,
      "root_covered" => resource_value(posture, :root_covered),
      "skipped_roots" => resource_value(posture, :skipped_roots) || [],
      "risk_score" => resource_value(posture, :risk_score) || 0,
      "highest_severity" => resource_value(posture, :highest_severity),
      "active_finding_count" => resource_value(posture, :active_finding_count) || 0,
      "last_scan_time" => normalize_value(resource_value(posture, :last_scan_at)),
      "last_successful_scan_time" => normalize_value(resource_value(posture, :last_successful_scan_at)),
      "metadata" => resource_value(posture, :metadata) || %{}
    }
  end

  defp bumblebee_finding_to_map(finding) do
    %{
      "finding_id" => resource_value(finding, :finding_id),
      "agent_id" => resource_value(finding, :agent_id),
      "run_id" => resource_value(finding, :run_id),
      "catalog_id" => resource_value(finding, :catalog_id),
      "catalog_snapshot_ref" => resource_value(finding, :catalog_snapshot_ref),
      "scanner_version" => resource_value(finding, :scanner_version),
      "severity" => resource_value(finding, :severity),
      "risk_score" => resource_value(finding, :risk_score) || 0,
      "ecosystem" => resource_value(finding, :ecosystem),
      "package_name" => resource_value(finding, :package_name),
      "package_version" => resource_value(finding, :package_version),
      "evidence" => resource_value(finding, :evidence) || %{},
      "confidence" => resource_value(finding, :confidence),
      "status" => resource_value(finding, :status),
      "first_seen_at" => normalize_value(resource_value(finding, :first_seen_at)),
      "last_seen_at" => normalize_value(resource_value(finding, :last_seen_at)),
      "resolved_at" => normalize_value(resource_value(finding, :resolved_at)),
      "metadata" => resource_value(finding, :metadata) || %{}
    }
  end

  defp risk_contribution_to_map(nil), do: nil

  defp risk_contribution_to_map(contribution) do
    %{
      "source" => resource_value(contribution, :source),
      "source_ref" => resource_value(contribution, :source_ref),
      "score" => resource_value(contribution, :score),
      "risk_level_id" => resource_value(contribution, :risk_level_id),
      "risk_level" => resource_value(contribution, :risk_level),
      "reason" => resource_value(contribution, :reason),
      "active" => resource_value(contribution, :active),
      "occurred_at" => normalize_value(resource_value(contribution, :occurred_at)),
      "resolved_at" => normalize_value(resource_value(contribution, :resolved_at)),
      "metadata" => resource_value(contribution, :metadata) || %{}
    }
  end

  defp bumblebee_catalog_version(nil), do: nil

  defp bumblebee_catalog_version(posture) do
    metadata = resource_value(posture, :metadata) || %{}

    Map.get(metadata, "catalog_version") ||
      get_in(metadata, ["catalog", "version"]) ||
      get_in(metadata, ["catalog", "catalog_version"])
  end

  defp sum_resource_int(resources, key) do
    Enum.reduce(resources, 0, fn resource, acc ->
      case resource_value(resource, key) do
        value when is_integer(value) -> acc + value
        _ -> acc
      end
    end)
  end

  defp resource_value(nil, _key), do: nil

  defp resource_value(resource, key) when is_map(resource) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(resource, key) -> Map.get(resource, key)
      Map.has_key?(resource, string_key) -> Map.get(resource, string_key)
      true -> nil
    end
  end
end
