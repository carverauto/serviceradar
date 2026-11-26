defmodule ServiceRadar.Camera.VantageObservationEnvelopeTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.Validations.VantageCropJpeg
  alias ServiceRadar.Camera.VantageObservation
  alias ServiceRadar.Camera.VantageObservationEnvelope
  alias ServiceRadar.Camera.VantageObservationProjector
  alias ServiceRadar.Camera.VantagePipeline

  @camera_id "11111111-1111-4111-8111-111111111111"
  @profile_id "22222222-2222-4222-8222-222222222222"
  @entry_id "33333333-3333-4333-8333-333333333333"
  @job_id "44444444-4444-7444-8444-444444444444"
  @digest String.duplicate("a", 64)
  @system_actor SystemActor.system(:vantage_envelope_test)

  # Minimal valid Baseline JFIF JPEG: SOI + APP0("JFIF\0") + SOF0 + SOS + EOI
  @valid_jfif <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
                0x00, 0x01, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x10,
                0x01, 0x01, 0x11, 0x00, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F,
                0x00, 0xFF, 0xD9>>

  # Header-only SOI + APP0("JFIF\0") + EOI (no SOF0, no SOS)
  @header_only_jfif <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01, 0x01, 0x00, 0x00,
                      0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9>>

  # Missing SOF0 (SOI + APP0 + SOS + EOI)
  @missing_sof0_jfif <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01, 0x01, 0x00, 0x00,
                       0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00,
                       0x00, 0x3F, 0x00, 0xFF, 0xD9>>

  # SOF2 injected after SOS
  @post_sos_sof2_jfif <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01, 0x01, 0x00, 0x00,
                        0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10,
                        0x00, 0x10, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01,
                        0x00, 0x00, 0x3F, 0x00, 0xFF, 0xC2, 0x00, 0x02, 0xFF, 0xD9>>

  # Progressive SOF2 JPEG (must be rejected)
  @progressive_jfif <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01, 0x01, 0x00, 0x00,
                      0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xC2, 0x00, 0x0B, 0x08, 0x00, 0x10,
                      0x00, 0x10, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xD9>>

  # Missing JFIF APP0 header
  @non_jfif_jpeg <<0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x08, "Exif", 0x00, 0x00, 0xFF, 0xDA, 0x00, 0x02,
                   0xFF, 0xD9>>

  describe "VantageCropJpeg validation" do
    test "accepts nil, Baseline JFIF, and exact 32 KiB boundary while rejecting > 32 KiB and Progressive SOF2" do
      assert {:ok, nil} = VantageCropJpeg.validate_jpeg(nil)
      assert {:ok, @valid_jfif} = VantageCropJpeg.validate_jpeg(@valid_jfif)
      assert VantageCropJpeg.valid_crop_jpeg?(@valid_jfif)

      header = binary_part(@valid_jfif, 0, byte_size(@valid_jfif) - 2)
      pad_len = VantageCropJpeg.max_bytes() - byte_size(@valid_jfif)
      exact_max = header <> :binary.copy(<<0x00>>, pad_len) <> <<0xFF, 0xD9>>
      assert byte_size(exact_max) == 32_768
      assert {:ok, ^exact_max} = VantageCropJpeg.validate_jpeg(exact_max)

      over_max = header <> :binary.copy(<<0x00>>, pad_len + 1) <> <<0xFF, 0xD9>>
      assert byte_size(over_max) == 32_769
      assert {:error, :crop_too_large} = VantageCropJpeg.validate_jpeg(over_max)

      assert {:error, :invalid_crop_jpeg} = VantageCropJpeg.validate_jpeg(@progressive_jfif)
      assert {:error, :invalid_crop_jpeg} = VantageCropJpeg.validate_jpeg(@non_jfif_jpeg)
      assert {:error, :invalid_crop_jpeg} = VantageCropJpeg.validate_jpeg(@header_only_jfif)
      assert {:error, :invalid_crop_jpeg} = VantageCropJpeg.validate_jpeg(@missing_sof0_jfif)
      assert {:error, :invalid_crop_jpeg} = VantageCropJpeg.validate_jpeg(@post_sos_sof2_jfif)
      assert {:error, :invalid_crop_jpeg} = VantageCropJpeg.validate_jpeg("not-a-jpeg")

      # Byte-stuffed 0xFF 0x00 inside entropy scan followed by 0xC2 must still be accepted
      stuffed_entropy =
        binary_part(@valid_jfif, 0, byte_size(@valid_jfif) - 2) <>
          <<0xFF, 0x00, 0xC2, 0xFF, 0xD9>>

      assert {:ok, ^stuffed_entropy} = VantageCropJpeg.validate_jpeg(stuffed_entropy)
    end

    test "enforces crop_jpeg validation on VantageObservation :upsert_observation changeset" do
      base_attrs = %{
        observation_key: "obs:gate-west-01:1",
        pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
        pipeline_version: "1.0.0",
        worker_kind: "camera_vlm",
        model_id: "qwen3.5-4b",
        model_version: "2026.1",
        catalog_entry_id: @entry_id,
        camera_source_id: @camera_id,
        stream_profile_id: @profile_id,
        source_mode: :recorded_block,
        timeline_ts_us: 1_760_000_000_000_000,
        time_basis: :received,
        category: "license_plate",
        label: "SR-0100",
        confidence: 0.94,
        bbox: %{"x1" => 0.32, "y1" => 0.58, "x2" => 0.48, "y2" => 0.66},
        attributes: %{"plate_text" => "SR-0100", "region" => "US-CO"},
        signal_schema_id: "alpr_plate_read",
        signal_schema_version: "1.0.0",
        display_contract_id: "alpr_plate_read"
      }

      ok_cs =
        Ash.Changeset.for_create(
          VantageObservation,
          :upsert_observation,
          Map.put(base_attrs, :crop_jpeg, @valid_jfif),
          actor: @system_actor
        )

      assert ok_cs.valid?, inspect(ok_cs.errors)

      bad_crop_cs =
        Ash.Changeset.for_create(
          VantageObservation,
          :upsert_observation,
          Map.put(base_attrs, :crop_jpeg, @progressive_jfif),
          actor: @system_actor
        )

      refute bad_crop_cs.valid?
      assert Enum.any?(bad_crop_cs.errors, &(&1.field == :crop_jpeg))

      bad_recorded_cs =
        Ash.Changeset.for_create(
          VantageObservation,
          :upsert_observation,
          Map.put(base_attrs, :catalog_entry_id, nil),
          actor: @system_actor
        )

      refute bad_recorded_cs.valid?
      assert Enum.any?(bad_recorded_cs.errors, &(&1.field == :catalog_entry_id))
    end
  end

  describe "VantageObservationEnvelope.validate/1" do
    test "parses valid recorded_block envelope with SR-0100 and normalizes bbox to map" do
      envelope = base_recorded_envelope()

      assert {:ok, identity, {:ok, body}} = VantageObservationEnvelope.validate(envelope)
      assert identity.source_mode == :recorded_block
      assert identity.job_id == @job_id
      assert identity.catalog_entry_id == @entry_id
      assert identity.descriptor_sha256 == @digest
      assert [obs] = body.observations
      assert obs.label == "SR-0100"
      assert obs.bbox == %{"x1" => 0.32, "y1" => 0.58, "x2" => 0.48, "y2" => 0.66}
      assert obs.crop_jpeg == @valid_jfif
      assert obs.search_text =~ "SR-0100"
    end

    test "parses valid live_keyframe_tap envelope with nil job_id and catalog_entry_id" do
      live_envelope = %{
        "schema_version" => "vantage.result.v1",
        "source_mode" => "live_keyframe_tap",
        "job_id" => nil,
        "catalog_entry_id" => nil,
        "descriptor_sha256" => nil,
        "camera_source_id" => @camera_id,
        "stream_profile_id" => @profile_id,
        "pipeline_id" => "io.serviceradar.vantage-bay-guidance.align",
        "pipeline_version" => "1.0.0",
        "worker_kind" => "external_rust",
        "worker_id" => "worker-bay-04",
        "model_id" => "bay-align-onnx",
        "model_version" => "1.0.0",
        "capability" => "vantage.bay_guidance.v1",
        "observations" => [
          %{
            "observation_key" => "live:bay-04:frame:7",
            "frame_sequence" => 7,
            "timeline_ts_us" => 1_760_000_001_000_000,
            "time_basis" => "received",
            "category" => "bay_alignment",
            "label" => "CENTER +0.12m",
            "confidence" => 0.91,
            "bbox" => [0.25, 0.3, 0.75, 0.85],
            "attributes" => %{"lateral_offset_m" => 0.12, "status" => "aligning"},
            "signal_schema_id" => "bay_guidance_vector",
            "signal_schema_version" => "1.0.0"
          }
        ]
      }

      assert {:ok, identity, {:ok, body}} = VantageObservationEnvelope.validate(live_envelope)
      assert identity.source_mode == :live_keyframe_tap
      assert identity.job_id == nil
      assert identity.catalog_entry_id == nil
      assert [obs] = body.observations
      assert obs.fragment_sequence == nil
      assert obs.frame_sequence == 7
    end

    test "retains identity while failing body on invalid bbox or oversized crop_jpeg" do
      bad_bbox =
        put_in(base_recorded_envelope(), ["observations", Access.at(0), "bbox"], [
          0.8,
          0.2,
          0.4,
          0.9
        ])

      assert {:ok, %{job_id: @job_id}, {:error, :invalid_bbox}} =
               VantageObservationEnvelope.validate(bad_bbox)

      header = binary_part(@valid_jfif, 0, byte_size(@valid_jfif) - 2)
      oversized = header <> :binary.copy(<<0x00>>, 33_000) <> <<0xFF, 0xD9>>

      bad_crop =
        put_in(
          base_recorded_envelope(),
          ["observations", Access.at(0), "crop_jpeg_b64"],
          Base.encode64(oversized)
        )

      assert {:ok, %{job_id: @job_id}, {:error, :crop_too_large}} =
               VantageObservationEnvelope.validate(bad_crop)
    end

    test "rejects recorded_block envelope lacking job_id or catalog_entry_id" do
      missing_job = Map.put(base_recorded_envelope(), "job_id", nil)
      assert {:error, :invalid_result_envelope} = VantageObservationEnvelope.validate(missing_job)
    end

    test "recursively rejects :out_of_range inside nested attributes maps and lists" do
      nested_map_oor =
        put_in(base_recorded_envelope(), ["observations", Access.at(0), "attributes"], %{
          "nested" => %{"big" => :out_of_range}
        })

      assert {:ok, %{job_id: @job_id}, {:error, :invalid_result_envelope}} =
               VantageObservationEnvelope.validate(nested_map_oor)

      nested_list_oor =
        put_in(base_recorded_envelope(), ["observations", Access.at(0), "attributes"], %{
          "vals" => [:out_of_range]
        })

      assert {:ok, %{job_id: @job_id}, {:error, :invalid_result_envelope}} =
               VantageObservationEnvelope.validate(nested_list_oor)

      nested_list_map_oor =
        put_in(base_recorded_envelope(), ["observations", Access.at(0), "attributes"], %{
          "items" => [%{"x" => :out_of_range}]
        })

      assert {:ok, %{job_id: @job_id}, {:error, :invalid_result_envelope}} =
               VantageObservationEnvelope.validate(nested_list_map_oor)
    end
  end

  describe "VantageObservationProjector.validate_signal_schema/2" do
    test "validates Draft 2020-12 signal_schema with $defs and fails closed on violations" do
      schema = %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "required" => ["plate_text", "region"],
        "$defs" => %{
          "plate" => %{"type" => "string", "pattern" => "^[A-Z0-9-]{2,12}$"}
        },
        "properties" => %{
          "plate_text" => %{"$ref" => "#/$defs/plate"},
          "region" => %{"type" => "string", "minLength" => 2}
        },
        "additionalProperties" => false
      }

      assert :ok =
               VantageObservationProjector.validate_signal_schema(schema, %{
                 "plate_text" => "TEST-742",
                 "region" => "US-CO"
               })

      assert {:error, :signal_schema_violation} =
               VantageObservationProjector.validate_signal_schema(schema, %{
                 "plate_text" => "invalid plate!",
                 "region" => "US-CO"
               })

      assert {:error, :signal_schema_violation} =
               VantageObservationProjector.validate_signal_schema(schema, %{
                 "plate_text" => "SR-0100"
               })
    end

    test "fails closed immediately on circular $ref chains and rejects them in VantagePipeline changesets" do
      direct_cycle = %{
        "$defs" => %{"a" => %{"$ref" => "#/$defs/a"}},
        "$ref" => "#/$defs/a"
      }

      mutual_cycle = %{
        "$defs" => %{
          "a" => %{"$ref" => "#/$defs/b"},
          "b" => %{"$ref" => "#/$defs/a"}
        },
        "$ref" => "#/$defs/a"
      }

      unresolvable_ref = %{
        "type" => "object",
        "properties" => %{"plate_text" => %{"$ref" => "#/$defs/missing"}}
      }

      for bad_schema <- [direct_cycle, mutual_cycle, unresolvable_ref, "not-a-map"] do
        task =
          Task.async(fn ->
            VantageObservationProjector.validate_signal_schema(bad_schema, %{
              "plate_text" => "SR-0100"
            })
          end)

        assert {:error, :signal_schema_violation} = Task.await(task, 2_000)

        cs =
          Ash.Changeset.for_create(
            VantagePipeline,
            :create,
            %{
              pipeline_id: "io.serviceradar.vantage-alpr.cycle-check",
              version: "1.0.0",
              name: "Cycle Check",
              signal_schema_id: "cycle_test",
              signal_schema_version: "1.0.0",
              signal_schema: bad_schema,
              display_contract_id: "cycle_test"
            },
            actor: @system_actor
          )

        refute cs.valid?
        assert Enum.any?(cs.errors, &(&1.field == :signal_schema))
      end
    end

    test "preserves object property literally named $schema while deleting only top-level $schema" do
      schema = %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "required" => ["$schema"],
        "properties" => %{
          "$schema" => %{"type" => "string"}
        },
        "additionalProperties" => false
      }

      assert :ok =
               VantageObservationProjector.validate_signal_schema(schema, %{"$schema" => "v1"})

      assert {:error, :signal_schema_violation} =
               VantageObservationProjector.validate_signal_schema(schema, %{})

      assert {:error, :signal_schema_violation} =
               VantageObservationProjector.validate_signal_schema(schema, %{"$schema" => 123})

      cs =
        Ash.Changeset.for_create(
          VantagePipeline,
          :create,
          %{
            pipeline_id: "io.serviceradar.vantage-alpr.schema-prop",
            version: "1.0.0",
            name: "Schema Prop",
            signal_schema_id: "schema_prop",
            signal_schema_version: "1.0.0",
            signal_schema: schema,
            display_contract_id: "schema_prop"
          },
          actor: @system_actor
        )

      assert cs.valid?, inspect(cs.errors)
    end
  end

  defp base_recorded_envelope do
    %{
      "schema_version" => "vantage.result.v1",
      "schema" => "media.results.vantage.v1",
      "source_mode" => "recorded_block",
      "job_id" => @job_id,
      "catalog_entry_id" => @entry_id,
      "descriptor_sha256" => @digest,
      "camera_source_id" => @camera_id,
      "stream_profile_id" => @profile_id,
      "pack_id" => "io.serviceradar.vantage-alpr",
      "pipeline_id" => "io.serviceradar.vantage-alpr.vehicle-plate",
      "pipeline_version" => "1.0.0",
      "worker_kind" => "camera_vlm",
      "worker_id" => "media-worker-01",
      "model_id" => "qwen3.5-4b",
      "model_version" => "2026.1",
      "capability" => "vantage.alpr.v1",
      "observations" => [
        %{
          "observation_key" => "obs:gate-west-01:track-1",
          "fragment_sequence" => 1,
          "frame_sequence" => 1,
          "media_pts_ns" => 1_000_000_000,
          "timeline_ts_us" => 1_760_000_000_000_000,
          "time_basis" => "received",
          "track_id" => "1",
          "category" => "license_plate",
          "label" => "SR-0100",
          "confidence" => 0.94,
          "bbox" => [0.32, 0.58, 0.48, 0.66],
          "crop_jpeg_b64" => Base.encode64(@valid_jfif),
          "attributes" => %{"plate_text" => "SR-0100", "region" => "US-CO"},
          "signal_schema_id" => "alpr_plate_read",
          "signal_schema_version" => "1.0.0",
          "display_contract_id" => "alpr_plate_read"
        }
      ]
    }
  end
end
