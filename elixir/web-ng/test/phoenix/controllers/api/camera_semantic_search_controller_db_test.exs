defmodule ServiceRadarWebNGWeb.Api.CameraSemanticSearchControllerDBTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RecorderClaim
  alias ServiceRadar.Camera.RecordingAccessAudit
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Identity.RBAC.Cache
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Repo
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures
  alias ServiceRadarRecordingMetadata.Descriptor

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db
  @moduletag :tmp_dir

  @storage_id "00000000-0000-4000-8000-000000000611"
  @base_dt ~U[2026-11-17 12:00:00.000000Z]
  @base_us DateTime.to_unix(@base_dt, :microsecond)

  setup %{conn: conn, tmp_dir: directory} do
    Fixtures.recording_recovery_gate(directory)
    previous_web_opts = Application.get_env(:serviceradar_web_ng, :camera_semantic_search_opts)
    previous_vantage_enabled = Application.get_env(:serviceradar_web_ng, :vantage_rpc_enabled)
    previous_vantage_request_fn = Application.get_env(:serviceradar_web_ng, :vantage_rpc_request_fn)

    Application.delete_env(:serviceradar_web_ng, :camera_semantic_search_opts)

    on_exit(fn ->
      restore_web_env(:vantage_rpc_enabled, previous_vantage_enabled)
      restore_web_env(:vantage_rpc_request_fn, previous_vantage_request_fn)

      if previous_web_opts,
        do: Application.put_env(:serviceradar_web_ng, :camera_semantic_search_opts, previous_web_opts),
        else: Application.delete_env(:serviceradar_web_ng, :camera_semantic_search_opts)
    end)

    actor = system_actor()
    insert_local_storage_binding(@storage_id)

    {viewer, _} =
      user_with_permissions(["devices.view", "devices.cameras.recordings.view"], actor)

    {live_only_user, _} =
      user_with_permissions(["devices.view", "devices.cameras.view"], actor)

    %{
      conn: log_in_user(conn, viewer),
      anon_conn: build_conn(),
      live_only_conn: log_in_user(build_conn(), live_only_user),
      viewer: viewer,
      actor: actor
    }
  end

  test "GET /api/cameras/search enforces RBAC, fails closed without Vantage, forwards only authorized cameras to Vantage, returns timeline_path, writes access audit, and returns 503 when the embedder is unavailable",
       %{
         conn: conn,
         anon_conn: anon_conn,
         live_only_conn: live_only_conn,
         viewer: viewer,
         actor: actor
       } do
    ctx = seed_visual_search_fixture(actor)
    from_us = @base_us - 1_000_000
    to_us = @base_us + 30_000_000

    # 1. Anonymous -> 401; live-stream-only user -> 403 Forbidden
    assert get(anon_conn, ~p"/api/cameras/search?q=person+in+red+dress").status == 401

    denied = get(live_only_conn, ~p"/api/cameras/search?q=person+in+red+dress")
    assert json_response(denied, 403) == %{"error" => "forbidden"}
    assert get_resp_header(denied, "cache-control") == ["private, no-store"]

    # 2. Validation bounds
    bad_q = get(conn, ~p"/api/cameras/search?q=")
    assert bad_q.status == 400

    bad_limit = get(conn, ~p"/api/cameras/search?q=person&limit=99")
    assert json_response(bad_limit, 400) == %{"error" => "invalid_request"}

    # 3. No Vantage provider -> fail closed with 503
    Application.put_env(:serviceradar_web_ng, :vantage_rpc_enabled, false)

    disabled_resp = get(conn, ~p"/api/cameras/search?q=person+in+red+dress")
    assert json_response(disabled_resp, 503) == %{"error" => "semantic_search_unavailable"}

    Application.put_env(:serviceradar_web_ng, :vantage_rpc_enabled, true)

    # 4. Embedder unavailable at the provider -> 503 + Retry-After: 5
    Application.put_env(:serviceradar_web_ng, :vantage_rpc_request_fn, fn
      "vantage.rpc.semantic_search.v1", _json, _opts ->
        {:ok, %{body: Jason.encode!(%{"status" => "error", "error" => "embedder_timeout"})}}
    end)

    unavailable_resp = get(conn, ~p"/api/cameras/search?q=person+in+red+dress")
    assert json_response(unavailable_resp, 503) == %{"error" => "search_embedder_unavailable"}
    assert get_resp_header(unavailable_resp, "retry-after") == ["5"]

    # 5. A provider hit for the authorized camera
    test_pid = self()
    entry = ctx.playable_entry
    best_ts_us = entry.timeline_start_us + 1_000_000
    frame_id = Ecto.UUID.generate()

    Application.put_env(:serviceradar_web_ng, :vantage_rpc_request_fn, fn
      "vantage.rpc.semantic_search.v1", json, _opts ->
        send(test_pid, {:vantage_payload, Jason.decode!(json)})

        {:ok,
         %{
           body:
             Jason.encode!(%{
               "status" => "ok",
               "time_basis" => "received",
               "results" => [
                 %{
                   "catalog_entry_id" => to_string(entry.id),
                   "visual_frame_id" => frame_id,
                   "camera_source_id" => to_string(ctx.source.id),
                   "camera_display_name" => "Synthetic Entry Gate Camera",
                   "clip_start_us" => entry.timeline_start_us,
                   "clip_end_us" => entry.timeline_end_us,
                   "best_timeline_ts_us" => best_ts_us,
                   "score" => 0.93,
                   "object_class" => "person",
                   "dominant_colors" => ["red"],
                   "bbox" => [0.1, 0.1, 0.4, 0.9]
                 }
               ]
             })
         }}
    end)

    resp =
      get(
        conn,
        ~p"/api/cameras/search?q=person+in+red+dress&camera_source_id=#{ctx.source.id}&from=#{from_us}&to=#{to_us}&object_class=person&color=red"
      )

    assert_received {:vantage_payload, payload}
    assert payload["authorized_camera_source_ids"] == [ctx.source.id]

    assert get_resp_header(resp, "cache-control") == ["private, no-store"]
    %{"data" => data} = json_response(resp, 200)
    assert data["query"] == "person in red dress"
    assert data["time_basis"] == "received"
    assert [hit] = data["results"]

    assert hit["camera_source_id"] == ctx.source.id
    assert hit["catalog_entry_id"] == entry.id
    assert hit["object_class"] == "person"
    assert "red" in hit["dominant_colors"]
    assert is_list(hit["bbox"])
    assert hit["timeline_path"] =~ "/cameras/#{ctx.source.id}/recordings?mode=timeline"
    assert hit["timeline_path"] =~ "seek=#{hit["best_timeline_ts_us"]}"
    assert hit["timeline_path"] =~ "highlight_frame=#{hit["visual_frame_id"]}"

    # 6. Append-only RecordingAccessAudit recorded in OSS with event_kind == :semantic_search
    audits =
      RecordingAccessAudit
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(event_kind == :semantic_search and actor_id == ^viewer.id)
      |> Ash.read!(actor: actor)

    assert audits != []
    audit = List.last(audits)
    assert audit.camera_source_id == ctx.source.id
    assert audit.details["query_text"] == "person in red dress"
    assert audit.details["provider"] == "vantage_rpc"
  end

  defp restore_web_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_web_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)

  defp seed_visual_search_fixture(actor) do
    opts = [actor: actor]
    key = Ecto.UUID.generate()

    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:synthetic-sem-api-#{key}",
          vendor: "synthetic",
          vendor_camera_id: key,
          display_name: "Synthetic Entry Gate Camera",
          assigned_agent_id: "agent-example",
          assigned_gateway_id: "gateway-example"
        },
        opts
      )

    {:ok, profile} =
      StreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "main-semantic",
          codec_hint: "h264",
          relay_eligible: true
        },
        opts
      )

    {:ok, _policy} =
      CameraRecordingPolicy
      |> Ash.Changeset.for_create(
        :create,
        %{
          camera_source_id: source.id,
          stream_profile_id: profile.id,
          mode: :continuous,
          nvr_member: "serviceradar-nvr-0",
          storage: :local_only,
          visual_index_mode: :keyframes
        },
        opts
      )
      |> Ash.create(opts)

    live_ctx = open_claim(source, profile, @storage_id, key, opts)
    init_bytes = :binary.copy("init-box", 16)
    init_sha = sha256_hex(init_bytes)
    frag_bytes = :binary.copy("synthetic-fmp4-frag!", 20)
    frag_sha = sha256_hex(frag_bytes)

    block_0 = reserve_block(live_ctx, 0, "epoch-sem-1", opts)
    desc_0 = single_frag_descriptor(block_0, init_bytes, init_sha, frag_bytes, frag_sha, 0)

    {:ok, playable_entry} =
      RecordingBlocks.freeze_and_catalog(
        live_ctx.owner,
        live_ctx.claim,
        block_0,
        desc_0,
        %{first_unit_pts: 0, first_unit_received_at: @base_dt, reanchored: false},
        opts
      )

    # Second block, later reclaimed
    block_1 = reserve_block(live_ctx, 1, "epoch-sem-1", opts)
    desc_1 = single_frag_descriptor(block_1, init_bytes, init_sha, frag_bytes, frag_sha, 4_000_000_000)

    {:ok, reclaimed_entry} =
      RecordingBlocks.freeze_and_catalog(
        live_ctx.owner,
        live_ctx.claim,
        block_1,
        desc_1,
        %{
          first_unit_pts: 360_000,
          first_unit_received_at: DateTime.shift(@base_dt, second: 4),
          reanchored: false
        },
        opts
      )

    reclaimed_entry =
      reclaimed_entry
      |> Ash.Changeset.for_update(
        :transition_local_state,
        %{local_state: :reclaimed, local_state_at: DateTime.utc_now()},
        opts
      )
      |> Ash.update!(opts)

    %{
      source: source,
      playable_entry: playable_entry,
      reclaimed_entry: reclaimed_entry
    }
  end

  defp open_claim(source, profile, storage_id, tag, opts) do
    actor = opts[:actor]

    {:ok, session} =
      RelaySessionManager.request_open(source.id, profile.id,
        actor: actor,
        control_gateway_resolver: fn _agent, gateway -> {:ok, gateway} end,
        dispatch_open: fn _agent, _payload, open_opts, _requester ->
          {:ok, open_opts[:command_id]}
        end
      )

    assignment =
      Map.take(session, [:agent_id, :gateway_id, :camera_source_id, :stream_profile_id])

    {:ok, session} =
      RelaySessionLifecycle.activate_session(session.id, "synth-sa-#{tag}", assignment, opts)

    {:ok, owner} = IngestOwnership.for_relay(session.id, opts)
    claim_token = Ecto.UUID.generate()
    {:ok, consumer} = IngestOwnership.acquire_consumer(owner, :recorder, claim_token, 60_000, opts)

    initial_claim =
      case RecorderClaim
           |> Ash.Query.filter(ingest_owner_id == ^owner.id)
           |> Ash.read_one!(opts) do
        nil ->
          RecorderClaim
          |> Ash.Changeset.for_create(:initialize, %{ingest_owner_id: owner.id}, opts)
          |> Ash.create!(opts)

        existing ->
          existing
      end

    claim =
      initial_claim
      |> Ash.Changeset.for_update(
        :transition,
        %{
          claim_token: claim_token,
          ingest_epoch: owner.epoch,
          recorder_epoch: initial_claim.recorder_epoch + 1,
          next_block_sequence: 4,
          relay_session_id: owner.relay_session_id,
          media_ingest_id: session.media_ingest_id,
          storage_id: storage_id,
          consumer_id: consumer.id,
          lease_expires_at: consumer.expires_at,
          state: :active
        },
        opts
      )
      |> Ash.update!(opts)

    %{owner: owner, claim: claim}
  end

  defp reserve_block(live_ctx, sequence, clock_epoch, opts) do
    clock = %{
      "clock_epoch" => clock_epoch,
      "timebase" => 90_000,
      "dts_source" => "pts_no_reordering",
      "utc_mapping" => "unknown"
    }

    attrs = %{
      camera_source_id: live_ctx.owner.camera_source_id,
      stream_profile_id: live_ctx.owner.stream_profile_id,
      ingest_owner_id: live_ctx.owner.id,
      ingest_epoch: live_ctx.owner.epoch,
      recorder_claim_id: live_ctx.claim.id,
      recorder_epoch: live_ctx.claim.recorder_epoch,
      block_sequence: sequence,
      relay_session_id: live_ctx.claim.relay_session_id,
      media_ingest_id: live_ctx.claim.media_ingest_id,
      storage_id: live_ctx.claim.storage_id,
      clock: clock
    }

    identity = RecordingBlock.identity(attrs)

    RecordingBlock
    |> Ash.Changeset.for_create(
      :reserve,
      Map.put(attrs, :block_key, Descriptor.block_key(identity)),
      opts
    )
    |> Ash.create!(opts)
  end

  defp single_frag_descriptor(block, init_bytes, init_sha, frag_bytes, frag_sha, start_ns) do
    %{
      "version" => 1,
      "identity" => RecordingBlock.identity(block),
      "format" => %{"codec" => "avc1.42001e", "timescale" => 90_000},
      "init" => %{
        "length" => byte_size(init_bytes),
        "sha256" => init_sha
      },
      "media" => %{
        "length" => byte_size(frag_bytes),
        "sha256" => frag_sha
      },
      "fragments" => [
        %{
          "sequence" => 0,
          "offset" => 0,
          "length" => byte_size(frag_bytes),
          "start_ns" => start_ns,
          "duration_ns" => 2_000_000_000,
          "sha256" => frag_sha,
          "tail_duration_source" => nil,
          "motion" => "unknown"
        }
      ]
    }
  end

  defp insert_local_storage_binding(storage_id) do
    now = DateTime.utc_now()

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.camera_local_storage_bindings (
        id, schema_version, storage_id, generation, provider_resource_ref,
        profile_sha256, binding_sha256, provisioned_by, inserted_at
      ) VALUES ($1, 1, $2, 1, $3, $4, $5, 'synthetic-provisioner', $6)
      ON CONFLICT DO NOTHING
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(storage_id),
        "pvc://synthetic-nvr-0",
        sha256_hex("synth-profile-#{storage_id}"),
        sha256_hex("synth-binding-#{storage_id}"),
        now
      ]
    )
  end

  defp user_with_permissions(permissions, actor) do
    user = user_fixture()

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Synthetic semantic api #{Ecto.UUID.generate()}", permissions: permissions},
        actor: actor,
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    user =
      user
      |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: profile.id}, actor: actor)
      |> Ash.update!()

    Cache.put(user.id, MapSet.new(permissions))
    on_exit(fn -> Cache.invalidate(user.id) end)
    {user, profile}
  end

  defp sha256_hex(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
