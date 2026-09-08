defmodule ServiceRadarWebNGWeb.Api.SourceInventoryControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadarWebNG.Accounts.Scope

  defmodule ReaderStub do
    @moduledoc false
    def list(params) do
      send(self(), {:source_inventory_params, params})
      Process.get(:source_inventory_result, {:error, :source_inventory_unavailable})
    end
  end

  setup %{conn: conn} do
    previous = Application.get_env(:serviceradar_web_ng, :source_inventory_reader)
    Application.put_env(:serviceradar_web_ng, :source_inventory_reader, ReaderStub)

    on_exit(fn ->
      Process.delete(:source_inventory_result)

      if is_nil(previous) do
        Application.delete_env(:serviceradar_web_ng, :source_inventory_reader)
      else
        Application.put_env(:serviceradar_web_ng, :source_inventory_reader, previous)
      end
    end)

    user = ServiceRadarWebNG.AccountsFixtures.user_fixture(%{role: :viewer})
    %{conn: log_in_api_user(conn, user), user: user}
  end

  test "requires bearer or API-key authentication", %{conn: conn} do
    response =
      conn
      |> delete_req_header("authorization")
      |> get(~p"/api/v1/source-inventory?source=example-inventory&instance=acme-prod")
      |> json_response(401)

    assert response["error"] == "unauthorized"
    refute_received {:source_inventory_params, _params}
  end

  test "requires devices.view before invoking the reader", %{conn: conn, user: user} do
    forbidden_scope = Scope.for_user(user, permissions: MapSet.new())

    response =
      conn
      |> assign(:current_scope, forbidden_scope)
      |> ServiceRadarWebNGWeb.Api.SourceInventoryController.index(%{"instance" => "acme-prod"})
      |> json_response(403)

    assert response["error"] == "forbidden"
    refute_received {:source_inventory_params, _params}
  end

  test "returns a bounded collection response to an authorized bearer", %{conn: conn} do
    Process.put(:source_inventory_result, {:ok, response_fixture()})

    response =
      conn
      |> get(~p"/api/v1/source-inventory?source=example-inventory&instance=acme-prod&limit=100")
      |> json_response(200)

    assert_received {:source_inventory_params,
                     %{
                       "source" => "example-inventory",
                       "instance" => "acme-prod",
                       "limit" => "100"
                     }}

    assert response["schema_version"] == "serviceradar.source_inventory.v1"
    assert response["collection"]["complete"] == true
    assert response["rows"] == []
  end

  test "maps collection changes and unsafe queries to stable errors", %{conn: conn} do
    Process.put(:source_inventory_result, {:error, :source_collection_changed})

    changed =
      conn
      |> get(~p"/api/v1/source-inventory?source=example-inventory&instance=acme-prod")
      |> json_response(409)

    assert changed["error"] == "source_collection_changed"

    Process.put(:source_inventory_result, {:error, {:invalid_query, :unknown_query_parameter}})

    invalid =
      build_conn()
      |> log_in_api_user(ServiceRadarWebNG.AccountsFixtures.user_fixture(%{role: :viewer}))
      |> get(~p"/api/v1/source-inventory?source=example-inventory&instance=acme-prod&sql=select")
      |> json_response(400)

    assert invalid == %{
             "error" => "unknown_query_parameter",
             "message" => "Invalid source inventory query"
           }
  end

  test "does not expose unexpected reader errors", %{conn: conn} do
    Process.put(:source_inventory_result, {:error, {:database, "secret internal detail"}})

    response =
      conn
      |> get(~p"/api/v1/source-inventory?source=example-inventory&instance=acme-prod")
      |> json_response(500)

    assert response == %{
             "error" => "source_inventory_unavailable",
             "message" => "Source inventory is temporarily unavailable"
           }

    refute inspect(response) =~ "secret internal detail"
  end

  defp response_fixture do
    %{
      "api_version" => "v1",
      "schema_version" => "serviceradar.source_inventory.v1",
      "source" => "example-inventory",
      "source_instance" => "acme-prod",
      "partition" => "default",
      "collection" => %{
        "id" => "collection-1",
        "complete" => true,
        "observed_at" => "2026-07-13T12:00:00Z",
        "completed_at" => "2026-07-13T12:00:01Z",
        "expected_present_count" => 0
      },
      "rows" => [],
      "pagination" => %{"limit" => 100, "has_more" => false, "next_cursor" => nil}
    }
  end
end
