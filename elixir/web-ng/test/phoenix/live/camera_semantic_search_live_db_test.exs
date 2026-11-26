defmodule ServiceRadarWebNGWeb.CameraSemanticSearchLiveDBTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RecorderClaim
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Camera.VisualFrame
  alias ServiceRadar.Camera.VisualIndexDispatcher
  alias ServiceRadar.Camera.VisualIndexResultProjector
  alias ServiceRadar.Identity.RBAC.Cache
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Repo
  alias ServiceRadarRecordingControl.RecoveryGate
  alias ServiceRadarRecordingMetadata.Descriptor

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db
  @moduletag :tmp_dir

  @storage_id "00000000-0000-4000-8000-000000000621"

  setup %{tmp_dir: directory} do
    previous_web_opts = Application.get_env(:serviceradar_web_ng, :camera_semantic_search_opts)
    previous_vantage_enabled = Application.get_env(:serviceradar_web_ng, :vantage_rpc_enabled)
    previous_vantage_request_fn = Application.get_env(:serviceradar_web_ng, :vantage_rpc_request_fn)

    Application.delete_env(:serviceradar_web_ng, :camera_semantic_search_opts)
    open_synthetic_recovery_gate!(directory)

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
      user_with_permissions(
        [
          "devices.view",
          "devices.cameras.view",
          "devices.cameras.recordings.view"
        ],
        actor
      )

    {recording_admin, _} =
      user_with_permissions(
        [
          "devices.view",
          "settings.recording.view",
          "settings.recording.manage"
        ],
        actor
      )

    %{viewer: viewer, recording_admin: recording_admin, actor: actor}
  end

  test "disconnected mount on /cameras and /cameras/:id/recordings performs zero camera/visual DB queries",
       %{viewer: viewer, actor: actor} do
    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:synthetic-sem-disc-#{Ecto.UUID.generate()}",
          vendor: "synthetic",
          vendor_camera_id: Ecto.UUID.generate(),
          display_name: "Synthetic Disconnected Search Cam"
        },
        actor: actor
      )

    handler_id = "camera-semantic-disc-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:serviceradar, :repo, :query],
      fn _event, _measurements, metadata, _cfg ->
        query = Map.get(metadata, :query, "")

        if query =~ "camera_" do
          send(test_pid, {:unexpected_camera_query, query})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    fleet_resp = viewer |> authed_conn() |> get(~p"/cameras")
    assert html_response(fleet_resp, 200) =~ "camera-fleet-semantic-search"
    refute_received {:unexpected_camera_query, _}

    tl_resp =
      viewer
      |> authed_conn()
      |> get(
        ~p"/cameras/#{source.id}/recordings?mode=timeline&seek=1700000002000000&highlight_frame=#{Ecto.UUID.generate()}"
      )

    assert html_response(tl_resp, 200) =~ "camera-recordings-loading"
    refute_received {:unexpected_camera_query, _}
  end

  test "fleet search on /cameras renders result cards and embedder-unavailable banner, and deep-links into timeline with seek offset, hit markers, and bbox overlay",
       %{viewer: viewer, actor: actor} do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    ctx = seed_recent_visual_fixture(actor, now)

    Application.put_env(:serviceradar_web_ng, :vantage_rpc_enabled, true)

    # 1. Embedder offline banner on /cameras when the Vantage provider reports it
    Application.put_env(:serviceradar_web_ng, :vantage_rpc_request_fn, fn
      "vantage.rpc.semantic_search.v1", _json, _opts ->
        {:ok, %{body: Jason.encode!(%{"status" => "error", "error" => "search_embedder_unavailable"})}}

      _subject, _json, _opts ->
        {:error, :no_responders}
    end)

    {:ok, fleet_view, _html} = live(authed_conn(viewer), ~p"/cameras")
    assert has_element?(fleet_view, "#camera-fleet-semantic-search")

    fleet_view
    |> form("#camera-fleet-semantic-search-form", %{search: %{q: "person in red dress"}})
    |> render_submit()

    assert has_element?(
             fleet_view,
             "#camera-fleet-semantic-unavailable",
             "Visual search workers unavailable"
           )

    # 2. A Vantage hit renders a clip card with an Open in Timeline deep link
    Application.put_env(:serviceradar_web_ng, :vantage_rpc_request_fn, vantage_stub(ctx))

    fleet_view
    |> form("#camera-fleet-semantic-search-form", %{
      search: %{q: "person in red dress", object_class: "person", range: "1h"}
    })
    |> render_submit()

    assert has_element?(fleet_view, "[data-role='semantic-search-result-card']", "Synthetic Gate 7")
    assert has_element?(fleet_view, "[data-role='open-in-timeline-link']", "Open in Timeline")

    # 3. Deep-linking to /cameras/:id/recordings?mode=timeline&from=...&to=...&seek=...&highlight_frame=...
    from_us = ctx.entry.timeline_start_us
    to_us = ctx.entry.timeline_end_us + 4_000_000
    seek_us = ctx.entry.timeline_start_us + 2_000_000

    {:ok, tl_view, tl_html} =
      live(
        authed_conn(viewer),
        ~p"/cameras/#{ctx.source.id}/recordings?mode=timeline&from=#{from_us}&to=#{to_us}&seek=#{seek_us}&highlight_frame=#{ctx.frame.id}"
      )

    assert has_element?(tl_view, "#camera-timeline-search-form")
    assert has_element?(tl_view, "#camera-timeline-player[data-seek-offset-seconds='2.0']")
    assert has_element?(tl_view, "#camera-timeline-player[data-highlight-frame-id='#{ctx.frame.id}']")
    assert has_element?(tl_view, "[data-role='semantic-bbox-overlay']")
    assert has_element?(tl_view, "[data-role='toggle-bbox-overlay']")
    assert tl_html =~ "person"

    # 4. Submitting inline timeline semantic search populates hit markers on #camera-timeline-coverage-bar
    tl_view
    |> form("#camera-timeline-search-form", %{search: %{q: "person in red dress"}})
    |> render_submit()

    assert has_element?(tl_view, "#camera-timeline-coverage-bar [data-role='semantic-hit-marker']")
    assert has_element?(tl_view, "#camera-timeline-search-results [data-role='timeline-semantic-hit']")
  end

  test "Settings /settings/recording Policy and Health tabs persist visual_index_mode and display VisualIndexJob summary",
       %{recording_admin: admin, actor: actor} do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    ctx = seed_recent_visual_fixture(actor, now)

    {:ok, pol_view, _} = live(authed_conn(admin), ~p"/settings/recording?tab=policy")
    assert has_element?(pol_view, "#policy-visual-index-mode-select")
    assert has_element?(pol_view, "#policy-visual-min-interval-input")
    assert has_element?(pol_view, "#policy-visual-max-frames-input")

    pol_view
    |> element("#edit-policy-#{ctx.policy.id}")
    |> render_click()

    pol_view
    |> form("#recording-policy-form", %{
      policy: %{
        visual_index_mode: "keyframes",
        visual_index_min_interval_ms: "3000",
        visual_index_max_frames_per_block: "48"
      }
    })
    |> render_submit()

    updated =
      CameraRecordingPolicy
      |> Ash.Query.filter(id == ^ctx.policy.id)
      |> Ash.read_one!(actor: actor)

    assert updated.visual_index_mode == :keyframes
    assert updated.visual_index_min_interval_ms == 3000
    assert updated.visual_index_max_frames_per_block == 48

    {:ok, health_view, _} = live(authed_conn(admin), ~p"/settings/recording?tab=health")
    assert has_element?(health_view, "#health-visual-indexing-card")
    assert has_element?(health_view, "#health-visual-indexing-model-badge")
    assert has_element?(health_view, "#health-visual-jobs-completed", "1")
  end

  defp authed_conn(user), do: log_in_user(build_conn(), user)

  defp restore_web_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_web_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)

  # Stands in for the Vantage provider's NATS RPC responder.
  defp vantage_stub(ctx) do
    camera_source_id = to_string(ctx.source.id)
    frame_id = to_string(ctx.frame.id)
    frame_ts_us = ctx.frame.timeline_ts_us

    detection = %{
      "visual_frame_id" => frame_id,
      "timeline_ts_us" => frame_ts_us,
      "bbox" => [0.25, 0.2, 0.55, 0.88],
      "object_class" => "person",
      "score" => 0.94,
      "dominant_colors" => ["red"],
      "time_basis" => "received"
    }

    hit = %{
      "catalog_entry_id" => to_string(ctx.entry.id),
      "visual_frame_id" => frame_id,
      "camera_source_id" => camera_source_id,
      "camera_display_name" => "Synthetic Gate 7",
      "clip_start_us" => ctx.entry.timeline_start_us,
      "clip_end_us" => ctx.entry.timeline_end_us,
      "best_timeline_ts_us" => frame_ts_us,
      "score" => 0.91,
      "object_class" => "person",
      "dominant_colors" => ["red"],
      "time_basis" => "received",
      "frame_detections" => [detection]
    }

    fn
      "vantage.rpc.semantic_search.v1", _json, _opts ->
        {:ok, %{body: Jason.encode!(%{"status" => "ok", "time_basis" => "received", "results" => [hit]})}}

      "vantage.rpc.frame_overlay.v1", _json, _opts ->
        {:ok, %{body: Jason.encode!(%{"status" => "ok", "detections" => [detection]})}}

      _subject, _json, _opts ->
        {:error, :no_responders}
    end
  end

  defp seed_recent_visual_fixture(actor, now) do
    opts = [actor: actor]
    key = Ecto.UUID.generate()
    model_cfg = VisualIndexDispatcher.active_model_config()
    dim = model_cfg.embedding_dim
    block_dt = DateTime.shift(now, second: -30)

    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:synthetic-sem-lv-#{key}",
          vendor: "synthetic",
          vendor_camera_id: key,
          display_name: "Synthetic Gate 7",
          assigned_agent_id: "agent-example",
          assigned_gateway_id: "gateway-example"
        },
        opts
      )

    {:ok, profile} =
      StreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "main-lv",
          codec_hint: "h264",
          relay_eligible: true
        },
        opts
      )

    {:ok, policy} =
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

    block = reserve_block(live_ctx, 0, "epoch-lv-1", opts)

    desc = %{
      "version" => 1,
      "identity" => RecordingBlock.identity(block),
      "format" => %{"codec" => "avc1.42001e", "timescale" => 90_000},
      "init" => %{"length" => byte_size(init_bytes), "sha256" => init_sha},
      "media" => %{"length" => byte_size(frag_bytes) * 2, "sha256" => frag_sha},
      "fragments" => [
        %{
          "sequence" => 0,
          "offset" => 0,
          "length" => byte_size(frag_bytes),
          "start_ns" => 0,
          "duration_ns" => 2_000_000_000,
          "sha256" => frag_sha,
          "tail_duration_source" => nil,
          "motion" => "unknown"
        },
        %{
          "sequence" => 1,
          "offset" => byte_size(frag_bytes),
          "length" => byte_size(frag_bytes),
          "start_ns" => 2_000_000_000,
          "duration_ns" => 2_000_000_000,
          "sha256" => frag_sha,
          "tail_duration_source" => nil,
          "motion" => "unknown"
        }
      ]
    }

    {:ok, entry} =
      RecordingBlocks.freeze_and_catalog(
        live_ctx.owner,
        live_ctx.claim,
        block,
        desc,
        %{first_unit_pts: 0, first_unit_received_at: block_dt, reanchored: false},
        opts
      )

    assert {:ok, _} =
             VisualIndexResultProjector.ingest_result(%{
               "schema" => "media.results.visual_index.v1",
               "schema_version" => 1,
               "catalog_entry_id" => entry.id,
               "descriptor_sha256" => entry.descriptor_sha256,
               "detector_model_id" => model_cfg.detector_model_id,
               "detector_model_version" => model_cfg.detector_model_version,
               "embedder_model_id" => model_cfg.embedder_model_id,
               "embedder_model_version" => model_cfg.embedder_model_version,
               "embedding_dim" => dim,
               "frames" => [
                 %{
                   "fragment_sequence" => 1,
                   "media_pts_ns" => 2_000_000_000,
                   "scene_suppressed" => false,
                   "detections" => [
                     %{
                       "object_class" => "person",
                       "confidence" => 0.94,
                       "bbox" => [0.25, 0.2, 0.55, 0.88],
                       "dominant_colors" => ["red"]
                     }
                   ],
                   "embeddings" => [
                     %{
                       "region_kind" => "crop",
                       "region_index" => 1,
                       "object_class" => "person",
                       "confidence" => 0.94,
                       "bbox" => [0.25, 0.2, 0.55, 0.88],
                       "dominant_colors" => ["red"],
                       "embedding" => basis_vector(dim, 0)
                     }
                   ]
                 }
               ]
             })

    frame =
      VisualFrame
      |> Ash.Query.filter(catalog_entry_id == ^entry.id)
      |> Ash.read_one!(opts)

    %{source: source, profile: profile, policy: policy, entry: entry, frame: frame}
  end

  defp open_synthetic_recovery_gate!(tmp_dir) do
    prior = Application.fetch_env(:serviceradar_core, :nvr_recovery_gate)
    path = Path.join(tmp_dir, "recovery.json")
    generation = Ecto.UUID.generate()
    File.write!(path, ~s({"generation":"#{generation}","state":"ready"}))

    {:ok, gate} =
      RecoveryGate.load(
        %{
          "SERVICERADAR_NVR_RECOVERY_GENERATION" => generation,
          "SERVICERADAR_NVR_RECOVERY_STATE_FILE" => Path.expand(path)
        },
        nil
      )

    Application.put_env(:serviceradar_core, :nvr_recovery_gate, gate)

    on_exit(fn ->
      case prior do
        {:ok, val} -> Application.put_env(:serviceradar_core, :nvr_recovery_gate, val)
        :error -> Application.delete_env(:serviceradar_core, :nvr_recovery_gate)
      end
    end)
  end

  defp basis_vector(dim, hot_idx) do
    for idx <- 0..(dim - 1), do: if(idx == hot_idx, do: 1.0, else: 0.0)
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
      RelaySessionLifecycle.activate_session(session.id, "synth-slv-#{tag}", assignment, opts)

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
        %{name: "Synthetic semantic lv #{Ecto.UUID.generate()}", permissions: permissions},
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
