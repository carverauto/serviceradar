#!/usr/bin/env elixir

# Post-generation transform for the edge/v1 Elixir protobuf bindings (task 1.5, enum parity).
#
# WHY: Go retains an unknown/NEGATIVE int32 enum as its integer and rejects it in the explicit
# SEMANTIC validator (a permanent_rejection). protobuf-elixir's generated `key/1` and `value/1`
# catchalls are guarded `when is_integer(tag) and tag >= 0`, so a negative enum RAISES during
# decode. That is not merely a disposition mismatch: because protobuf resolves a repeated singular
# field LAST-ONE-WINS, `traffic_class = -1` followed by `traffic_class = BULK` has the effective
# value BULK -- which Go ACCEPTS and Elixir would REJECT outright, since the decoder raises on the
# first occurrence before ever reaching the second.
#
# This transform injects two identity clauses into each generated edge ENUM module so negative tags
# are RETAINED exactly as Go retains them. They are declared in the module BODY on purpose: the
# Protobuf DSL appends its own clauses at `@before_compile`, so body clauses take precedence for
# negatives while every other tag falls through to the generated clauses unchanged.
#
# It is a project-owned transform -- NOT a protobuf fork and NOT a custom generator template -- and
# runs in BOTH the generate path and the clean-temp verify path BEFORE formatting/comparison, so the
# byte-exact drift gate stays meaningful.
#
# Usage: elixir scripts/patch_edge_enum_negatives.exs <root-dir-containing-edge/v1>
#
# Deterministic, idempotent, and FAIL-CLOSED on generator-version, module-inventory, source-shape,
# or PARTIAL-PATCH drift. Every enum module is validated and patched INDEPENDENTLY: a file-wide
# marker check would be fail-open, letting a file with some clauses stripped report "already
# patched".

