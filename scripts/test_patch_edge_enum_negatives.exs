#!/usr/bin/env elixir

# Committed fixture test for scripts/patch_edge_enum_negatives.exs (task 1.5).
#
# The transform is part of the ABI toolchain: if it silently no-ops, an edge enum ships WITHOUT the
# negative-retention clauses and the Go/Elixir accept-reject parity breaks with no other signal. The
# byte-exact `verify-proto-edge-elixir` gate cannot catch that on its own, because it compares a
# regenerated tree against the committed tree -- both produced by the SAME transform.
#
# So this asserts the transform's FAIL-CLOSED contract directly, on synthetic fixtures, with no
# protoc dependency:
#
#   1. a clean unpatched pair is patched, and re-running is a no-op (idempotent);
#   2. INVENTORY drift (an unexpected enum, including a NESTED one) exits non-zero;
#   3. GENERATOR-VERSION drift exits non-zero;
#   4. SOURCE-SHAPE drift (a module declaring `enum: true` that no longer matches the pinned
#      generated shape) exits non-zero;
#   5. PARTIAL PATCH (marker present, clauses stripped) exits non-zero -- the fail-open case a
#      file-wide marker check would miss.
#
# Usage: elixir scripts/test_patch_edge_enum_negatives.exs

defmodule TransformFixtureTest do
  @script Path.expand("patch_edge_enum_negatives.exs", __DIR__)

  # Exactly the modules the transform pins, so a clean fixture satisfies the inventory check.
  @inventory ~w(
    EdgeCapabilityPurpose EdgeOriginKind EdgeRecordCompression EdgeRecordEncoding EdgeRecordDispositionKind
    EdgeRecordPayloadFamily EdgeRecordRouteProfile EdgeRecordTrafficClass
    EdgeSourceAuthorizationKind EdgeUnattributableReason MtrCompletionDisposition MtrOutcome
    SweepAssignmentState SweepExecutionEventKind
    SweepExecutionSource
    SweepMode SweepModeBit SweepModeOutcome SweepResultFormat TransportProtocol
  )

  # Derived, never restated: adding an enum to the inventory above must not require
  # also finding and bumping a hardcoded count in the checks below.
  @inventory_count length(@inventory)

  def run do
    results = [
      check("clean tree is patched, then idempotent", &clean_then_idempotent/0),
      check("inventory drift (nested enum) fails closed", &inventory_drift/0),
      check("generator-version drift fails closed", &generator_drift/0),
      check("source-shape drift fails closed", &shape_drift/0),
      check("partial patch fails closed", &partial_patch/0)
    ]

    failed = Enum.count(results, &(&1 == :failed))

    if failed == 0 do
      IO.puts("transform fixture test: #{length(results)} checks passed")
    else
      IO.puts(:stderr, "transform fixture test: #{failed} check(s) FAILED")
      System.halt(1)
    end
  end

  defp check(name, fun) do
    case fun.() do
      :ok ->
        IO.puts("  ok   #{name}")
        :ok

      {:error, detail} ->
        IO.puts(:stderr, "  FAIL #{name}: #{detail}")
        :failed
    end
  end

  # ---- fixtures ---------------------------------------------------------------------------------

  defp enum_module(name, version \\ "0.16.0") do
    """
    defmodule Serviceradar.Edge.V1.#{name} do
      @moduledoc false

      use Protobuf,
        enum: true,
        full_name: "serviceradar.edge.v1.#{name}",
        protoc_gen_elixir_version: "#{version}",
        syntax: :proto3

      field :#{String.upcase(name)}_UNSPECIFIED, 0
    end
    """
  end

  defp write_tree(modules) do
    dir = Path.join(System.tmp_dir!(), "edge_enum_fixture_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([dir, "edge", "v1"]))
    File.write!(Path.join([dir, "edge", "v1", "record.pb.ex"]), Enum.join(modules, "\n"))
    dir
  end

  defp default_modules, do: Enum.map(@inventory, &enum_module/1)

  defp run_transform(dir) do
    {out, status} = System.cmd("elixir", [@script, dir], stderr_to_stdout: true)
    {status, out}
  end

  # ---- checks -----------------------------------------------------------------------------------

  defp clean_then_idempotent do
    dir = write_tree(default_modules())
    file = Path.join([dir, "edge", "v1", "record.pb.ex"])

    with {0, _} <- run_transform(dir),
         content = File.read!(file),
         @inventory_count <- count(content, "def key(tag) when is_integer(tag) and tag < 0, do: tag"),
         @inventory_count <-
           count(content, "def value(tag) when is_integer(tag) and tag < 0, do: tag"),
         {0, out} <- run_transform(dir),
         ^content <- File.read!(file),
         true <- String.contains?(out, "0 file(s) patched") do
      cleanup(dir)
      :ok
    else
      other ->
        cleanup(dir)
        {:error, "unexpected: #{inspect(other)}"}
    end
  end

  defp inventory_drift do
    # A NESTED enum (`<Message>.<Enum>`) is exactly the shape a one-segment matcher would miss.
    nested = """
    defmodule Serviceradar.Edge.V1.InventoryProbe.NestedState do
      @moduledoc false

      use Protobuf,
        enum: true,
        full_name: "serviceradar.edge.v1.InventoryProbe.NestedState",
        protoc_gen_elixir_version: "0.16.0",
        syntax: :proto3

      field :NESTED_STATE_UNSPECIFIED, 0
    end
    """

    expect_failure(default_modules() ++ [nested], "unexpected")
  end

  defp generator_drift do
    [first | rest] = @inventory
    modules = [enum_module(first, "0.17.0") | Enum.map(rest, &enum_module/1)]
    expect_failure(modules, "generator drift")
  end

  defp shape_drift do
    mangled = """
    defmodule Serviceradar.Edge.V1.ShapeProbe do
      @moduledoc false

      use Protobuf, enum: true, full_name: "x", protoc_gen_elixir_version: "0.16.0", syntax: :proto3

      field :SHAPE_PROBE_UNSPECIFIED, 0
    end
    """

    expect_failure(default_modules() ++ [mangled], "source drift")
  end

  defp partial_patch do
    dir = write_tree(default_modules())
    file = Path.join([dir, "edge", "v1", "record.pb.ex"])
    {0, _} = run_transform(dir)

    # Strip the two clauses from ONE module while leaving its marker: a file-wide marker check would
    # report "already patched" and ship a file with N markers but N-1 clause pairs.
    patched = File.read!(file)

    broken =
      String.replace(
        patched,
        "  def key(tag) when is_integer(tag) and tag < 0, do: tag\n" <>
          "  def value(tag) when is_integer(tag) and tag < 0, do: tag\n",
        "",
        global: false
      )

    File.write!(file, broken)

    case run_transform(dir) do
      {status, out} when status != 0 ->
        cleanup(dir)
        if String.contains?(out, "PARTIAL PATCH"), do: :ok, else: {:error, "wrong message: #{out}"}

      {0, out} ->
        cleanup(dir)
        {:error, "exited 0 on a partial patch (fail-open): #{out}"}
    end
  end

  defp expect_failure(modules, expected_fragment) do
    dir = write_tree(modules)

    case run_transform(dir) do
      {status, out} when status != 0 ->
        cleanup(dir)

        if String.contains?(out, expected_fragment),
          do: :ok,
          else: {:error, "exited #{status} but message lacked #{inspect(expected_fragment)}: #{out}"}

      {0, out} ->
        cleanup(dir)
        {:error, "exited 0, expected failure (#{expected_fragment}): #{out}"}
    end
  end

  defp count(haystack, needle), do: haystack |> String.split(needle) |> length() |> Kernel.-(1)
  defp cleanup(dir), do: File.rm_rf!(dir)
end

TransformFixtureTest.run()
