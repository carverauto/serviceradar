defmodule ServiceRadar.Camera.RelaySourceResolverTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.RelaySourceResolver

  # Invented inventory: documentation addresses and made-up ids.
  @assignment_id "6f0c2a52-4f1e-4c1b-9f3e-2b7d6c1a9e01"

  setup do
    %{camera_source_id: Ecto.UUID.generate(), stream_profile_id: Ecto.UUID.generate()}
  end

  describe "resolve_start_payload/2" do
    test "names the discovering assignment and vendor ids, and never sends an address", ctx do
      fetcher =
        fetcher(ctx, %{
          vendor_profile_id: "high",
          rtsp_transport: "tcp",
          codec_hint: "h264",
          container_hint: "annexb",
          metadata: %{"insecure_skip_verify" => true},
          camera_source: %{
            vendor_camera_id: "invented-cam-01",
            discovery_assignment_id: @assignment_id
          }
        })

      assert {:ok, payload} =
               ctx
               |> start_payload()
               |> Map.put(:source_url, "rtsps://192.0.2.10:7441/AbCdEfInvented05")
               |> RelaySourceResolver.resolve_start_payload(camera_profile_fetcher: fetcher)

      assert payload.source_resolver == %{
               plugin_assignment_id: @assignment_id,
               vendor_camera_id: "invented-cam-01",
               vendor_profile_id: "high"
             }

      refute Map.has_key?(payload, :source_url)
      refute inspect(payload) =~ "AbCdEfInvented05"
      assert payload.rtsp_transport == "tcp"
      assert payload.codec_hint == "h264"
      assert payload.container_hint == "annexb"
      assert payload.insecure_skip_verify == true
    end

    test "a profile without a vendor profile id leaves it out of the resolver", ctx do
      fetcher =
        fetcher(ctx, %{
          vendor_profile_id: nil,
          camera_source: %{
            vendor_camera_id: "invented-cam-02",
            discovery_assignment_id: @assignment_id,
            metadata: %{"insecure_skip_verify" => "true"}
          }
        })

      assert {:ok, payload} =
               RelaySourceResolver.resolve_start_payload(start_payload(ctx),
                 camera_profile_fetcher: fetcher
               )

      assert payload.source_resolver == %{
               plugin_assignment_id: @assignment_id,
               vendor_camera_id: "invented-cam-02"
             }

      assert payload.insecure_skip_verify == true
    end

    test "keeps TLS verification enabled without an explicit opt-in", ctx do
      fetcher =
        fetcher(ctx, %{
          metadata: %{"source" => "protect-bootstrap", "insecure_skip_verify" => false},
          camera_source: %{
            vendor_camera_id: "invented-cam-03",
            discovery_assignment_id: @assignment_id,
            metadata: %{"plugin_id" => "unifi-protect-camera"}
          }
        })

      assert {:ok, payload} =
               RelaySourceResolver.resolve_start_payload(start_payload(ctx),
                 camera_profile_fetcher: fetcher
               )

      refute Map.has_key?(payload, :insecure_skip_verify)
    end

    test "a source no plugin assignment is recorded as discovering fails as source_resolver_missing",
         ctx do
      fetcher =
        fetcher(ctx, %{
          vendor_profile_id: "high",
          camera_source: %{vendor_camera_id: "invented-cam-04", discovery_assignment_id: nil}
        })

      assert {:error, "source_resolver_missing"} =
               RelaySourceResolver.resolve_start_payload(start_payload(ctx),
                 camera_profile_fetcher: fetcher
               )
    end

    test "rejects inventory relay for inactive source devices", ctx do
      fetcher =
        fetcher(ctx, %{
          camera_source: %{
            device_uid: "sr:inactive-camera",
            vendor_camera_id: "invented-cam-05",
            discovery_assignment_id: @assignment_id
          }
        })

      assert {:error, "camera source device is inactive"} =
               RelaySourceResolver.resolve_start_payload(start_payload(ctx),
                 camera_profile_fetcher: fetcher,
                 device_lifecycle_active?: fn "sr:inactive-camera" -> false end
               )
    end
  end

  defp start_payload(ctx) do
    %{
      relay_session_id: "relay-1",
      camera_source_id: ctx.camera_source_id,
      stream_profile_id: ctx.stream_profile_id
    }
  end

  defp fetcher(%{camera_source_id: source_id, stream_profile_id: profile_id}, profile) do
    fn ^source_id, ^profile_id -> {:ok, profile} end
  end
end
