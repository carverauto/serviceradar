defmodule ServiceRadar.Analytics.StarRocks.QueryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Query

  @moduletag :db_free

  test "execute submits compiled SQL and maps HTTP rows" do
    sql = "SELECT id, bytes_in FROM serviceradar.ocsf_network_activity LIMIT 1"

    http = fn request ->
      assert request.method == :post
      assert request.url =~ "/api/v1/catalogs/default_catalog/databases/serviceradar/sql"
      assert Jason.decode!(request.body) == %{"query" => sql}

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "meta" => [%{"name" => "id"}, %{"name" => "bytes_in"}],
             "data" => [["flow-alpha-0001", 1200]]
           })
       }}
    end

    assert {:ok, %Postgrex.Result{columns: columns, rows: rows, num_rows: 1}} =
             Query.execute(sql, http: http)

    assert columns == ["id", "bytes_in"]
    assert rows == [["flow-alpha-0001", 1200]]
  end

  test "execute maps Frontend NDJSON data frames" do
    body =
      """
      {"connectionId":1}
      {"meta":[{"name":"id","type":"varchar(64)"},{"name":"bytes_in","type":"bigint(20)"}]}
      {"data":["flow-alpha-0001",1200]}
      {"statistics":{"returnRows":1}}
      """

    http = fn _request -> {:ok, %{status: 200, body: body}} end

    assert {:ok, %Postgrex.Result{columns: columns, rows: rows}} =
             Query.execute("SELECT id, bytes_in FROM serviceradar.ocsf_network_activity LIMIT 1",
               http: http
             )

    assert columns == ["id", "bytes_in"]
    assert rows == [["flow-alpha-0001", 1200]]
  end

  test "catalog join SQL is an HTTP error, never a PostgreSQL fallback" do
    sql =
      "SELECT f.id FROM serviceradar.ocsf_network_activity AS f " <>
        "INNER JOIN cnpg_platform.platform.flow_process_attribution_current AS attr " <>
        "ON attr.local_ip = f.src_endpoint_ip LIMIT 1"

    http = fn request ->
      assert Jason.decode!(request.body) == %{"query" => sql}
      {:error, :connect_failed}
    end

    assert {:error, :connect_failed} = Query.execute(sql, http: http)
  end

  test "uninjected execute uses HTTP rather than a stub ACK" do
    assert {:error, reason} =
             Query.execute("SELECT 1",
               config: %{fe_http: "http://127.0.0.1:1", database: "serviceradar"}
             )

    refute reason == :starrocks_not_configured

    assert reason in [:connect_failed, :timeout] or match?({:failed_connect, _}, reason) or
             is_tuple(reason)
  end
end
