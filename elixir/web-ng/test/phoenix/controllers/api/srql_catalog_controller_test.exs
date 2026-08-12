defmodule ServiceRadarWebNGWeb.Api.SrqlCatalogControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadarWebNGWeb.SRQL.Catalog

  setup %{conn: conn} do
    user = ServiceRadarWebNG.AshTestHelpers.user_fixture()
    %{conn: log_in_api_user(conn, user)}
  end

  describe "GET /api/srql/catalog" do
    test "returns structured catalog with cache headers", %{conn: conn} do
      conn = get(conn, ~p"/api/srql/catalog")
      response = json_response(conn, 200)

      assert get_resp_header(conn, "etag") == [Catalog.etag()]
      assert get_resp_header(conn, "cache-control") == ["private, max-age=300, must-revalidate"]
      assert is_map(response["entities"])
      assert is_map(response["entities"]["devices"])
      assert "hostname" in response["entities"]["devices"]["fields"]["filter"]
      device_stats_fields = response["entities"]["devices"]["fields"]["stats"]
      assert "tags.<key>" in device_stats_fields
      assert "metadata.<key>" in device_stats_fields
      addon_fleet_fields = response["entities"]["addon_fleet"]["fields"]
      assert "category" in addon_fleet_fields["filter"]
      assert "reason_code" in addon_fleet_fields["filter"]
      assert "evidence_age_seconds" in addon_fleet_fields["numeric"]
      attributed_flow_fields = response["entities"]["attributed_flows"]["fields"]
      assert "src_endpoint_ip" in attributed_flow_fields["filter"]
      assert "dst_endpoint_ip" in attributed_flow_fields["filter"]
      assert "src_endpoint_port" in attributed_flow_fields["filter"]
      assert "dst_endpoint_port" in attributed_flow_fields["filter"]
      assert "protocol_num" in attributed_flow_fields["filter"]
      assert "src_endpoint_port" in attributed_flow_fields["numeric"]
      assert "dst_endpoint_port" in attributed_flow_fields["numeric"]
      assert "protocol_num" in attributed_flow_fields["numeric"]
      refute "in:" in response["control_tokens"]
      assert "time:" in response["control_tokens"]
      assert ":" in response["operators"]
      assert response["version"] == String.trim(Catalog.etag(), ~s("))
    end

    test "exposes canonical log severity fields so Monaco stops flagging them", %{conn: conn} do
      conn = get(conn, ~p"/api/srql/catalog")
      response = json_response(conn, 200)

      log_fields = response["entities"]["logs"]["fields"]

      # Monaco flags any field token not present in the flattened field set for
      # the entity; the schema exposes both columns but the curated catalog
      # previously omitted them, producing a red squiggle under `severity_text`.
      assert "severity_text" in log_fields["filter"]
      assert "severity_number" in log_fields["filter"]
      # `severity_number` is the canonical numeric OTel severity, so it must also
      # advertise as numeric for range/comparison completions.
      assert "severity_number" in log_fields["numeric"]
    end

    test "exposes curated known values so editors can suggest enum syntax", %{conn: conn} do
      conn = get(conn, ~p"/api/srql/catalog")
      response = json_response(conn, 200)

      device_enums = response["entities"]["devices"]["enums"]
      # The headline case: users kept guessing `discovery_sources:%awx%`; the
      # editor must be able to offer the real values behind `discovery_sources`.
      assert "awx" in device_enums["discovery_sources"]
      assert "armis" in device_enums["discovery_sources"]

      # Derived AWX/ansible-capable predicate is a first-class boolean filter and
      # advertises its two truth values so the editor can complete `awx_managed:`.
      device_fields = response["entities"]["devices"]["fields"]
      assert "awx_managed" in device_fields["filter"]
      assert "awx_managed" in device_fields["boolean"]
      assert device_enums["awx_managed"] == ["true", "false"]

      log_enums = response["entities"]["logs"]["enums"]
      assert "ERROR" in log_enums["severity_text"]
      # Declared severity order is preserved (not alphabetized).
      assert log_enums["severity_text"] == ["FATAL", "ERROR", "WARN", "INFO", "DEBUG"]

      # Entities without curated values still advertise an (empty) enum map so
      # clients can rely on the key existing.
      assert response["entities"]["agents"]["enums"] == %{}
    end

    test "returns 304 for a matching If-None-Match", %{conn: conn} do
      etag = Catalog.etag()

      conn =
        conn
        |> put_req_header("if-none-match", etag)
        |> get(~p"/api/srql/catalog")

      assert response(conn, 304) == ""
      assert get_resp_header(conn, "etag") == [etag]
      assert get_resp_header(conn, "cache-control") == ["private, max-age=300, must-revalidate"]
    end

    test "rejects unauthenticated requests", %{conn: conn} do
      conn = conn |> delete_req_header("authorization") |> get(~p"/api/srql/catalog")

      assert json_response(conn, 401) == %{"error" => "authentication_required"}
    end

    test "etag changes when the catalog content changes" do
      base = Catalog.structured()
      changed = Catalog.structured_from_entities([changed_entity() | Catalog.entities()])

      assert Catalog.etag(changed) != Catalog.etag(base)
    end

    test "registers the composite_results entity", %{conn: conn} do
      response =
        conn
        |> get(~p"/api/srql/catalog")
        |> json_response(200)

      fields = response["entities"]["composite_results"]["fields"]

      assert "check" in fields["filter"]
      assert "verdict" in fields["filter"]
      assert "status" in fields["filter"]
    end

    test "offers an enabled check as a device field with its verdicts", %{conn: conn} do
      check = enabled_composite_check()

      response =
        conn
        |> get(~p"/api/srql/catalog")
        |> json_response(200)

      device_fields = response["entities"]["devices"]["fields"]["filter"]

      assert "composite.#{check.slug}" in device_fields
      assert "composite.#{check.slug}.status" in device_fields
    end
  end

  defp enabled_composite_check do
    alias ServiceRadar.Actors.SystemActor
    alias ServiceRadar.CompositeChecks.CompositeCheck
    alias ServiceRadar.CompositeChecks.CompositeCheckRule

    actor = SystemActor.system(:srql_catalog_test)

    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Catalog Check #{System.unique_integer([:positive])}",
          scope_query: "in:devices"
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, _rule} =
      CompositeCheckRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          check_id: check.id,
          position: 0,
          match: %{"a" => "available"},
          verdict: "isolated_verified",
          verdict_label: "Isolated verified",
          status: :healthy
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, enabled} =
      check
      |> Ash.Changeset.for_update(:enable, %{acknowledge_coverage_gap: true}, actor: actor)
      |> Ash.update()

    enabled
  end

  defp changed_entity do
    %{
      id: "test_entity",
      label: "Test Entity",
      route: nil,
      default_time: "",
      default_sort_field: "inserted_at",
      default_sort_dir: "desc",
      default_filter_field: "name",
      filter_fields: ["name"],
      downsample: false
    }
  end
end
