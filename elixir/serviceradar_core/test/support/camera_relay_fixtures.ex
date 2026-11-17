defmodule ServiceRadar.Test.CameraRelayFixtures do
  @moduledoc false

  import ExUnit.Assertions

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.IngestOwner
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Repo

  require Ash.Query

  # Only serial, unboxed recording owners use this helper. Generic relay
  # fixtures can run concurrently and must not touch the deployment singleton.
  def preserve_recording_control(stop_origin \\ nil) do
    prior = recording_control_rows()
    origin = if stop_origin, do: Ecto.UUID.dump!(stop_origin)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        [] ->
          Repo.query!(
            "DELETE FROM platform.camera_recording_control WHERE id = 'deployment' AND " <>
              "((NOT stopped AND deployment_ref IS NULL) OR deployment_ref = $1)",
            [origin]
          )

        [[%{"stopped" => false, "deployment_ref" => nil}]] ->
          %{num_rows: deleted} =
            Repo.query!(
              "DELETE FROM platform.camera_recording_control WHERE id = 'deployment' " <>
                "AND stopped AND deployment_ref = $1",
              [origin]
            )

          if deleted == 1 do
            Repo.query!("INSERT INTO platform.camera_recording_control DEFAULT VALUES")
          end

        _ ->
          :ok
      end

      assert recording_control_rows() == prior
    end)

    prior == []
  end

  # Only serial recording owners install deployment state; generic camera
  # fixtures must not open this gate for unrelated tests.
  def recording_recovery_gate(directory) do
    prior = Application.fetch_env(:serviceradar_core, :nvr_recovery_gate)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:serviceradar_core, :nvr_recovery_gate, value)
        :error -> Application.delete_env(:serviceradar_core, :nvr_recovery_gate)
      end
    end)

    path = Path.join(directory, "recovery.json")
    generation = Ecto.UUID.generate()
    ready = ~s({"generation":"#{generation}","state":"ready"})
    File.write!(path, ready)

    {:ok, gate} =
      ServiceRadarRecordingControl.RecoveryGate.load(
        %{
          "SERVICERADAR_NVR_RECOVERY_GENERATION" => generation,
          "SERVICERADAR_NVR_RECOVERY_STATE_FILE" => Path.expand(path)
        },
        nil
      )

    Application.put_env(:serviceradar_core, :nvr_recovery_gate, gate)
    %{path: path, ready: ready}
  end

  def context do
    actor = SystemActor.system(:camera_relay_test)
    key = Ecto.UUID.generate()
    opts = [actor: actor]

    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:relay-example-#{key}",
          vendor: "acme",
          vendor_camera_id: key,
          assigned_agent_id: "agent-example",
          assigned_gateway_id: "gateway-example"
        },
        opts
      )

    ExUnit.Callbacks.on_exit(fn -> cleanup(source.id) end)

    {:ok, profile} =
      StreamProfile.create_profile(%{camera_source_id: source.id, profile_name: "main"}, opts)

    %{source: source, profile: profile, actor: actor, opts: opts}
  end

  def archive_destination(provisioning_ref) do
    %{
      "schema_version" => 1,
      "provisioning_ref" => provisioning_ref,
      "generation" => 1,
      "purpose" => "recording",
      "provider" => "s3_compatible",
      "endpoint" => "https://objects.example.com",
      "region" => "example-region",
      "bucket" => "example-recordings",
      "namespace" => "recordings/v1",
      "archive_format_version" => 1,
      "required_encryption" => "sse_s3_aes256"
    }
  end

  def open(ctx, opts \\ []) do
    defaults = [
      actor: ctx.actor,
      control_gateway_resolver: fn _agent, gateway -> {:ok, gateway} end,
      dispatch_open: fn _agent, _payload, opts, _requester -> {:ok, opts[:command_id]} end
    ]

    RelaySessionManager.request_open(ctx.source.id, ctx.profile.id, Keyword.merge(defaults, opts))
  end

  def activate(ctx, session, ingest_id \\ Ecto.UUID.generate(), attrs \\ %{}) do
    assignment =
      Map.take(session, [:agent_id, :gateway_id, :camera_source_id, :stream_profile_id])

    RelaySessionLifecycle.activate_session(
      session.id,
      ingest_id,
      Map.merge(assignment, attrs_map(attrs)),
      ctx.opts
    )
  end

  def legacy(ctx, attrs \\ %{}) do
    defaults = %{
      camera_source_id: ctx.source.id,
      stream_profile_id: ctx.profile.id,
      agent_id: ctx.source.assigned_agent_id,
      gateway_id: ctx.source.assigned_gateway_id,
      lease_expires_at: DateTime.shift(DateTime.utc_now(), second: 30)
    }

    {:ok, session} = RelaySession.create_session(Map.merge(defaults, attrs_map(attrs)), ctx.opts)

    {:ok, session} =
      RelaySession.activate(session, %{media_ingest_id: Ecto.UUID.generate()}, ctx.opts)

    session
  end

  def owner(ctx) do
    {:ok, owner} =
      IngestOwner
      |> Ash.Query.filter(
        camera_source_id == ^ctx.source.id and stream_profile_id == ^ctx.profile.id
      )
      |> Ash.Query.load(:database_now)
      |> Ash.read_one(ctx.opts)

    owner
  end

  def expire_owner(ctx, owner) do
    owner
    |> Ash.Changeset.for_update(:transition, %{
      lease_expires_at: DateTime.shift(owner.database_now, second: -1)
    })
    |> Ash.update!(ctx.opts)
  end

  def reload(ctx, session), do: RelaySession.get_by_id(session.id, ctx.opts)

  def sessions(ctx) do
    RelaySession |> Ash.Query.filter(camera_source_id == ^ctx.source.id) |> Ash.read!(ctx.opts)
  end

  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp attrs_map(attrs) when is_map(attrs), do: attrs

  defp recording_control_rows do
    Repo.query!(
      "SELECT to_jsonb(control) FROM platform.camera_recording_control AS control WHERE id = 'deployment'"
    ).rows
  end

  @doc "Deletes every camera row hanging off `source_id`, for tests that commit their rows."
  def cleanup(source_id) do
    id = Ecto.UUID.dump!(source_id)

    cleanup_source_access_audits(id)
    cleanup_source_dispositions(id)

    Repo.query!(
      "DELETE FROM platform.camera_recording_holds_versions WHERE version_source_id IN " <>
        "(SELECT id FROM platform.camera_recording_holds WHERE camera_source_id = $1)",
      [id]
    )

    Repo.query!("DELETE FROM platform.camera_recording_holds WHERE camera_source_id = $1", [id])

    Repo.query!(
      "DELETE FROM platform.camera_recording_operations WHERE camera_source_id = $1",
      [id]
    )

    Repo.query!(
      "DELETE FROM platform.camera_recording_catalog WHERE camera_source_id = $1 OR recording_block_id IN " <>
        "(SELECT id FROM platform.camera_recording_blocks WHERE camera_source_id = $1)",
      [id]
    )

    Repo.query!(
      "DELETE FROM platform.camera_recording_gaps WHERE camera_source_id = $1",
      [id]
    )

    Repo.query!(
      "DELETE FROM platform.camera_local_publication_intents WHERE recording_block_id IN " <>
        "(SELECT id FROM platform.camera_recording_blocks WHERE camera_source_id = $1)",
      [id]
    )

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM platform.camera_local_publication_intents WHERE recording_block_id IN " <>
                 "(SELECT id FROM platform.camera_recording_blocks WHERE camera_source_id = $1)",
               [id]
             )

    Repo.query!(
      "DELETE FROM platform.camera_nvr_archive_receipts WHERE recording_block_id IN " <>
        "(SELECT id FROM platform.camera_recording_blocks WHERE camera_source_id = $1)",
      [id]
    )

    Repo.query!("DELETE FROM platform.camera_recording_blocks WHERE camera_source_id = $1", [id])

    Repo.query!(
      "DELETE FROM platform.camera_recorder_claims WHERE ingest_owner_id IN " <>
        "(SELECT id FROM platform.camera_ingest_owners WHERE camera_source_id = $1)",
      [id]
    )

    Repo.query!(
      "DELETE FROM platform.camera_consumer_leases WHERE ingest_owner_id IN " <>
        "(SELECT id FROM platform.camera_ingest_owners WHERE camera_source_id = $1)",
      [id]
    )

    Repo.query!("DELETE FROM platform.camera_ingest_owners WHERE camera_source_id = $1", [id])
    Repo.query!("DELETE FROM platform.camera_relay_sessions WHERE camera_source_id = $1", [id])

    Repo.query!(
      "DELETE FROM platform.camera_recording_policies_versions WHERE version_source_id IN " <>
        "(SELECT id FROM platform.camera_recording_policies WHERE camera_source_id = $1)",
      [id]
    )

    Repo.query!("DELETE FROM platform.camera_recording_policies WHERE camera_source_id = $1", [id])

    Repo.query!("DELETE FROM platform.camera_stream_profiles WHERE camera_source_id = $1", [id])
    Repo.query!("DELETE FROM platform.camera_sources WHERE id = $1", [id])

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM platform.camera_sources WHERE id = $1", [id])
  end

  @doc "Cleans up append-only `camera_recording_dispositions` rows committed by unboxed tests."
  def cleanup_dispositions_by_operation(operation_id) do
    op_bin = Ecto.UUID.dump!(operation_id)

    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.camera_recording_dispositions WHERE operation_id = $1",
        [op_bin]
      )

    if count > 0 do
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!(
            "ALTER TABLE platform.camera_recording_dispositions DISABLE TRIGGER trg_camera_recording_dispositions_append_only"
          )

          Repo.query!(
            "DELETE FROM platform.camera_recording_dispositions WHERE operation_id = $1",
            [op_bin]
          )

          Repo.query!(
            "ALTER TABLE platform.camera_recording_dispositions ENABLE TRIGGER trg_camera_recording_dispositions_append_only"
          )
        end)

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.camera_recording_dispositions WHERE operation_id = $1",
                 [op_bin]
               )
    end
  end

  @doc "Cleans up a camera-less quarantined catalog entry and any attached operations/dispositions."
  def cleanup_quarantined_entry(entry_id) do
    entry_bin = Ecto.UUID.dump!(entry_id)

    %{rows: op_rows} =
      Repo.query!(
        "SELECT DISTINCT operation_id FROM platform.camera_recording_dispositions WHERE catalog_entry_id = $1",
        [entry_bin]
      )

    for [op_bin] <- op_rows do
      cleanup_dispositions_by_operation(Ecto.UUID.load!(op_bin))
    end

    %{rows: [[entry_count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.camera_recording_catalog WHERE id = $1",
        [entry_bin]
      )

    if entry_count > 0 do
      %{rows: [[storage_bin, block_key]]} =
        Repo.query!(
          "SELECT storage_id, block_key FROM platform.camera_recording_catalog WHERE id = $1",
          [entry_bin]
        )

      Repo.query!(
        "DELETE FROM platform.camera_recording_operations WHERE storage_id = $1 AND block_key = $2",
        [storage_bin, block_key]
      )

      Repo.query!("DELETE FROM platform.camera_recording_catalog WHERE id = $1", [entry_bin])
    end

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM platform.camera_recording_catalog WHERE id = $1",
               [entry_bin]
             )
  end

  defp cleanup_source_dispositions(source_id_bin) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM platform.camera_recording_dispositions
        WHERE catalog_entry_id IN (
          SELECT id FROM platform.camera_recording_catalog
          WHERE camera_source_id = $1 OR recording_block_id IN (
            SELECT id FROM platform.camera_recording_blocks WHERE camera_source_id = $1
          )
        )
        """,
        [source_id_bin]
      )

    if count > 0 do
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!(
            "ALTER TABLE platform.camera_recording_dispositions DISABLE TRIGGER trg_camera_recording_dispositions_append_only"
          )

          Repo.query!(
            """
            DELETE FROM platform.camera_recording_dispositions
            WHERE catalog_entry_id IN (
              SELECT id FROM platform.camera_recording_catalog
              WHERE camera_source_id = $1 OR recording_block_id IN (
                SELECT id FROM platform.camera_recording_blocks WHERE camera_source_id = $1
              )
            )
            """,
            [source_id_bin]
          )

          Repo.query!(
            "ALTER TABLE platform.camera_recording_dispositions ENABLE TRIGGER trg_camera_recording_dispositions_append_only"
          )
        end)
    end
  end

  defp cleanup_source_access_audits(source_id_bin) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.camera_recording_access_audits WHERE camera_source_id = $1",
        [source_id_bin]
      )

    if count > 0 do
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!(
            "ALTER TABLE platform.camera_recording_access_audits DISABLE TRIGGER camera_recording_access_audits_append_only_trigger"
          )

          Repo.query!(
            "DELETE FROM platform.camera_recording_access_audits WHERE camera_source_id = $1",
            [source_id_bin]
          )

          Repo.query!(
            "ALTER TABLE platform.camera_recording_access_audits ENABLE TRIGGER camera_recording_access_audits_append_only_trigger"
          )
        end)
    end
  end

  def local_intent(block, operation) do
    descriptor = recording_descriptor(block)
    {:ok, encoded} = ServiceRadarRecordingMetadata.Descriptor.encode(descriptor)

    {:ok, bytes} =
      ServiceRadarRecordingMetadata.LocalPublicationIntent.encode(descriptor, block.storage_id, %{
        operation_id: operation,
        recording_block_id: block.id,
        descriptor_sha256: digest(encoded)
      })

    bytes
  end

  # Invented metadata owns the DB authority contract; the worker keeper freezes
  # real synthetic media through Packaging and Spool.
  def recording_descriptor(block) do
    %{
      "version" => 1,
      "identity" => ServiceRadar.Camera.RecordingBlock.identity(block),
      "format" => %{"codec" => "avc1.42c00a", "timescale" => 90_000},
      "init" => %{"length" => 1, "sha256" => digest("i")},
      "media" => %{"length" => 3, "sha256" => digest("abc")},
      "fragments" => [
        %{
          "sequence" => 0,
          "offset" => 0,
          "length" => 3,
          "start_ns" => 0,
          "duration_ns" => 1_000_000_000,
          "sha256" => digest("abc"),
          "tail_duration_source" => nil,
          "motion" => "unknown"
        }
      ]
    }
  end

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
