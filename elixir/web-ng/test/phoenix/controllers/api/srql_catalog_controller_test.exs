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
      conn = conn |> recycle() |> get(~p"/api/srql/catalog")

      assert json_response(conn, 401) == %{"error" => "authentication_required"}
    end

    test "etag changes when the catalog content changes" do
      base = Catalog.structured()
      changed = Catalog.structured_from_entities([changed_entity() | Catalog.entities()])

      assert Catalog.etag(changed) != Catalog.etag(base)
    end
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
