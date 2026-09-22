defmodule ServiceRadar.Analytics.StarRocks.StreamLoadTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Attribution
  alias ServiceRadar.Analytics.StarRocks.StreamLoad

  @moduletag :db_free

  @rows [
    %{"id" => "flow-alpha", "bytes_in" => 1200, "bytes_out" => 80},
    %{"id" => "flow-bravo", "bytes_in" => 44, "bytes_out" => 9}
  ]

  test "stable identities produce the same load label across retry regrouping" do
    shuffled = Enum.reverse(@rows)

    assert StreamLoad.load_label("ocsf_network_activity", @rows) ==
             StreamLoad.load_label("ocsf_network_activity", shuffled)
  end

  test "HTTP success is not ACK until Status is Success and loaded rows match" do
    http = fn
      %{method: :put, headers: headers, url: url, body: body} ->
        assert url =~ "/api/serviceradar/ocsf_network_activity/_stream_load"
        assert List.keyfind(headers, "label", 0)
        assert Jason.decode!(body) == @rows

        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "Status" => "Success",
               "NumberLoadedRows" => 2,
               "NumberFilteredRows" => 0
             })
         }}
    end

    assert {:ok, %{loaded: 2, label: label}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http, config: %{})

    assert String.starts_with?(label, "sr-")
  end

  test "partial update sets Stream Load headers and does not send traffic columns" do
    rows = [
      %{
        "id" => "flow-alpha-0001",
        "time" => "1999-06-15 12:00:00",
        "attribution_version" => 3,
        "pid" => 9,
        "comm" => "sshd"
      }
    ]

    http = fn %{method: :put, headers: headers, body: body} ->
      assert {"partial_update", "true"} in headers
      assert {"merge_condition", "attribution_version"} in headers
      assert {"columns", Enum.join(Attribution.load_columns(), ",")} in headers
      [payload] = Jason.decode!(body)
      refute Map.has_key?(payload, "bytes_in")
      assert payload["time"] == "1999-06-15 12:00:00"

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "Status" => "Success",
             "NumberLoadedRows" => 1,
             "NumberFilteredRows" => 0
           })
       }}
    end

    assert {:ok, %{loaded: 1}} =
             StreamLoad.persist("ocsf_network_activity", rows,
               http: http,
               config: %{},
               partial_update: true,
               merge_condition: "attribution_version",
               columns: Attribution.load_columns()
             )
  end

  test "filtered rows quarantine instead of acknowledging" do
    http = fn _request ->
      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "Status" => "Success",
             "NumberLoadedRows" => 1,
             "NumberFilteredRows" => 1
           })
       }}
    end

    assert {:quarantine, {:filtered_rows, 1, _label}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http)
  end

  test "publish timeout reconciles the original label before ACK" do
    label = StreamLoad.load_label("ocsf_network_activity", @rows)

    http = fn
      %{method: :put} ->
        {:ok, %{status: 200, body: Jason.encode!(%{"Status" => "Publish Timeout"})}}

      %{method: :get, url: url} ->
        assert url =~ "get_load_state?label=#{label}"

        {:ok, %{status: 200, body: load_state_body("VISIBLE")}}
    end

    assert {:ok, %{loaded: 2, reconciled: true, label: ^label}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http, label: label)
  end

  test "redelivery of an already-loaded batch reconciles instead of failing the ACK" do
    label = StreamLoad.load_label("ocsf_network_activity", @rows)

    http = fn
      %{method: :put} ->
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "TxnId" => -1,
               "Label" => label,
               "Status" => "Label Already Exists",
               "ExistingJobStatus" => "FINISHED",
               "Message" => "Label [#{label}] has already been used.",
               "NumberTotalRows" => 0,
               "NumberLoadedRows" => 0,
               "NumberFilteredRows" => 0
             })
         }}

      %{method: :get} ->
        {:ok, %{status: 200, body: load_state_body("VISIBLE")}}
    end

    assert {:ok, %{loaded: 2, reconciled: true, label: ^label}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http)
  end

  test "a committed but not yet visible transaction is a durable load" do
    http = fn
      %{method: :put} -> {:error, :timeout}
      %{method: :get} -> {:ok, %{status: 200, body: load_state_body("COMMITTED")}}
    end

    assert {:ok, %{loaded: 2, reconciled: true}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http)
  end

  test "an aborted label is never acknowledged as persisted" do
    http = fn
      %{method: :put} ->
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "Status" => "Label Already Exists",
               "ExistingJobStatus" => "FINISHED"
             })
         }}

      %{method: :get} ->
        {:ok, %{status: 200, body: load_state_body("ABORTED", "too many filtered rows")}}
    end

    assert {:error, {:label_aborted, _label}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http)
  end

  test "follows FE 307 redirect to the Stream Load coordinator" do
    parent = self()

    http = fn
      %{url: url} = request ->
        if String.contains?(url, "coordinator") do
          send(parent, {:loaded, url, request.body})

          {:ok,
           %{
             status: 200,
             body:
               Jason.encode!(%{
                 "Status" => "Success",
                 "NumberLoadedRows" => 2,
                 "NumberFilteredRows" => 0
               })
           }}
        else
          send(parent, {:redirected, url})

          {:ok,
           %{
             status: 307,
             headers: [
               {"location",
                "http://coordinator.example.invalid/api/serviceradar/ocsf_network_activity/_stream_load"}
             ],
             body: ""
           }}
        end
    end

    assert {:ok, %{loaded: 2}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http, config: %{})

    assert_received {:redirected, fe_url}
    assert fe_url =~ "/_stream_load"

    assert_received {:loaded,
                     "http://coordinator.example.invalid/api/serviceradar/ocsf_network_activity/_stream_load",
                     body}

    assert Jason.decode!(body) == @rows
  end

  test "uninjected persist uses HTTP instead of a stub ACK" do
    assert {:error, {reason, label}} =
             StreamLoad.persist("ocsf_network_activity", @rows,
               config: %{fe_http: "http://127.0.0.1:1", database: "serviceradar"}
             )

    refute reason == :starrocks_http_not_configured
    assert is_binary(label)
    assert String.starts_with?(label, "sr-")
  end

  test "lost HTTP response after timeout does not ACK until the transaction commits" do
    http = fn
      %{method: :put} -> {:error, :timeout}
      %{method: :get} -> {:ok, %{status: 200, body: load_state_body("UNKNOWN")}}
    end

    assert {:error, {:unresolved_label, _label, "ocsf_network_activity"}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http)
  end

  # Shape of a real `/api/<db>/get_load_state` answer, as returned by the
  # StarRocks release this change targets.
  defp load_state_body(state, reason \\ "") do
    Jason.encode!(%{
      "state" => state,
      "reason" => reason,
      "status" => "OK",
      "code" => "0",
      "msg" => "Success",
      "message" => "OK"
    })
  end
end
