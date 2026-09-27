defmodule ServiceRadarWebNGWeb.TopologySnapshotController do
  use Phoenix.Controller, formats: [:html, :json]

  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.Topology.AtlasReader
  alias ServiceRadarWebNG.Topology.AtlasRequest
  alias ServiceRadarWebNG.Topology.GodViewSnapshot
  alias ServiceRadarWebNG.Topology.GodViewStream
  alias ServiceRadarWebNGWeb.FeatureFlags

  require Logger

  def revisions(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    if FeatureFlags.god_view_enabled?() do
      with :ok <- require_authenticated(conn),
           {:ok, conn} <- require_permission(conn, "analytics.view"),
           {:ok, level_ids} <- AtlasRequest.parse_levels(params),
           {:ok, revisions} <- AtlasReader.revisions(conn.assigns.current_scope, level_ids) do
        json(conn, revisions)
      else
        %Plug.Conn{} = conn -> conn
        {:error, reason} -> atlas_error(conn, reason)
      end
    else
      atlas_error(conn, :god_view_disabled)
    end
  end

  def show(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    if FeatureFlags.god_view_enabled?() do
      with :ok <- require_authenticated(conn),
           {:ok, conn} <- require_permission(conn, "analytics.view") do
        case GodViewStream.latest_snapshot() do
          {:ok, %{snapshot: snapshot, payload: payload}} ->
            root_meta = bitmap_meta(snapshot, :root_cause)
            affected_meta = bitmap_meta(snapshot, :affected)
            healthy_meta = bitmap_meta(snapshot, :healthy)
            unknown_meta = bitmap_meta(snapshot, :unknown)
            pipeline_stats = pipeline_stats(snapshot)

            conn
            |> put_resp_content_type("application/octet-stream")
            |> put_resp_header("cache-control", "no-store")
            |> put_resp_header("x-sr-god-view-schema", Integer.to_string(snapshot.schema_version))
            |> put_resp_header("x-sr-god-view-revision", Integer.to_string(snapshot.revision))
            |> put_resp_header(
              "x-sr-god-view-bitmap-root-bytes",
              Integer.to_string(root_meta.bytes)
            )
            |> put_resp_header(
              "x-sr-god-view-bitmap-affected-bytes",
              Integer.to_string(affected_meta.bytes)
            )
            |> put_resp_header(
              "x-sr-god-view-bitmap-healthy-bytes",
              Integer.to_string(healthy_meta.bytes)
            )
            |> put_resp_header(
              "x-sr-god-view-bitmap-unknown-bytes",
              Integer.to_string(unknown_meta.bytes)
            )
            |> put_resp_header(
              "x-sr-god-view-bitmap-root-count",
              Integer.to_string(root_meta.count)
            )
            |> put_resp_header(
              "x-sr-god-view-bitmap-affected-count",
              Integer.to_string(affected_meta.count)
            )
            |> put_resp_header(
              "x-sr-god-view-bitmap-healthy-count",
              Integer.to_string(healthy_meta.count)
            )
            |> put_resp_header(
              "x-sr-god-view-bitmap-unknown-count",
              Integer.to_string(unknown_meta.count)
            )
            |> put_resp_header(
              "x-sr-god-view-generated-at",
              DateTime.to_iso8601(snapshot.generated_at)
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-raw-links",
              Integer.to_string(Map.get(pipeline_stats, :raw_links, 0))
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-unique-pairs",
              Integer.to_string(Map.get(pipeline_stats, :unique_pairs, 0))
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-final-edges",
              Integer.to_string(Map.get(pipeline_stats, :final_edges, 0))
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-final-direct",
              Integer.to_string(Map.get(pipeline_stats, :final_direct, 0))
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-final-inferred",
              Integer.to_string(Map.get(pipeline_stats, :final_inferred, 0))
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-final-attachment",
              Integer.to_string(Map.get(pipeline_stats, :final_attachment, 0))
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-unresolved-endpoints",
              Integer.to_string(Map.get(pipeline_stats, :unresolved_endpoints, 0))
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-edge-telemetry-interface",
              Integer.to_string(Map.get(pipeline_stats, :edge_telemetry_interface, 0))
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-edge-telemetry-fallback",
              Integer.to_string(Map.get(pipeline_stats, :edge_telemetry_fallback, 0))
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-edge-unresolved-directional",
              Integer.to_string(Map.get(pipeline_stats, :edge_unresolved_directional, 0))
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-edge-class-backbone",
              Integer.to_string(Map.get(pipeline_stats, :edge_class_backbone, 0))
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-edge-class-attachment",
              Integer.to_string(Map.get(pipeline_stats, :edge_class_attachment, 0))
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-edge-class-inferred",
              Integer.to_string(Map.get(pipeline_stats, :edge_class_inferred, 0))
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-edge-class-hosted",
              Integer.to_string(Map.get(pipeline_stats, :edge_class_hosted, 0))
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-edge-class-observed",
              Integer.to_string(Map.get(pipeline_stats, :edge_class_observed, 0))
            )
            |> put_resp_header(
              "x-sr-god-view-pipeline-backbone-edge-count",
              Integer.to_string(Map.get(pipeline_stats, :backbone_edge_count, 0))
            )
            |> send_resp(200, payload)

          {:error, reason} ->
            Logger.error("God-View snapshot build failed: #{inspect(reason)}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "snapshot_build_failed"})
        end
      end
    else
      send_resp(conn, :not_found, "Not Found")
    end
  end

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) -> :ok
      _ -> conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"}) |> halt()
    end
  end

  defp require_permission(conn, permission) do
    scope = conn.assigns[:current_scope]

    case RBAC.authorize_current(scope, [permission]) do
      {:ok, current_scope} -> {:ok, assign(conn, :current_scope, current_scope)}
      {:error, _reason} -> conn |> put_status(:forbidden) |> json(%{error: "forbidden"}) |> halt()
    end
  end

  defp bitmap_meta(snapshot, key) do
    GodViewSnapshot.bitmap_metadata(snapshot, key)
  end

  defp atlas_error(conn, reason) do
    {status, body} = AtlasRequest.error_response(reason)
    conn = if status == 503, do: put_resp_header(conn, "retry-after", "1"), else: conn
    conn |> put_status(status) |> json(body)
  end

  defp pipeline_stats(snapshot) do
    snapshot
    |> Map.get(:pipeline_stats, %{})
    |> Map.take([
      :raw_links,
      :unique_pairs,
      :final_edges,
      :final_direct,
      :final_inferred,
      :final_attachment,
      :edge_class_backbone,
      :edge_class_attachment,
      :edge_class_inferred,
      :edge_class_hosted,
      :edge_class_observed,
      :backbone_edge_count,
      :unresolved_endpoints,
      :edge_telemetry_interface,
      :edge_telemetry_fallback,
      :edge_unresolved_directional
    ])
  end
end
