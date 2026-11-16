defmodule ServiceRadarWebNGWeb.Settings.RecordingLiveDBTest do
  @moduledoc """
  Database-backed LiveView regression coverage for `/settings/recording`
  exercising `ServiceRadarWebNG.CameraRecordingSettings` against real Ash and
  Postgres queries without `recording_deps` stubs.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Camera.ArchiveDestinations
  alias ServiceRadar.Camera.IngestOwner
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecorderClaim
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Credentials.CredentialSecretBuilder
  alias ServiceRadar.Credentials.NativeDescriptors
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.CameraRecordingSettings

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db

  @storage_id "00000000-0000-4000-8000-000000000041"

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    actor = system_actor()

    %{
      conn: log_in_user(conn, user),
      user: user,
      scope: Scope.for_user(user),
      actor: actor
    }
  end

  test "selecting a camera source and stream profile loads relay-eligible profiles, receipts, and paged blocks without stubs",
       %{conn: conn, scope: scope, actor: actor} do
    fixture = create_camera_with_profiles_and_blocks(actor, 26)

    assert [returned_profile] =
             CameraRecordingSettings.list_relay_profiles(scope, fixture.source.id)

    assert returned_profile.id == fixture.eligible_profile.id

    {:ok, view, _html} = live(conn, ~p"/settings/recording?tab=cameras")

    assert has_element?(view, "#recording-camera-picker-form")

    assert has_element?(
             view,
             "#recording-camera-select option[value='#{fixture.source.id}']"
           )

    view
    |> element("#recording-camera-picker-form")
    |> render_change(%{"camera_source_id" => fixture.source.id})

    assert has_element?(
             view,
             "#recording-profile-select option[value='#{fixture.eligible_profile.id}']"
           )

    refute has_element?(
             view,
             "#recording-profile-select option[value='#{fixture.ineligible_profile.id}']"
           )

    assert has_element?(view, "#camera-recording-blocks-section")
    assert has_element?(view, "#next-camera-blocks-page")
    assert has_element?(view, "#block-inserted-#{fixture.receipt_block_id}")
    assert render(view) =~ "version synth-ver-db-01"

    # Filtering by the relay-eligible stream profile exercises Enum.any?/2 on real StreamProfile structs.
    view
    |> element("#recording-camera-picker-form")
    |> render_change(%{
      "camera_source_id" => fixture.source.id,
      "stream_profile_id" => fixture.eligible_profile.id
    })

    assert has_element?(
             view,
             "#recording-profile-select option[value='#{fixture.eligible_profile.id}'][selected]"
           )

    # Reset profile filter and advance keyset page against real RecordingBlocks.operator_page/3.
    view
    |> element("#recording-camera-picker-form")
    |> render_change(%{"camera_source_id" => fixture.source.id, "stream_profile_id" => ""})

    assert has_element?(view, "#next-camera-blocks-page")

    view
    |> element("#next-camera-blocks-page")
    |> render_click()

    refute has_element?(view, "#next-camera-blocks-page")
    assert has_element?(view, "#block-inserted-#{fixture.oldest_block_id}")
  end

  test "archive tab registers an operator destination and saves active archive settings against Postgres without stubs",
       %{conn: conn, scope: scope, actor: actor} do
    writer_secret = create_synthetic_s3_secret(actor, "Synthetic Archive Writer")
    slug = "synthetic-#{System.unique_integer([:positive])}"

    {:ok, view, html} = live(conn, ~p"/settings/recording?tab=archive")

    assert has_element?(view, "#register-archive-destination-form")
    assert html =~ "Local only: no object storage configured"

    {:ok, retention_view, _retention_html} = live(conn, ~p"/settings/recording?tab=retention")
    assert has_element?(retention_view, "#recording-retention-blocked-panel")

    view
    |> element("#register-archive-destination-form")
    |> render_submit(%{
      "destination" => %{
        "name" => slug,
        "endpoint" => "https://objects.example.com",
        "region" => "example-1",
        "bucket" => "synthetic-archive",
        "namespace" => "recordings/v1"
      }
    })

    bindings = CameraRecordingSettings.list_archive_bindings(scope)
    binding = Enum.find(bindings, &(&1.provisioning_ref == "operator:#{slug}"))
    assert binding
    assert binding.generation == 1
    assert has_element?(view, "#archive-binding-#{binding.id}")

    view
    |> element("#recording-archive-settings-form")
    |> render_submit(%{
      "settings" => %{
        "active_archive_binding_id" => binding.id,
        "archive_enabled" => "true",
        "writer_credential_secret_id" => writer_secret.id,
        "reader_credential_secret_id" => ""
      }
    })

    overview = CameraRecordingSettings.load_archive_settings_view(scope)
    assert overview.storage_mode == :local_and_archive
    assert overview.active_binding_id == binding.id
    assert overview.form["archive_enabled"] == "true"
    assert overview.selected_writer_label == writer_secret.name
    refute has_element?(view, "#archive-local-only-banner")
  end

  defp create_camera_with_profiles_and_blocks(actor, total_blocks) do
    opts = [actor: actor]
    key = Ecto.UUID.generate()

    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:synthetic-cam-#{key}",
          vendor: "synthetic",
          vendor_camera_id: key,
          display_name: "Synthetic Yard Camera #{System.unique_integer([:positive])}",
          assigned_agent_id: "agent-example",
          assigned_gateway_id: "gateway-example"
        },
        opts
      )

    {:ok, eligible_profile} =
      StreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "main-eligible",
          codec_hint: "h264",
          relay_eligible: true
        },
        opts
      )

    {:ok, ineligible_profile} =
      StreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "aux-disabled",
          codec_hint: "mjpeg",
          relay_eligible: false
        },
        opts
      )

    {:ok, session} =
      RelaySessionManager.request_open(source.id, eligible_profile.id,
        actor: actor,
        control_gateway_resolver: fn _agent, gateway -> {:ok, gateway} end,
        dispatch_open: fn _agent, _payload, open_opts, _requester -> {:ok, open_opts[:command_id]} end
      )

    assignment =
      Map.take(session, [:agent_id, :gateway_id, :camera_source_id, :stream_profile_id])

    {:ok, session} =
      RelaySessionLifecycle.activate_session(
        session.id,
        "synthetic-ingest-#{key}",
        assignment,
        opts
      )

    {:ok, owner} =
      IngestOwner
      |> Ash.Query.filter(camera_source_id == ^source.id and stream_profile_id == ^eligible_profile.id)
      |> Ash.read_one(opts)

    claim =
      RecorderClaim
      |> Ash.Changeset.for_create(:initialize, %{ingest_owner_id: owner.id}, opts)
      |> Ash.create!(opts)

    inserted =
      for seq <- 0..(total_blocks - 1) do
        insert_synthetic_block(source.id, eligible_profile.id, owner, session, claim.id, seq)
      end

    oldest = hd(inserted)
    newest = List.last(inserted)

    {:ok, binding} =
      ArchiveDestinations.register_operator(
        %{
          name: "cam-receipt-#{System.unique_integer([:positive])}",
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-cam-archive",
          namespace: "recordings/v1"
        },
        opts
      )

    object_sha = Base.encode16(:crypto.hash(:sha256, "synthetic-fmp4-payload"), case: :lower)

    receipt_bytes =
      Jason.encode!(%{
        "version" => 2,
        "storage_id" => @storage_id,
        "block_key" => newest.block_key,
        "destination_sha256" => binding.destination_sha256,
        "verified_at_ms" => 1_763_200_010_000,
        "objects" => [
          %{
            "name" => "media.fmp4",
            "key" => "recordings/v1/#{@storage_id}/#{newest.block_key}/media.fmp4",
            "length" => 4096,
            "sha256" => object_sha,
            "etag" => "\"synthetic-etag-1\"",
            "version_id" => "synth-ver-db-01"
          }
        ]
      })

    {:ok, _receipt} =
      NVRArchiveReceipt.record(
        binding.id,
        receipt_bytes,
        %{recording_block_id: newest.id},
        actor: actor
      )

    %{
      source: source,
      eligible_profile: eligible_profile,
      ineligible_profile: ineligible_profile,
      oldest_block_id: oldest.id,
      receipt_block_id: newest.id
    }
  end

  defp insert_synthetic_block(source_id, profile_id, owner, session, claim_id, sequence) do
    block_id = Ash.UUIDv7.generate()

    block_key =
      :sha256
      |> :crypto.hash("synthetic-web-ng-block:#{claim_id}:#{sequence}")
      |> Base.encode16(case: :lower)

    inserted_at = DateTime.shift(~U[2026-11-15 12:00:00.000000Z], second: sequence)

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.camera_recording_blocks (
        id, block_key, camera_source_id, stream_profile_id, ingest_owner_id, ingest_epoch,
        recorder_claim_id, recorder_epoch, block_sequence, relay_session_id, media_ingest_id,
        storage_id, clock, state, upload_epoch, inserted_at, updated_at
      ) VALUES (
        $1, $2, $3, $4, $5, $6,
        $7, 1, $8, $9, $10,
        $11, $12::jsonb, 'open_local', 0, $13, $13
      )
      """,
      [
        Ecto.UUID.dump!(block_id),
        block_key,
        Ecto.UUID.dump!(source_id),
        Ecto.UUID.dump!(profile_id),
        Ecto.UUID.dump!(owner.id),
        owner.epoch,
        Ecto.UUID.dump!(claim_id),
        sequence,
        Ecto.UUID.dump!(session.id),
        session.media_ingest_id,
        Ecto.UUID.dump!(@storage_id),
        %{"timescale" => 90_000},
        inserted_at
      ]
    )

    %{id: block_id, block_key: block_key}
  end

  defp create_synthetic_s3_secret(actor, prefix) do
    {:ok, built} =
      CredentialSecretBuilder.build(
        NativeDescriptors.s3_compatible(),
        "access_key",
        %{
          "access_key_id" => "SYNTHETICACCESSKEY02",
          "secret_access_key" => String.duplicate("s", 32)
        },
        %{name: "#{prefix} #{System.unique_integer([:positive])}"}
      )

    NetworkCredentialSecret.create_secret!(built, actor: actor)
  end
end
