defmodule ServiceRadar.Edge.LaneBoundsCorpusTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.LaneValidate
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpen
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpenAck

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @manifest Path.join(@testdata, "lane_bounds_corpus.txt")
  @external_resource @manifest

  test "both handshake halves agree with the shared corpus" do
    names =
      for line <- @manifest |> File.read!() |> String.split("\n", trim: true) do
        [name, req_file, ack_file, accepted] = String.split(line)
        request = req_file |> fixture() |> EdgeRecordLaneOpen.decode()

        result =
          if ack_file == "-" do
            LaneValidate.open(request)
          else
            ack = ack_file |> fixture() |> EdgeRecordLaneOpenAck.decode()
            LaneValidate.open_ack(ack, request)
          end

        if accepted == "true" do
          assert result == :ok, "#{name}: #{inspect(result)}"
        else
          assert {:error, reason} = result, name
          refute match?({:schema_unavailable, _}, reason), name
        end

        name
      end

    assert Enum.sort(names) ==
             Enum.sort(~w(request_control nonce_below nonce_min nonce_max nonce_over
      bytes_zero bytes_cap bytes_over frames_zero frames_cap frames_over spool base unresolved route class unknown
      grant_bytes_equal grant_bytes_inside grant_bytes_zero grant_bytes_over
      grant_frames_equal grant_frames_inside grant_frames_zero grant_frames_over
      ack_spool ack_nonce ack_route ack_class ack_unknown ack_invalid_request))
  end

  test "request literals and independent grant relations are pinned" do
    for {name, field, expected} <- [
          {"bytes_cap", :requested_byte_credits, 1_073_741_824},
          {"bytes_over", :requested_byte_credits, 1_073_741_825},
          {"frames_cap", :requested_frame_credits, 1_048_576},
          {"frames_over", :requested_frame_credits, 1_048_577}
        ] do
      req = "lane_bound_#{name}_request.bin" |> fixture() |> EdgeRecordLaneOpen.decode()
      assert Map.fetch!(req, field) == expected
    end

    for {name, expected} <- [
          {"nonce_below", 15},
          {"nonce_min", 16},
          {"nonce_max", 64},
          {"nonce_over", 65}
        ] do
      req = "lane_bound_#{name}_request.bin" |> fixture() |> EdgeRecordLaneOpen.decode()
      assert byte_size(req.session_nonce) == expected
    end

    for dimension <- ["bytes", "frames"], relation <- ["equal", "inside", "zero", "over"] do
      name = "grant_#{dimension}_#{relation}"
      req = "lane_bound_#{name}_request.bin" |> fixture() |> EdgeRecordLaneOpen.decode()
      ack = "lane_bound_#{name}_ack.bin" |> fixture() |> EdgeRecordLaneOpenAck.decode()
      assert req.requested_byte_credits == 100 and req.requested_frame_credits == 10

      {granted, requested} =
        if dimension == "bytes" do
          assert ack.granted_frame_credits == 5
          {ack.granted_byte_credits, req.requested_byte_credits}
        else
          assert ack.granted_byte_credits == 50
          {ack.granted_frame_credits, req.requested_frame_credits}
        end

      case relation do
        "equal" -> assert granted == requested
        "inside" -> assert granted > 0 and granted < requested
        "zero" -> assert granted == 0
        "over" -> assert granted == requested + 1
      end
    end
  end

  test "malformed decoded requests cannot raise or bypass integer domains" do
    req = "lane_bound_request_control_request.bin" |> fixture() |> EdgeRecordLaneOpen.decode()

    for bad <- [
          nil,
          %{},
          Map.delete(req, :session_nonce),
          %{req | requested_byte_credits: 1.0},
          %{req | requested_frame_credits: :bad},
          %{req | session_nonce: nil},
          %{req | first_unresolved_sequence: 18_446_744_073_709_551_616},
          %{req | sequence_base: 1.0}
        ] do
      assert {:error, _} = LaneValidate.open(bad)
    end
  end

  defp fixture(name), do: File.read!(Path.join(@testdata, name))
end
