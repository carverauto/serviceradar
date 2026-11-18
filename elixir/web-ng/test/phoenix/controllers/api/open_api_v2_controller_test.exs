defmodule ServiceRadarWebNGWeb.Api.OpenApiV2ControllerTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ServiceRadarWebNGWeb.Api.OpenApiV2Controller
  alias ServiceRadarWebNGWeb.AshJsonApiRouter

  @moduletag :db_free

  @committed_openapi_path Path.expand("../../../../priv/static/openapi.json", __DIR__)

  test "AshJsonApiRouter mounts the Notifications domain" do
    assert ServiceRadar.Notifications in AshJsonApiRouter.domains()
  end

  test "show/2 generates OpenAPI document containing Notifications routes" do
    conn =
      :get
      |> conn("/api/v2/open_api")
      |> OpenApiV2Controller.show(%{})

    assert conn.status == 200
    doc = Jason.decode!(conn.resp_body)
    assert doc["openapi"] =~ "3.0"
    assert Map.has_key?(doc["paths"], "/api/v2/notification-channels")
    assert Map.has_key?(doc["paths"], "/api/v2/notification-routes")
  end

  test "show/2 includes all /api/v2/declarative-checks endpoints and request/response schemas" do
    conn =
      :get
      |> conn("/api/v2/open_api")
      |> OpenApiV2Controller.show(%{})

    assert conn.status == 200
    doc = Jason.decode!(conn.resp_body)
    paths = doc["paths"]
    schemas = get_in(doc, ["components", "schemas"])

    assert doc["security"] == []
    assert Enum.any?(doc["tags"], &(&1["name"] == "declarative_checks"))

    assert get_in(paths, ["/api/v2/declarative-checks", "get", "operationId"]) ==
             "listDeclarativeChecks"

    assert get_in(paths, ["/api/v2/declarative-checks", "post", "operationId"]) ==
             "createDeclarativeCheck"

    assert get_in(paths, ["/api/v2/declarative-checks/{slug}", "get", "operationId"]) ==
             "getDeclarativeCheck"

    assert get_in(paths, ["/api/v2/declarative-checks/{slug}", "put", "operationId"]) ==
             "updateDeclarativeCheck"

    assert get_in(paths, ["/api/v2/declarative-checks/{slug}", "delete", "operationId"]) ==
             "deleteDeclarativeCheck"

    assert get_in(paths, ["/api/v2/declarative-checks/{slug}/export", "get", "operationId"]) ==
             "exportDeclarativeCheck"

    assert get_in(paths, ["/api/v2/declarative-checks/import", "post", "operationId"]) ==
             "importDeclarativeCheck"

    assert get_in(paths, ["/api/v2/declarative-checks/test-run", "post", "operationId"]) ==
             "testRunDeclarativeCheckInline"

    assert get_in(paths, ["/api/v2/declarative-checks/{slug}/test-run", "post", "operationId"]) ==
             "testRunDeclarativeCheckBySlug"

    for schema_name <- [
          "DeclarativeCheckCanonicalDocument",
          "DeclarativeCheckDetail",
          "DeclarativeCheckCreateRequest",
          "DeclarativeCheckUpdateRequest",
          "DeclarativeCheckListResponse",
          "DeclarativeCheckResponse",
          "DeclarativeCheckImportRequest",
          "DeclarativeCheckImportResult",
          "DeclarativeCheckImportResponse",
          "DeclarativeCheckInlineTestRunRequest",
          "DeclarativeCheckSavedTestRunRequest",
          "DeclarativeCheckNodeTrace",
          "DeclarativeCheckTestRunResult",
          "DeclarativeCheckTestRunResponse",
          "DeclarativeCheckValidationErrorResponse",
          "DeclarativeCheckErrorResponse"
        ] do
      assert is_map(schemas[schema_name]), "expected schema #{schema_name} in components.schemas"
    end
  end

  test "committed priv/static/openapi.json matches AshJsonApiRouter.spec/0 with zero drift" do
    expected =
      AshJsonApiRouter.spec()
      |> Jason.encode!(pretty: true)
      |> Kernel.<>("\n")

    committed = File.read!(@committed_openapi_path)
    assert committed == expected

    decoded = Jason.decode!(committed)

    for rel_path <- [
          "/declarative-checks",
          "/declarative-checks/{slug}",
          "/declarative-checks/{slug}/export",
          "/declarative-checks/import",
          "/declarative-checks/test-run",
          "/declarative-checks/{slug}/test-run"
        ] do
      assert Map.has_key?(decoded["paths"], rel_path),
             "expected #{rel_path} in priv/static/openapi.json"
    end
  end
end
