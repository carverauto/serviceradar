defmodule ServiceRadar.EventWriter.Processors.NormalizedLogParityTest do
  @moduledoc """
  A syslog record must be stored the same whichever side ran its Zen rules.

  Each shared case holds the record the log collector publishes in JSON mode
  (`gelf`), for EventWriter to normalize, and the batch it publishes for the
  same syslog line when it normalizes the record itself (`otlp`). The
  collector's tests keep both current with its encoders
  (rust/flowgger/src/flowgger/normalized/tests.rs).

  The hand-picked cases are in a shared file. The generated ones come from the
  collector's own test binary, which this suite runs: the property covers two
  languages, so the collector generates and encodes, and EventWriter compares.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.Processors.Logs
  alias ServiceRadar.Observability.Zen.Normalizer

  @cases Path.expand(
           "../../../../../../rust/flowgger/tests/resources/normalized_log_parity.json",
           __DIR__
         )
  @generator_dir Path.expand("../../../../../../rust/flowgger", __DIR__)
  @generator_test "flowgger::normalized::tests::props::write_parity_corpus"
  @rules {__MODULE__, :rules}

  defmodule RuleLoader do
    @moduledoc false
    def load_rules("logs.syslog"),
      do:
        {:ok, Process.get({ServiceRadar.EventWriter.Processors.NormalizedLogParityTest, :rules})}
  end

  setup do
    old_config = Application.get_env(:serviceradar_core, Normalizer, [])
    Application.put_env(:serviceradar_core, Normalizer, runtime_rule_loader: RuleLoader)
    Normalizer.invalidate_all()

    on_exit(fn ->
      Application.put_env(:serviceradar_core, Normalizer, old_config)
      Normalizer.invalidate_all()
    end)

    {:ok, cases: @cases |> File.read!() |> Jason.decode!()}
  end

  test "both paths store the same row for every shared case", %{cases: cases} do
    assert cases != []

    for %{"name" => name} = shared <- cases do
      assert {name, comparable(collector_normalized_row(shared))} ==
               {name, comparable(json_row(shared))}
    end
  end

  # Records, receive times and rule outputs the collector's generators draw, a
  # fresh set on every run: 300, or as many as PARITY_CORPUS_CASES asks for. A
  # failure prints one case of each kind; add it to the shared file to keep it.
  # The Bazel target bounds the time.
  @tag timeout: :infinity
  test "both paths store the same row for generated records and rule outputs" do
    wanted = String.to_integer(System.get_env("PARITY_CORPUS_CASES", "300"))
    cases = generated_cases(wanted)
    assert length(cases) >= wanted

    disagreements =
      for shared <- cases,
          collector = shared |> collector_normalized_rows() |> Enum.map(&comparable/1),
          json = shared |> json_rows() |> Enum.map(&comparable/1),
          collector != json do
        {differing_columns(collector, json), shared, collector, json}
      end

    assert disagreements == [],
           "the two paths store different rows for #{length(disagreements)} of " <>
             "#{length(cases)} generated cases. One of each kind:\n\n" <>
             (disagreements
              |> Enum.uniq_by(&elem(&1, 0))
              |> Enum.map_join("\n\n", &describe/1))
  end

  # The rows agreeing proves nothing if both paths ignore the record, so one
  # case is also held to what its syslog line says.
  test "a collector-normalized record keeps what its syslog line said", %{cases: cases} do
    shared = Enum.find(cases, &(&1["name"] == "a syslog record with no rules"))

    assert shared["line"] ==
             ~s(<13>1 2030-01-02T03:04:05.250Z host01.example.com app 4242 ID47 ) <>
               ~s([test@1 detail="synthetic"] synthetic message)

    row = collector_normalized_row(shared)

    assert row.timestamp == ~U[2030-01-02 03:04:05.250000Z]
    assert row.observed_timestamp == ~U[2030-01-02 03:04:06.000000Z]

    assert %{
             body: "synthetic message",
             severity_text: "INFO",
             severity_number: 9,
             source: "syslog",
             source_ip: "192.0.2.10",
             service_name: "app",
             service_version: nil,
             scope_name: nil
           } = row

    assert %{"_remote_addr" => "default:192.0.2.10", "_syslog_format" => "rfc5424"} =
             row.attributes

    refute Enum.any?(Map.keys(row.attributes), &String.starts_with?(&1, "serviceradar.column."))
  end

  defp differing_columns([collector], [json]) do
    for column <- Map.keys(collector), collector[column] != json[column], do: column
  end

  defp differing_columns(collector, json), do: {:rows, length(collector), length(json)}

  defp describe({columns, shared, collector, json}) do
    stored =
      case columns do
        {:rows, _, _} ->
          ["collector: #{inspect(collector)}", "json: #{inspect(json)}"]

        columns ->
          for column <- columns do
            "#{column}: collector #{inspect(hd(collector)[column])}, " <>
              "json #{inspect(hd(json)[column])}"
          end
      end

    Enum.join(stored ++ [Jason.encode!(Map.delete(shared, "otlp"))], "\n")
  end

  defp generated_cases(wanted) do
    assert [generator] =
             Path.wildcard(Path.join(@generator_dir, "**/flowgger_properties_test")),
           "the collector's property test binary is a declared input of this target"

    corpus = Path.join(System.tmp_dir!(), "parity-corpus-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(corpus) end)

    {output, status} =
      System.cmd(generator, ["--ignored", "--exact", @generator_test],
        stderr_to_stdout: true,
        env: [
          {"PARITY_CORPUS_OUT", corpus},
          # No example database, which a test sandbox cannot write; a random seed.
          {"HEGEL_DEFAULT_PROFILE", "ci"},
          {"HEGEL_DERANDOMIZE", "false"},
          {"HEGEL_TEST_CASES", Integer.to_string(wanted)}
        ]
      )

    assert status == 0, output

    corpus |> File.stream!() |> Enum.map(&Jason.decode!/1)
  end

  defp json_rows(shared), do: shared |> json_row() |> List.wrap()

  defp collector_normalized_rows(shared) do
    Logs.parse_message(%{
      data: Base.decode64!(shared["otlp"]),
      metadata: collector_metadata(shared)
    })
  end

  defp json_row(shared) do
    Process.put(@rules, Enum.map(shared["rules"], &{&1["key"], Jason.encode!(&1["jdm"])}))
    Normalizer.invalidate_subject("logs.syslog")

    Logs.parse_message(%{
      data: Jason.encode!(shared["gelf"]),
      metadata: %{subject: "logs.syslog", received_at: received_at(shared)}
    })
  end

  # EventWriter reads the batch a day after the collector received the line:
  # every time in the row has to be the collector's.
  defp collector_normalized_row(shared) do
    assert [row] = collector_normalized_rows(shared)
    row
  end

  defp collector_metadata(shared) do
    %{
      subject: "logs.normalized.syslog",
      received_at: DateTime.shift(received_at(shared), day: 1),
      headers: [
        {"Sr-Log-Schema", "otlp-normalized-v1"},
        {"Sr-Ruleset-Id", "sha256:synthetic"}
      ]
    }
  end

  defp received_at(shared), do: DateTime.from_unix!(shared["received_unix_nano"], :nanosecond)

  # Ids and insertion time are generated per row, and `serviceradar.ingest`
  # records which subject delivered it.
  defp comparable(row) do
    row
    |> Map.drop([:id, :created_at])
    |> Map.update!(:attributes, &Map.delete(&1, "serviceradar.ingest"))
    |> Map.update!(:timestamp, &DateTime.to_unix(&1, :microsecond))
    |> Map.update!(:observed_timestamp, &DateTime.to_unix(&1, :microsecond))
  end
end
