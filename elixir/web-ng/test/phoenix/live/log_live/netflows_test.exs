defmodule ServiceRadarWebNGWeb.LogLive.NetflowsTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Integrations.MapboxSettings
  alias ServiceRadar.Observability.NetflowLocalCidr
  alias ServiceRadarWebNG.AccountsFixtures

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})

    user =
      Ash.update!(user, %{timezone: "America/Chicago"},
        action: :update_timezone_preference,
        actor: user
      )

    conn = log_in_user(conn, user)

    Application.put_env(
      :serviceradar_web_ng,
      :srql_module,
      ServiceRadarWebNG.TestSupport.SRQLStub
    )

    on_exit(fn ->
      Application.delete_env(:serviceradar_web_ng, :srql_module)
    end)

    %{conn: conn}
  end

  test "reset control restores the first-visit netflows query", %{conn: conn} do
    filtered =
      "in:flows time:[2026-08-28T17:38:00.000000Z,2026-08-28T17:41:59.999999Z] sort:time:desc"

    {:ok, lv, html} = live(conn, ~p"/observability/netflows?#{%{q: filtered}}")
    assert html =~ "time:[2026-08-28T17:38:00.000000Z,2026-08-28T17:41:59.999999Z]"

    lv
    |> element(~s(button[aria-label="Reset SRQL filters"]))
    |> render_click()

    path = assert_patch(lv)
    params = path |> URI.parse() |> Map.get(:query) |> Kernel.||("") |> URI.decode_query()

    assert params["q"] == "in:flows time:last_1h sort:time:desc"
    refute params["q"] =~ "time:["
    refute Map.has_key?(params, "nf")
    refute Map.has_key?(params, "cursor")
    refute Map.has_key?(params, "page")

    html = render(lv)
    assert html =~ "time:last_1h"
    refute html =~ "time:[2026-08-28T17:38:00.000000Z,2026-08-28T17:41:59.999999Z]"
  end

  test "/flows redirects to the canonical NetFlow page with retained query bytes", %{conn: conn} do
    q = "in:flows time:last_24h"

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/flows?#{%{q: q, limit: 50}}")
    assert String.starts_with?(to, "/observability/netflows?")
    assert URI.decode_query(URI.parse(to).query || "") == %{"q" => q, "limit" => "50"}

    {:ok, _lv, html} = live(conn, to)
    # Overview panels of the netflows tab.
    assert html =~ "Avg PPS"
    assert html =~ "Total Packets"
  end

  test "/observability netflows summary rates use the selected query window", %{conn: conn} do
    Application.put_env(
      :serviceradar_web_ng,
      :srql_module,
      ServiceRadarWebNGWeb.LogLive.NetflowsTest.RecordingSRQLStub
    )

    test_pid = self()
    :persistent_term.put({__MODULE__, :test_pid}, test_pid)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :test_pid})
    end)

    q = "in:flows time:last_24h"

    {:ok, _lv, html} = live(conn, ~p"/observability/netflows?#{%{q: q, limit: 50}}")

    assert html =~ "Avg Bandwidth"
    assert html =~ "1.0 Kbps"
    assert html =~ "Avg PPS"
    assert html =~ "1.0 pps"

    queries = collect_srql_queries([])

    refute Enum.any?(queries, fn query ->
             String.contains?(query, ~S|stats:"min(time) as first_time, max(time) as last_time"|)
           end)
  end

  test "/flows keeps canonical path when patching state", %{conn: conn} do
    Application.put_env(
      :serviceradar_web_ng,
      :srql_module,
      ServiceRadarWebNGWeb.LogLive.NetflowsTest.RecordingSRQLStub
    )

    q = "in:flows time:last_24h"

    assert {:error, {:redirect, %{to: _to}}} = live(conn, ~p"/flows?#{%{q: q, limit: 50}}")

    {:ok, lv, _html} =
      live(conn, ~p"/observability/netflows?#{%{q: q, limit: 50, open_flow: "1"}}")

    lv
    |> element(~s(button[phx-click="netflow_modal_filter"][phx-value-field="src_ip"]))
    |> render_click()

    path = assert_patch(lv)
    assert String.starts_with?(path, "/observability/netflows?")
  end

  test "/observability netflows open_flow=1 opens flow details and preserves explicit time window",
       %{conn: conn} do
    Application.put_env(
      :serviceradar_web_ng,
      :srql_module,
      ServiceRadarWebNGWeb.LogLive.NetflowsTest.RecordingSRQLStub
    )

    test_pid = self()
    :persistent_term.put({__MODULE__, :test_pid}, test_pid)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :test_pid})
    end)

    q =
      ~s(in:flows time:last_24h src_endpoint_ip:192.168.1.134 dst_endpoint_ip:13.217.9.183 src_endpoint_port:57196 dst_endpoint_port:443 protocol_num:6 sort:time:desc limit:1)

    {:ok, _lv, html} =
      live(conn, ~p"/observability/netflows?#{%{q: q, limit: 50, open_flow: "1"}}")

    assert html =~ "Flow details"
    # dst port 443 resolves to the HTTPS service label.
    assert html =~ "HTTPS"
    assert html =~ "direction:"
    assert html =~ "bidirectional"
    assert html =~ "SourceNet Inc"
    assert html =~ "DestNet LLC"

    queries = collect_srql_queries([])
    assert Enum.any?(queries, &String.contains?(&1, "time:last_24h"))

    # The timeseries query must bucket within the explicit 24h window
    # (bucket size itself is an implementation detail of the window).
    assert Enum.any?(queries, fn query ->
             String.contains?(query, "bucket:") and String.contains?(query, "time:last_24h")
           end)
  end

  @tag :web_ng_shared_fixture_db
  test "Flow Explorer rows and modal expose the same canonical instant in the saved zone",
       %{conn: conn} do
    Application.put_env(
      :serviceradar_web_ng,
      :srql_module,
      ServiceRadarWebNGWeb.LogLive.NetflowsTest.RecordingSRQLStub
    )

    q = "in:flows time:last_24h sort:time:desc"

    {:ok, lv, _html} =
      live(
        conn,
        ~p"/observability/netflows?#{%{q: q, limit: 50, view: "explorer", open_flow: "1"}}"
      )

    for {id, style} <- [
          {"netflow-row-time-0", "compact"},
          {"netflow-flow-detail-time", "full"}
        ] do
      assert has_element?(
               lv,
               ~s(time##{id}[datetime="2026-02-27T21:00:00Z"][data-user-time-iso="2026-02-27T21:00:00Z"][data-user-time-zone="America/Chicago"][data-user-time-style="#{style}"])
             )
    end

    assert has_element?(
             lv,
             ~s(#netflow-row-time-0[phx-hook="UserTime"])
           )

    assert has_element?(
             lv,
             ~s(#netflow-flow-detail-time[phx-hook="UserTime"])
           )
  end

  test "flow details map renders a configured Local CIDR anchor", %{conn: conn} do
    Application.put_env(
      :serviceradar_web_ng,
      :srql_module,
      ServiceRadarWebNGWeb.LogLive.NetflowsTest.RecordingSRQLStub
    )

    NetflowLocalCidr
    |> Ash.Changeset.for_create(
      :create,
      %{
        partition: "default",
        label: "k3s node interfaces",
        cidr: "192.168.1.0/24",
        location_label: "Carver, MN",
        latitude: 44.7636,
        longitude: -93.6258,
        enabled: true
      },
      actor: system_actor()
    )
    |> Ash.create!()

    settings = MapboxSettings.get_settings!(actor: system_actor())

    settings
    |> Ash.Changeset.for_update(
      :update,
      %{enabled: true, access_token: "pk.test-local-anchor"},
      actor: system_actor()
    )
    |> Ash.update!()

    q =
      ~s(in:flows time:last_24h src_endpoint_ip:192.168.1.134 dst_endpoint_ip:13.217.9.183 src_endpoint_port:57196 dst_endpoint_port:443 protocol_num:6 sort:time:desc limit:1)

    {:ok, lv, _html} =
      live(conn, ~p"/observability/netflows?#{%{q: q, limit: 50, open_flow: "1"}}")

    map =
      lv
      |> element(~s([phx-hook="MapboxFlowMap"]))
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([phx-hook="MapboxFlowMap"]))

    [markers_json] = LazyHTML.attribute(map, "data-markers")

    assert [source | _] = Jason.decode!(markers_json)
    assert source["label"] == "Source - 192.168.1.134 - Carver, MN"
    assert source["local_anchor"] == true
    assert source["lat"] == 44.7636
    assert source["lng"] == -93.6258
  end

  test "prefix tag filter control patches SRQL tag: into the query", %{conn: conn} do
    Application.put_env(
      :serviceradar_web_ng,
      :srql_module,
      ServiceRadarWebNGWeb.LogLive.NetflowsTest.RecordingSRQLStub
    )

    q = "in:flows time:last_24h"

    {:ok, lv, html} =
      live(conn, ~p"/observability/netflows?#{%{q: q, limit: 50, view: "explorer"}}")

    assert html =~ "Prefix tag"
    assert has_element?(lv, ~s(form[phx-submit="netflow_prefix_tag_filter"] input[name="tag"]))

    lv
    |> form(~s(form[phx-submit="netflow_prefix_tag_filter"]), %{"tag" => "netbox:tag:iot"})
    |> render_submit()

    path = assert_patch(lv)
    decoded = URI.decode_query(URI.parse(path).query || "")
    assert Map.get(decoded, "q", "") =~ "tag:netbox:tag:iot"
  end

  test "flow listing and detail show prefix tag chips when present", %{conn: conn} do
    Application.put_env(
      :serviceradar_web_ng,
      :srql_module,
      ServiceRadarWebNGWeb.LogLive.NetflowsTest.PrefixTaggedSRQLStub
    )

    q = "in:flows time:last_24h"

    {:ok, lv, html} =
      live(conn, ~p"/observability/netflows?#{%{q: q, limit: 50, view: "explorer"}}")

    assert html =~ "netbox:tag:corp"
    assert html =~ "provider:cloudflare"
    assert html =~ "Filter flows with tag netbox:tag:corp"
    assert has_element?(lv, ~s(form[phx-submit="netflow_prefix_tag_filter"]))

    {:ok, _lv, detail_html} =
      live(
        conn,
        ~p"/observability/netflows?#{%{q: q, limit: 50, view: "explorer", open_flow: "1"}}"
      )

    assert detail_html =~ "Flow details"
    assert detail_html =~ "netbox:tag:corp"
    assert detail_html =~ "provider:cloudflare"
    assert detail_html =~ "Prefix tag: netbox:tag:corp"
    assert detail_html =~ "Prefix tag: provider:cloudflare"
  end

  test "untagged flows do not render prefix tag chips", %{conn: conn} do
    Application.put_env(
      :serviceradar_web_ng,
      :srql_module,
      ServiceRadarWebNGWeb.LogLive.NetflowsTest.RecordingSRQLStub
    )

    q = "in:flows time:last_24h"

    {:ok, _lv, html} =
      live(conn, ~p"/observability/netflows?#{%{q: q, limit: 50, view: "explorer"}}")

    refute html =~ "Filter flows with tag"
    refute html =~ "Prefix tag: "
  end

  defp collect_srql_queries(acc) do
    receive do
      {:srql_query, query} when is_binary(query) ->
        collect_srql_queries([query | acc])
    after
      100 ->
        Enum.reverse(acc)
    end
  end

  defmodule RecordingSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @impl true
    def query(query) when is_binary(query), do: query(query, %{})

    @impl true
    def query(query, _opts) when is_binary(query) do
      case :persistent_term.get({ServiceRadarWebNGWeb.LogLive.NetflowsTest, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:srql_query, query})
        _ -> :ok
      end

      cond do
        String.contains?(query, "bucket:") ->
          {:ok,
           %{
             "results" => [
               %{"timestamp" => "2026-02-27T21:00:00Z", "series" => "tcp", "value" => 1024}
             ],
             "pagination" => %{},
             "error" => nil
           }}

        String.contains?(query, ~S|stats:"sum(bytes_total) as total_bytes"|) ->
          {:ok,
           %{
             "results" => [%{"total_bytes" => 10_800_000}],
             "pagination" => %{},
             "error" => nil
           }}

        String.contains?(query, ~S|stats:"sum(packets_total) as total_packets"|) ->
          {:ok,
           %{
             "results" => [%{"total_packets" => 86_400}],
             "pagination" => %{},
             "error" => nil
           }}

        String.contains?(query, ~S|stats:"sum(packets_in) as total_packets_in"|) ->
          {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}

        String.contains?(query, ~S|stats:"sum(packets_out) as total_packets_out"|) ->
          {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}

        String.contains?(query, ~S|stats:"sum(packets) as total_packets"|) ->
          {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}

        String.contains?(query, ~S|stats:"count(*) as total by protocol_num"|) ->
          {:ok,
           %{
             "results" => [
               %{"protocol_num" => 6, "total" => 1},
               %{"protocol_num" => 17, "total" => 1}
             ],
             "pagination" => %{},
             "error" => nil
           }}

        String.contains?(query, ~S|stats:"count(*) as total"|) ->
          {:ok,
           %{
             "results" => [%{"total" => 2}],
             "pagination" => %{},
             "error" => nil
           }}

        String.contains?(query, "in:flows") ->
          {:ok,
           %{
             "results" => [
               %{
                 "time" => "2026-02-27T21:00:00Z",
                 "src_endpoint_ip" => "192.168.1.134",
                 "dst_endpoint_ip" => "13.217.9.183",
                 "src_endpoint_port" => 57_196,
                 "dst_endpoint_port" => 443,
                 "protocol_num" => 6,
                 "protocol_name" => "tcp",
                 "direction_label" => "bidirectional",
                 "dst_service_label" => "HTTPS",
                 "src_hosting_provider" => "SourceNet Inc",
                 "dst_hosting_provider" => "DestNet LLC",
                 "src_mac" => "001122334455",
                 "dst_mac" => "AABBCCDDEEFF",
                 "src_mac_vendor" => "SourceVendor Corp",
                 "dst_mac_vendor" => "DestVendor Inc",
                 "tcp_flags" => 18,
                 "tcp_flags_labels" => ["SYN", "ACK"],
                 "packets_total" => 10,
                 "bytes_total" => 2048
               }
             ],
             "pagination" => %{},
             "error" => nil
           }}

        true ->
          {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}
      end
    end

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}
  end

  defmodule PrefixTaggedSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @impl true
    def query(query) when is_binary(query), do: query(query, %{})

    @impl true
    def query(query, _opts) when is_binary(query) do
      cond do
        String.contains?(query, "bucket:") ->
          {:ok,
           %{
             "results" => [
               %{"timestamp" => "2026-02-27T21:00:00Z", "series" => "tcp", "value" => 1024}
             ],
             "pagination" => %{},
             "error" => nil
           }}

        String.contains?(query, ~S|stats:"sum(bytes_total) as total_bytes"|) ->
          {:ok,
           %{
             "results" => [%{"total_bytes" => 10_800_000}],
             "pagination" => %{},
             "error" => nil
           }}

        String.contains?(query, ~S|stats:"sum(packets_total) as total_packets"|) ->
          {:ok,
           %{
             "results" => [%{"total_packets" => 86_400}],
             "pagination" => %{},
             "error" => nil
           }}

        String.contains?(query, ~S|stats:"count(*) as total"|) ->
          {:ok,
           %{
             "results" => [%{"total" => 1}],
             "pagination" => %{},
             "error" => nil
           }}

        String.contains?(query, "in:flows") ->
          {:ok,
           %{
             "results" => [
               %{
                 "time" => "2026-02-27T21:00:00Z",
                 "src_endpoint_ip" => "192.168.1.134",
                 "dst_endpoint_ip" => "13.217.9.183",
                 "src_endpoint_port" => 57_196,
                 "dst_endpoint_port" => 443,
                 "protocol_num" => 6,
                 "protocol_name" => "tcp",
                 "direction_label" => "bidirectional",
                 "dst_service_label" => "HTTPS",
                 "src_hosting_provider" => "SourceNet Inc",
                 "dst_hosting_provider" => "DestNet LLC",
                 "src_prefix_tags" => ["netbox:tag:corp"],
                 "dst_prefix_tags" => ["provider:cloudflare"],
                 "packets_total" => 10,
                 "bytes_total" => 2048
               }
             ],
             "pagination" => %{},
             "error" => nil
           }}

        true ->
          {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}
      end
    end

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}
  end
end
