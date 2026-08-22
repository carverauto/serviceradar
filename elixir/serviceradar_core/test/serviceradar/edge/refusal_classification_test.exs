defmodule ServiceRadar.Edge.RefusalClassificationTest do
  @moduledoc """
  Task 1.5-l: WHAT A REFUSAL IS CALLED, which is what decides RETRYABILITY.

  `:poison` permanently resolves a delivery, `:systemic` pauses, `:not_ready` leaves it
  unresolved. That makes the classification a different question from 1.5-a's, which freezes
  WHETHER bytes are refused and deliberately leaves the naming open: the same malformed bytes
  Go refuses permanently would, if called `:systemic` at a known delivery slot, be RETRYABLE
  FOREVER here. An accept/refuse corpus cannot see that divergence, because neither `:systemic`
  nor `:not_ready` is a refusal at all.

  ## The conservative default, and the residue it leaves

  `MatchError` is classified `:systemic` on purpose. It is genuinely ambiguous -- malformed wire
  OR a codegen/metadata bug -- and a deployment defect must not permanently destroy valid data.
  That choice is right, and it is exactly why the RESIDUE matters: every malformed input that
  reaches the decoder and raises `MatchError` becomes an infinitely retryable delivery.

  The design answer is that malformed bytes are not supposed to reach the decoder at all --
  `WireValidate` is a structural preflight that runs first. This file MEASURES that rather than
  asserting it, and it carries its own POSITIVE CONTROL: the same mutants are driven past the
  preflight, where they DO reach `MatchError`. Zero with the preflight and non-zero without it is
  the pair that shows the preflight is what closes the path, rather than the path having
  quietly become unreachable for some unrelated reason.

  ## The measurement, and how to reproduce it

  Generator: `record.bin`, the committed valid record, mutated by four strategies in equal
  proportion -- a single-bit flip, truncation at a random offset, a single-byte replacement, and
  a single-byte insertion -- drawn from `:rand` seeded `:exsss` with `{1, 5, 11}`. The seed is
  fixed because a fuzz result that cannot be replayed is an anecdote.

  AT 20,000 MUTANTS: 33 reach `MatchError` with the preflight bypassed (~0.165%), and 0 reach it
  with the preflight in place. Everything that survives the preflight and still fails to decode
  raises `Protobuf.DecodeError`, classified `:poison` -- the same permanent refusal Go gives
  those bytes.
  """
  use ExUnit.Case, async: true

  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.Edge.WireValidate

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)

  # Sized from the MEASURED control rate: driving these mutants past the preflight yields
  # MatchError at ~0.165% (33 in 20,000), so this population puts ~17 in the positive control
  # below -- enough that its absence is a signal rather than a small sample.
  @mutants 10_000

  defp testdata_dir do
    cond do
      File.dir?(@testdata) ->
        @testdata

      dir = System.get_env("TEST_SRCDIR") ->
        [System.get_env("TEST_WORKSPACE"), "_main"]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Path.join([dir, &1, "proto/edge/v1/testdata"]))
        |> Enum.find(&File.dir?/1)
        |> case do
          nil -> flunk("shared fixture directory not found under #{@testdata} or TEST_SRCDIR")
          p -> p
        end

      true ->
        flunk("shared fixture directory not found under #{@testdata}")
    end
  end

  defp valid_record_bytes, do: File.read!(Path.join(testdata_dir(), "record.bin"))

  # DETERMINISTIC. A fuzz result that cannot be reproduced is an anecdote: the seed is fixed, so a
  # failure names a specific mutant that can be replayed.
  defp seeded_mutants(bytes, count) do
    :rand.seed(:exsss, {1, 5, 11})
    size = byte_size(bytes)

    Enum.map(1..count, fn _ ->
      case :rand.uniform(4) do
        1 -> flip_bit(bytes, size)
        2 -> truncate(bytes, size)
        3 -> replace_byte(bytes, size)
        4 -> insert_byte(bytes, size)
      end
    end)
  end

  defp flip_bit(bytes, size) do
    at = :rand.uniform(size) - 1
    <<head::binary-size(at), byte, rest::binary>> = bytes
    <<head::binary, Bitwise.bxor(byte, Bitwise.bsl(1, :rand.uniform(8) - 1)), rest::binary>>
  end

  defp truncate(bytes, size), do: binary_part(bytes, 0, :rand.uniform(size) - 1)

  defp replace_byte(bytes, size) do
    at = :rand.uniform(size) - 1
    <<head::binary-size(at), _byte, rest::binary>> = bytes
    <<head::binary, :rand.uniform(256) - 1, rest::binary>>
  end

  defp insert_byte(bytes, size) do
    at = :rand.uniform(size) - 1
    <<head::binary-size(at), rest::binary>> = bytes
    <<head::binary, :rand.uniform(256) - 1, rest::binary>>
  end

  # For ONE mutant: does the preflight stop it, and if not, what does the decoder do?
  #
  # `:bypass` skips the preflight. That is not a second code path under test -- it is the POSITIVE
  # CONTROL, and it is the only thing that makes the real assertion meaningful: without it, a
  # change that made MatchError unreachable for some unrelated reason would leave this file green
  # while proving nothing about the preflight.
  defp outcome(bytes, mode \\ :preflight) do
    case preflight(bytes, mode) do
      {:error, _} ->
        :refused_by_preflight

      :ok ->
        try do
          decoded = Protobuf.decode(bytes, EdgeRecordV1, max_nesting_depth: 10_000)
          if is_struct(decoded, EdgeRecordV1), do: :decoded, else: :not_a_struct
        rescue
          error -> {:raised, error.__struct__, WireDecode.classify(error)}
        catch
          kind, _reason -> {:caught, kind}
        end
    end
  end

  defp preflight(_bytes, :bypass), do: :ok
  defp preflight(bytes, :preflight), do: WireValidate.validate(bytes, EdgeRecordV1)

  describe "the classification table is frozen" do
    test "each exception maps to its declared class" do
      # The three that carry a decision, stated as a table rather than left to be inferred from
      # the implementation's clause order.
      assert WireDecode.classify(%Protobuf.DecodeError{}) == :poison
      assert WireDecode.classify(%MatchError{term: :anything}) == :systemic
      assert WireDecode.classify(%FunctionClauseError{}) == :systemic
    end

    test "an unrecognised exception is systemic, never poison" do
      # FAIL CLOSED TOWARD RETRY, not toward destruction. An exception this classifier has never
      # seen is more likely a defect in this deployment than proof the bytes are bad, and calling
      # it :poison would permanently resolve a delivery on the strength of not recognising
      # something.
      assert WireDecode.classify(%RuntimeError{message: "unknown"}) == :systemic
      assert WireDecode.classify(%ArgumentError{}) == :systemic
    end
  end

  describe "malformed inputs do not reach the ambiguous MatchError path" do
    test "#{@mutants} deterministic mutants, counted" do
      mutants = seeded_mutants(valid_record_bytes(), @mutants)

      tally = Enum.frequencies_by(Enum.map(mutants, &outcome(&1, :preflight)), &tally_key/1)
      control = Enum.frequencies_by(Enum.map(mutants, &outcome(&1, :bypass)), &tally_key/1)

      # THE POSITIVE CONTROL, on the SAME mutants. The ambiguous path must be REACHABLE for
      # "zero" to be a result: driven past the preflight these inputs raise MatchError at ~0.17%.
      # If this ever reads zero, the assertion below has stopped measuring anything and the
      # population or the generator changed underneath it.
      reachable = Map.get(control, {:raised, MatchError}, 0)

      assert reachable > 0,
             "the ambiguous path was not reachable even with the preflight bypassed, so the " <>
               "assertion below proves nothing. Control tally: #{inspect(control)}"

      # NOT VACUOUS. If the preflight refused every mutant, or none of them, this file would
      # report zero MatchErrors while proving nothing about the decoder. Both sides must be
      # exercised for the count below to mean anything.
      refused = Map.get(tally, :refused_by_preflight, 0)
      survived = @mutants - refused

      assert refused > 0, "the preflight refused nothing; the fuzz did not exercise it"

      assert survived > 0,
             "the preflight refused every mutant, so the decoder was never reached and the " <>
               "MatchError count below is vacuous"

      # THE MEASUREMENT. A malformed input that survives the preflight and raises MatchError is
      # classified :systemic, which at a known delivery slot is retryable forever -- the exact
      # divergence from Go this task exists to close.
      match_errors = Map.get(tally, {:raised, MatchError}, 0)

      assert match_errors == 0,
             "#{match_errors} of #{@mutants} mutants reached the ambiguous MatchError path and " <>
               "would be retried forever, where the same bytes are refused permanently in Go. " <>
               "With the preflight bypassed the same mutants reach it #{reachable} times, so " <>
               "the preflight is what closes this. Tally: #{inspect(tally)}"
    end
  end

  defp tally_key({:raised, mod, _class}), do: {:raised, mod}
  defp tally_key({:caught, kind}), do: {:caught, kind}
  defp tally_key(other), do: other
end
