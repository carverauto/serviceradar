defmodule ServiceRadar.Edge.AckBoundsCorpusTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AckValidate
  alias Serviceradar.Edge.V1.EdgeDeliveryAckV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @manifest Path.join(@testdata, "ack_bounds_corpus.txt")
  @external_resource @manifest

  test "complete raw ACK boundary agrees with the shared Go corpus" do
    rows = rows()

    for row <- rows do
      result = AckValidate.validate_bytes(fixture(row.file), session(row), row.limits)

      if row.accepted do
        assert {:ok, _ack} = result, "#{row.file}: #{inspect(result)}"
      else
        assert {:error, reason} = result, row.file
        refute reason in [:session, :limits], row.file
        refute reason in [{:wire, :not_ready}, {:wire, :systemic}], row.file
        refute match?({:schema_unavailable, _}, reason), row.file

        case row.group do
          "raw" -> assert reason == {:wire, :too_large}, row.file
          "count" -> assert reason == :count, row.file
          "canonical" -> assert reason == :canonical_bytes, row.file
          "code" -> assert reason == :rejection_code, row.file
          _ -> :ok
        end
      end
    end

    assert MapSet.new(rows, & &1.group) ==
             MapSet.new(~w(raw count canonical code semantic policy))

    expected = ~w(raw_128 raw_129 raw_predecode count_2 count_3 canonical_65 canonical_66
      code_empty code_min code_cap code_over code_lower code_punctuation code_alphabet
      accept_control accept_audit accept_quarantine permanent_absent_id spool nonce window prefix sequence
      kind_zero kind_unknown kind_negative event_absent event_mismatch event_short accept_code unknown_outer
      unknown_nested retryable_tail resolve_after_retry missing_sent_event past_highest_sent watermark_regression
      exhausted_empty exhausted_nonempty nonpositive_defaults)

    assert Enum.sort(Enum.map(rows, & &1.file)) ==
             Enum.sort(Enum.map(expected, &("ack_bound_" <> &1 <> ".bin")))
  end

  test "raw, count and canonical groups each isolate their own budget" do
    for row <- rows(),
        row.group in ["raw", "count", "canonical"],
        not String.contains?(row.file, "predecode") do
      raw = fixture(row.file)
      ack = EdgeDeliveryAckV1.decode(raw)
      count = length(ack.dispositions)
      canonical = byte_size(EdgeDeliveryAckV1.encode(ack))

      case row.group do
        "raw" ->
          assert count < row.limits.dispositions and canonical < row.limits.canonical_bytes
          assert byte_size(raw) == row.limits.raw_bytes + if(row.accepted, do: 0, else: 1)

        "count" ->
          assert byte_size(raw) < row.limits.raw_bytes and canonical < row.limits.canonical_bytes
          assert count == row.limits.dispositions + if(row.accepted, do: 0, else: 1)

        "canonical" ->
          assert byte_size(raw) < row.limits.raw_bytes and count < row.limits.dispositions
          assert canonical == row.limits.canonical_bytes + if(row.accepted, do: 0, else: 1)
      end
    end
  end

  test "code length, grammar and non-emptiness have independent controls" do
    for {name, length} <- [
          {"empty", 0},
          {"min", 1},
          {"cap", 64},
          {"over", 65},
          {"lower", 2},
          {"punctuation", 2}
        ] do
      ack = "ack_bound_code_#{name}.bin" |> fixture() |> EdgeDeliveryAckV1.decode()
      assert byte_size(hd(ack.dispositions).rejection_code) == length
    end
  end

  test "caller-shape faults and invalid limits are contained" do
    row = Enum.find(rows(), & &1.accepted)
    raw = fixture(row.file)

    for limits <- [nil, %{raw_bytes: 1.0}, %{raw_bytes: :infinity}, %{misspelled: 10}] do
      assert {:error, :limits} = AckValidate.validate_bytes(raw, session(row), limits)
    end

    for state <- [
          nil,
          %{},
          %{session(row) | resolved_through: -1},
          %{session(row) | highest_sent: 1.0}
        ] do
      assert {:error, :session} = AckValidate.validate_bytes(raw, state, row.limits)
    end

    assert {:error, {:wire, :systemic}} =
             AckValidate.validate_bytes(nil, session(row), row.limits)
  end

  defp session(row) do
    [spool, nonce, first, second, third] =
      "ack_bound_session.txt"
      |> fixture()
      |> String.split()
      |> Enum.map(&Base.decode16!(&1, case: :mixed))

    %{
      spool_id: spool,
      nonce: nonce,
      highest_sent: row.highest,
      resolved_through: row.resolved,
      sent_events: if(row.sent, do: %{1 => first, 2 => second, 3 => third}, else: %{})
    }
  end

  defp rows do
    @manifest
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [file, group, wire, count, canonical, highest, resolved, sent, accepted] =
        String.split(line)

      %{
        file: file,
        group: group,
        limits: %{
          raw_bytes: String.to_integer(wire),
          dispositions: String.to_integer(count),
          canonical_bytes: String.to_integer(canonical)
        },
        highest: String.to_integer(highest),
        resolved: String.to_integer(resolved),
        sent: sent == "1",
        accepted: accepted == "true"
      }
    end)
  end

  defp fixture(name), do: File.read!(Path.join(@testdata, name))
end
