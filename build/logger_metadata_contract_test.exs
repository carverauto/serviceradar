ExUnit.start()

elixir_root = Path.expand("../elixir", __DIR__)

Code.require_file(
  Path.join(elixir_root, "serviceradar_core/lib/serviceradar/logging/console_formatter.ex")
)

defmodule ServiceRadar.LoggerMetadataContractTest.RawEventHandler do
  @moduledoc false

  # Stands in for any second `:logger` handler, such as the OTLP log handler:
  # it reports the event exactly as `:logger` delivered it.
  def log(event, %{config: %{test_pid: test_pid}}), do: send(test_pid, {:raw_event, event})
end

defmodule ServiceRadar.LoggerMetadataContractTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.LoggerMetadataContractTest.RawEventHandler
  alias ServiceRadar.Logging.ConsoleFormatter

  require Logger

  @moduletag :capture_log

  @elixir_root elixir_root
  # The releases whose console handler uses ConsoleFormatter, plus the core
  # library they all embed.
  @apps ~w(serviceradar_core serviceradar_core_elx serviceradar_agent_gateway web-ng)
  @guarded_levels ~w(warning warn error critical alert emergency)a
  # Not a key any call site uses, so it is in neither list.
  @unlisted_key :console_formatter_contract_unlisted

  describe "console handler output" do
    setup do
      {:ok, device} = StringIO.open("")
      console = :"console_#{System.unique_integer([:positive])}"
      raw = :"raw_#{System.unique_integer([:positive])}"

      :ok =
        :logger.add_handler(console, :logger_std_h, %{
          level: :all,
          formatter: {ConsoleFormatter, %{}},
          config: %{type: {:device, device}}
        })

      :ok =
        :logger.add_handler(raw, RawEventHandler, %{level: :all, config: %{test_pid: self()}})

      on_exit(fn ->
        :logger.remove_handler(console)
        :logger.remove_handler(raw)
      end)

      %{console: console, device: device}
    end

    test "prints allowlisted metadata, omits other keys, and leaves other handlers the full event",
         %{console: console, device: device} do
      marker = "contract-#{System.unique_integer([:positive])}"
      long_reason = String.duplicate("r", ConsoleFormatter.max_value_bytes() + 100)

      Logger.warning(
        "Sweep dispatch failed #{marker}",
        [
          {:reason, long_reason},
          {:agent_id, "agent-01"},
          {@unlisted_key, "unlisted-value"}
        ]
      )

      :ok = :logger_std_h.filesync(console)
      {_input, output} = StringIO.contents(device)
      line = output |> String.split("\n") |> Enum.find(&String.contains?(&1, marker))

      assert line, "the console handler printed nothing for the event: #{inspect(output)}"
      assert line =~ "[warning] Sweep dispatch failed #{marker}"
      assert line =~ "agent_id=agent-01 "

      printed_reason = String.duplicate("r", ConsoleFormatter.max_value_bytes())
      assert line =~ "reason=#{printed_reason}...[truncated, #{byte_size(long_reason)} bytes] "

      refute line =~ Atom.to_string(@unlisted_key)
      refute line =~ "unlisted-value"

      assert_receive {:raw_event, %{msg: {:string, message}, meta: meta}}, 1_000
      assert IO.chardata_to_string(message) == "Sweep dispatch failed #{marker}"
      assert meta.reason == long_reason
      assert Map.fetch!(meta, @unlisted_key) == "unlisted-value"
    end
  end

  describe "metadata value rendering" do
    cases = [
      {"a false value is printed, not dropped", false, "false"},
      {"a term is printed with inspect", {:error, :timeout}, "{:error, :timeout}"},
      {"a line break stays on one line", "first\nsecond\r\nthird", "first\\nsecond\\nthird"},
      {"a module name drops the Elixir prefix", Inspect.Error, "Inspect.Error"}
    ]

    for {name, value, expected} <- cases do
      test name do
        assert format_reason(unquote(Macro.escape(value))) ==
                 "reason=#{unquote(expected)} [warning] probe failed\n"
      end
    end

    test "a cut never splits a multi-byte character" do
      # 511 ASCII bytes, then a two-byte character straddling the limit.
      value = String.duplicate("a", ConsoleFormatter.max_value_bytes() - 1) <> "éé"
      kept = String.duplicate("a", ConsoleFormatter.max_value_bytes() - 1)

      assert format_reason(value) ==
               "reason=#{kept}...[truncated, #{byte_size(value)} bytes] [warning] probe failed\n"
    end

    defp format_reason(value) do
      %{level: :warning, msg: {:string, "probe failed"}, meta: %{time: 0, reason: value}}
      |> ConsoleFormatter.format(%{format: "$metadata[$level] $message\n"})
      |> IO.chardata_to_string()
    end
  end

  describe "metadata keys at warning and error call sites" do
    test "every key is either printed or deliberately withheld" do
      printed = MapSet.new(ConsoleFormatter.printed_keys())
      withheld = MapSet.new(Keyword.keys(ConsoleFormatter.withheld_keys()))

      assert MapSet.disjoint?(printed, withheld),
             "keys in both lists: #{inspect(MapSet.to_list(MapSet.intersection(printed, withheld)))}"

      uses = Enum.flat_map(@apps, &metadata_key_uses/1)

      for app <- @apps do
        assert Enum.any?(source_files(app)),
               "no sources found for #{app}; the guard scanned nothing"
      end

      assert length(uses) > 100,
             "found only #{length(uses)} metadata keys; the call-site scan is not matching Logger calls"

      unclassified =
        uses
        |> Enum.reject(fn {key, _where} -> key in printed or key in withheld end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.sort()

      assert unclassified == [], """
      Logger.warning/error metadata keys that the console would silently drop:

      #{Enum.map_join(unclassified, "\n", fn {key, where} -> "  #{key}: #{Enum.join(Enum.sort(where), ", ")}" end)}

      Add each key to @printed_keys in ServiceRadar.Logging.ConsoleFormatter when every
      call site puts a non-secret, already-redacted value under it; otherwise add it to
      @withheld_keys with the reason.
      """
    end
  end

  defp source_files(app), do: Path.wildcard(Path.join([@elixir_root, app, "lib/**/*.ex"]))

  defp metadata_key_uses(app) do
    Enum.flat_map(source_files(app), fn path ->
      relative = Path.relative_to(path, @elixir_root)

      {_ast, uses} =
        path
        |> File.read!()
        |> Code.string_to_quoted!(file: path)
        |> Macro.prewalk([], fn node, acc ->
          {node, literal_metadata_keys(node, relative) ++ acc}
        end)

      uses
    end)
  end

  # `Logger.warning(message, key: value)`. Metadata passed as a variable cannot
  # be read from the source and is not covered.
  defp literal_metadata_keys(
         {{:., _, [{:__aliases__, _, [:Logger]}, level]}, meta, [_message, metadata]},
         relative
       )
       when level in @guarded_levels and is_list(metadata) do
    for {key, _value} when is_atom(key) <- metadata, do: {key, "#{relative}:#{meta[:line]}"}
  end

  defp literal_metadata_keys(_node, _relative), do: []
end
