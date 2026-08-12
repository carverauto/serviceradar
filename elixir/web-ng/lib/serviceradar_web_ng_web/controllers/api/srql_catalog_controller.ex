defmodule ServiceRadarWebNGWeb.Api.SrqlCatalogController do
  @moduledoc """
  Serves the browser-facing SRQL catalog used by compact editors.

  The `ETag` response header is the HTTP validator and is quoted per the HTTP
  header grammar. The JSON body's `version` field is the same digest without
  quotes so clients can display or compare it as data; wrap it in quotes before
  sending it as an `If-None-Match` value.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  require Logger

  @cache_control "private, max-age=300, must-revalidate"

  def show(conn, _params) do
    catalog = catalog_for(conn)
    etag = Catalog.etag(catalog)

    conn =
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header("cache-control", @cache_control)

    if fresh?(conn, etag) do
      send_resp(conn, :not_modified, "")
    else
      json(conn, catalog)
    end
  end

  # Composite fields are the one runtime-varying part of the catalog: slugs and
  # verdicts are operator-authored, so they cannot live in the static list. The
  # version is a content hash of the whole payload, so adding or renaming a
  # check invalidates the ETag on its own.
  #
  # A failure here degrades to the static catalog rather than failing the
  # request: losing composite completions is a much smaller problem than an
  # editor that cannot load its catalog at all.
  defp catalog_for(conn) do
    case composite_checks(conn) do
      [] ->
        Catalog.structured()

      checks ->
        Catalog.entities()
        |> Catalog.with_composite_checks(checks)
        |> Catalog.structured_from_entities()
    end
  end

  defp composite_checks(conn) do
    scope = conn.assigns[:current_scope]

    case CompositeCheck.list_enabled(scope: scope) do
      {:ok, checks} -> Enum.map(checks, &check_with_verdicts(&1, scope))
      {:error, _reason} -> []
    end
  rescue
    exception ->
      Logger.warning("SRQL catalog omitted composite fields",
        reason: Exception.message(exception)
      )

      []
  end

  defp check_with_verdicts(check, scope) do
    verdicts =
      case CompositeCheckRule.list_by_check(check.id, scope: scope) do
        {:ok, rules} -> rules |> Enum.map(& &1.verdict) |> Enum.uniq()
        {:error, _reason} -> []
      end

    %{slug: check.slug, name: check.name, verdicts: verdicts}
  end

  defp fresh?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 in [etag, "W/" <> etag]))
  end
end