defmodule PatchEdgeEnumNegatives do
  @expected_generator "0.16.0"

  # The exact edge enum inventory, including NESTED enums (`<Message>.<Enum>`). A new/removed/
  # renamed enum MUST be a deliberate edit here, so a silently unpatched enum can never ship.
  @expected_modules ~w(
    Serviceradar.Edge.V1.EdgeCapabilityPurpose
    Serviceradar.Edge.V1.EdgeOriginKind
    Serviceradar.Edge.V1.EdgeRecordCompression
    Serviceradar.Edge.V1.EdgeRecordDispositionKind
    Serviceradar.Edge.V1.EdgeRecordPayloadFamily
    Serviceradar.Edge.V1.EdgeRecordRouteProfile
    Serviceradar.Edge.V1.EdgeRecordTrafficClass
    Serviceradar.Edge.V1.EdgeSourceAuthorizationKind
    Serviceradar.Edge.V1.EdgeUnattributableReason
    Serviceradar.Edge.V1.MtrCompletionDisposition
    Serviceradar.Edge.V1.MtrOutcome
    Serviceradar.Edge.V1.SweepAssignmentState
    Serviceradar.Edge.V1.SweepExecutionEventKind
    Serviceradar.Edge.V1.SweepExecutionSource
    Serviceradar.Edge.V1.SweepMode
    Serviceradar.Edge.V1.SweepModeBit
    Serviceradar.Edge.V1.SweepModeOutcome
    Serviceradar.Edge.V1.SweepResultFormat
    Serviceradar.Edge.V1.TransportProtocol
  )

  @marker "SERVICERADAR EDGE ENUM PARITY"
  @key_clause "def key(tag) when is_integer(tag) and tag < 0, do: tag"
  @value_clause "def value(tag) when is_integer(tag) and tag < 0, do: tag"

  # The generated enum header, pinned shape-exactly. The module name accepts DOTTED segments so a
  # NESTED enum (`Serviceradar.Edge.V1.Msg.State`) is recognised rather than silently skipped.
  @anchor ~r/\Adefmodule (Serviceradar\.Edge\.V1\.[A-Za-z0-9_.]+) do\n  @moduledoc false\n\n  use Protobuf,\n    enum: true,\n    full_name: "[^"]*",\n    protoc_gen_elixir_version: "([^"]*)",\n    syntax: :proto3\n/

  # Any module declaring `enum: true` in its `use Protobuf` statement MUST match @anchor. One that
  # does not is source-shape drift, not something to skip. The check is layout-INDEPENDENT (a
  # single-line `use Protobuf, enum: true, ...` must be caught too), and is scoped to the `use`
  # statement so a MESSAGE module's `field(:x, 1, type: SomeEnum, enum: true)` is not mistaken for
  # an enum declaration.
  @use_statement ~r/^\s*use Protobuf\b/m

  def run([root]) do
    dir = Path.join([root, "edge", "v1"])
    unless File.dir?(dir), do: die("edge binding directory not found: #{dir}")

    # Enumerate EVERY generated edge binding, not a fixed filename list, so a new .proto's output
    # cannot introduce unpatched enums unnoticed.
    files = dir |> Path.join("*.pb.ex") |> Path.wildcard() |> Enum.sort()
    if files == [], do: die("no generated *.pb.ex files found in #{dir}")

    {found, patched_count} =
      Enum.reduce(files, {[], 0}, fn path, {found, patched} ->
        content = File.read!(path)
        {new_content, mods} = patch_file(content, path)
        if new_content != content, do: File.write!(path, new_content)
        {found ++ mods, patched + if(new_content != content, do: 1, else: 0)}
      end)

    verify_inventory(found)

    IO.puts(
      "edge enum parity: #{length(found)} enum modules verified across #{length(files)} file(s), " <>
        "#{patched_count} file(s) patched" <>
        if(patched_count == 0, do: " (already up to date)", else: "")
    )
  end

  def run(_), do: die("usage: elixir scripts/patch_edge_enum_negatives.exs <root-dir>")

  defp patch_file(content, path) do
    segments = split_modules(content)

    {rebuilt, mods} =
      Enum.map_reduce(segments, [], fn segment, mods ->
        case Regex.run(@anchor, segment) do
          [anchor_text, mod, version] ->
            check_generator(mod, version, path)
            {patch_segment(segment, anchor_text, mod, path), [mod | mods]}

          nil ->
            # Not an enum module -- but if it LOOKS like one, the generated shape drifted.
            if declares_enum?(segment) do
              die(
                "source drift in #{path}: a module declares `enum: true` but does not match the " <>
                  "expected generated shape:\n  #{segment |> String.split("\n") |> hd()}"
              )
            end

            {segment, mods}
        end
      end)

    {Enum.join(rebuilt), Enum.reverse(mods)}
  end

  # True when the module's `use Protobuf` STATEMENT declares `enum: true`, whatever its line layout.
  # Scoped to the statement (up to the first blank line, which protoc-gen-elixir always emits after
  # it) so a message module's `field(..., enum: true)` is not misread as an enum declaration.
  defp declares_enum?(segment) do
    case Regex.run(@use_statement, segment, return: :index) do
      [{start, _len}] ->
        statement =
          case :binary.match(segment, "\n\n", scope: {start, byte_size(segment) - start}) do
            {stop, _} -> binary_part(segment, start, stop - start)
            :nomatch -> binary_part(segment, start, byte_size(segment) - start)
          end

        String.contains?(statement, "enum: true")

      nil ->
        false
    end
  end

  # Split on top-level `defmodule ` boundaries, keeping each module (and any leading preamble) as
  # its own segment so every enum is validated and patched INDEPENDENTLY.
  defp split_modules(content) do
    content
    |> String.split(~r/(?=^defmodule )/m)
    |> Enum.reject(&(&1 == ""))
  end

  defp patch_segment(segment, anchor_text, mod, path) do
    markers = count(segment, @marker)
    keys = count(segment, @key_clause)
    values = count(segment, @value_clause)

    cond do
      markers == 0 and keys == 0 and values == 0 ->
        String.replace(segment, anchor_text, anchor_text <> injection(), global: false)

      markers == 1 and keys == 1 and values == 1 ->
        segment

      true ->
        die(
          "PARTIAL PATCH in #{path}: #{mod} has #{markers} marker(s), #{keys} key/1 clause(s) and " <>
            "#{values} value/1 clause(s); expected all 0 (unpatched) or all 1 (patched). " <>
            "Regenerate with `make generate-proto-elixir` rather than hand-editing."
        )
    end
  end

  defp count(haystack, needle), do: haystack |> String.split(needle) |> length() |> Kernel.-(1)

  defp check_generator(mod, version, path) do
    if version != @expected_generator do
      die(
        "generator drift in #{path}: #{mod} declares protoc_gen_elixir_version #{inspect(version)}, " <>
          "expected #{inspect(@expected_generator)}"
      )
    end
  end

  defp injection do
    """

      # #{@marker} (task 1.5) -- injected by scripts/patch_edge_enum_negatives.exs.
      # Go RETAINS an unknown/negative int32 enum as its integer and rejects it in the explicit
      # semantic validator; the generated `key/1`/`value/1` catchalls are guarded `tag >= 0` and
      # would RAISE, making Elixir reject a message Go accepts (last-one-wins: `-1` followed by a
      # valid value has the VALID effective value). Declared in the module BODY on purpose: the
      # Protobuf DSL appends its clauses at `@before_compile`, so these win for negatives while
      # every other tag falls through to the generated clauses unchanged.
      #{@key_clause}
      #{@value_clause}
    """
  end

  defp verify_inventory(found) do
    found = Enum.sort(found)
    expected = Enum.sort(@expected_modules)

    duplicates = found -- Enum.uniq(found)
    if duplicates != [], do: die("duplicate enum module definitions: #{inspect(duplicates)}")

    if found != expected do
      die(
        "edge enum inventory drift.\n" <>
          "  missing (expected but not generated): #{inspect(expected -- found)}\n" <>
          "  unexpected (generated but not in the pinned inventory): #{inspect(found -- expected)}\n" <>
          "  Update @expected_modules in scripts/patch_edge_enum_negatives.exs deliberately."
      )
    end
  end

  defp die(message) do
    IO.puts(:stderr, "patch_edge_enum_negatives: #{message}")
    System.halt(1)
  end
end

PatchEdgeEnumNegatives.run(System.argv())
