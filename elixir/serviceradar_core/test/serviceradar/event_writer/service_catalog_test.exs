defmodule ServiceRadar.EventWriter.ServiceCatalogTest do
  @moduledoc """
  Throttling and failure isolation of the OTel service catalog upsert.

  The repo is a recorder standing in for `Repo.insert_all/3` only, so these
  tests observe which writes EventWriter issues; the SQL itself is covered
  against CNPG in `service_catalog_db_test.exs`.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.ServiceCatalog
  alias ServiceRadar.EventWriter.ServiceCatalogCache

  defmodule RecordingRepo do
    @moduledoc false

    def insert_all(table, entries, opts) do
      send(self(), {:insert_all, table, entries, opts})

      case Process.get(:recording_repo_fail) do
        nil -> {length(entries), nil}
        error -> raise error
      end
    end
  end

  @upsert_error [:serviceradar, :event_writer, :service_catalog, :upsert_error]
  @names_dropped [:serviceradar, :event_writer, :service_catalog, :names_dropped]

  setup context do
    table = :"service_catalog_test_#{System.unique_integer([:positive])}"
    interval = Map.get(context, :refresh_interval_ms, 60_000)

    start_supervised!(
      {ServiceCatalogCache, name: table, table: table, refresh_interval_ms: interval}
    )

    handler = "service-catalog-test-#{inspect(self())}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      [@upsert_error, @names_dropped],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{opts: [repo: RecordingRepo, cache: table]}
  end

  defp rows(names), do: Enum.map(names, &%{service_name: &1})

  defp written_names do
    receive do
      {:insert_all, "otel_service_catalog", entries, _opts} ->
        Enum.map(entries, & &1.service_name)
    after
      0 -> :no_write
    end
  end

  test "writes each new service once per signal and skips repeats within the interval",
       %{opts: opts} do
    assert {:ok, 2} =
             ServiceCatalog.record(:traces, rows(["checkout", "billing", "checkout"]), opts)

    assert written_names() == ["billing", "checkout"]

    assert {:ok, 0} = ServiceCatalog.record(:traces, rows(["checkout", "billing"]), opts)
    assert written_names() == :no_write

    # The seen-cache is per signal: logs for the same service is a new pair.
    assert {:ok, 1} = ServiceCatalog.record(:logs, rows(["checkout"]), opts)

    assert_received {:insert_all, "otel_service_catalog", [entry], _opts}
    assert Map.has_key?(entry, :logs_last_seen_at)
    refute Map.has_key?(entry, :traces_last_seen_at)
  end

  @tag refresh_interval_ms: 0
  test "writes again once the refresh interval has passed", %{opts: opts} do
    assert {:ok, 1} = ServiceCatalog.record(:metrics, rows(["checkout"]), opts)
    assert written_names() == ["checkout"]

    assert {:ok, 1} = ServiceCatalog.record(:metrics, rows(["checkout"]), opts)
    assert written_names() == ["checkout"]
  end

  test "a failed upsert never raises, emits upsert_error, and is retried by the next batch",
       %{opts: opts} do
    Process.put(:recording_repo_fail, DBConnection.ConnectionError.exception("connection lost"))

    assert {:error, %DBConnection.ConnectionError{}} =
             ServiceCatalog.record(:metrics, rows(["checkout"]), opts)

    assert written_names() == ["checkout"]
    assert_received {:telemetry, @upsert_error, %{count: 1}, %{signal: :metrics}}

    Process.delete(:recording_repo_fail)

    assert {:ok, 1} = ServiceCatalog.record(:metrics, rows(["checkout"]), opts)
    assert written_names() == ["checkout"]
  end

  test "ignores blank names and drops overlong or unstorable names with a count",
       %{opts: opts} do
    longest = String.duplicate("a", 255)

    batch = [
      %{service_name: nil},
      %{service_name: ""},
      %{service_name: "   "},
      %{other: "no service"},
      %{service_name: longest},
      %{service_name: String.duplicate("b", 256)},
      %{service_name: <<0xFF, 0xFE>>},
      %{service_name: "svc\0-0001"}
    ]

    assert {:ok, 1} = ServiceCatalog.record(:logs, batch, opts)
    assert written_names() == [longest]

    assert_received {:telemetry, @names_dropped, %{count: 1}, %{reason: :too_long}}
    assert_received {:telemetry, @names_dropped, %{count: 2}, %{reason: :invalid}}
  end

  test "counts codepoints like Postgres char_length, so combining marks cannot poison a batch",
       %{opts: opts} do
    combining = "e" <> String.duplicate("\u0301", 299)
    assert String.length(combining) < 255
    assert length(String.codepoints(combining)) > 255

    assert {:ok, 1} = ServiceCatalog.record(:logs, rows([combining, "checkout"]), opts)
    assert written_names() == ["checkout"]

    assert_received {:telemetry, @names_dropped, %{count: 1}, %{reason: :too_long}}
  end
end
