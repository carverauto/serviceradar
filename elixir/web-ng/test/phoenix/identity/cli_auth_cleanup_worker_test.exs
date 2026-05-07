defmodule ServiceRadar.Identity.CliAuthCleanupWorkerTest do
  @moduledoc """
  Integration tests for the daily CLI device-code cleanup worker.

  Covers proposal `add-cli-device-auth` §8.2.

  Run via the srql-fixtures CNPG instance per the
  `.agents/skills/srql-fixtures-db-tests` skill.

  We bypass the worker's `perform/1` reschedule step (which talks to
  Oban) and call the cleanup helpers via `perform_now/0` so the test
  doesn't require an Oban runtime. The proposal §8 spec is about the
  data transitions; scheduling is exercised by the existing
  `ObanEnsureScheduled` GenServer plumbing.
  """
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.CliAuthCleanupWorker
  alias ServiceRadar.Identity.CliSession
  alias ServiceRadar.Identity.DeviceAuthorization
  alias ServiceRadarWebNG.AccountsFixtures

  @moduletag :integration

  describe "perform/1 — pending DeviceAuthorization → :expired" do
    test "rolls a pending row past its expires_at to :expired" do
      row = mint_pending("BCDF-GHJK")
      backdate_device_authorization!(row.id, expires_at_ago: 60)

      run_cleanup!()

      actor = SystemActor.system(:test)
      {:ok, reread} = DeviceAuthorization.get_by_user_code("BCDF-GHJK", actor: actor)
      assert reread.status == :expired
    end

    test "leaves still-valid pending rows alone" do
      row = mint_pending("LMNP-QRST")

      run_cleanup!()

      actor = SystemActor.system(:test)
      {:ok, reread} = DeviceAuthorization.get_by_user_code("LMNP-QRST", actor: actor)
      assert reread.status == :pending
      assert reread.id == row.id
    end
  end

  describe "perform/1 — active CliSession → :expired" do
    test "rolls a session past its JWT expires_at to :expired" do
      user = AccountsFixtures.user_fixture()
      session = mint_session(user, "VWXZ-BCDF")
      backdate_cli_session!(session.jti, expires_at_ago: 60)

      run_cleanup!()

      actor = SystemActor.system(:test)
      {:ok, reread} = CliSession.get_by_jti(session.jti, actor: actor)
      assert reread.status == :expired
    end

    test "leaves still-active sessions alone" do
      user = AccountsFixtures.user_fixture()
      session = mint_session(user, "QRST-VWXZ")

      run_cleanup!()

      actor = SystemActor.system(:test)
      {:ok, reread} = CliSession.get_by_jti(session.jti, actor: actor)
      assert reread.status == :active
    end
  end

  describe "perform/1 — hard-delete old terminal rows" do
    test "destroys DeviceAuthorization rows in terminal status older than the retention window" do
      row = mint_pending("MNPQ-RSTV")
      mark_device_authorization!(row.id, status: :expired, inserted_ago_days: 100)

      run_cleanup!(retention_days: 90)

      assert deleted_device_authorization?(row.id)
    end

    test "keeps DeviceAuthorization rows under the retention window" do
      row = mint_pending("RSTV-WXZB")
      mark_device_authorization!(row.id, status: :expired, inserted_ago_days: 30)

      run_cleanup!(retention_days: 90)

      actor = SystemActor.system(:test)
      {:ok, reread} = DeviceAuthorization.get_by_user_code("RSTV-WXZB", actor: actor)
      assert reread.status == :expired
    end

    test "destroys CliSession rows in terminal status older than the retention window" do
      user = AccountsFixtures.user_fixture()
      session = mint_session(user, "TVWX-ZBCD")
      mark_cli_session!(session.jti, status: :revoked, inserted_ago_days: 100)

      run_cleanup!(retention_days: 90)

      assert deleted_cli_session?(session.jti)
    end

    test "keeps CliSession rows under the retention window" do
      user = AccountsFixtures.user_fixture()
      session = mint_session(user, "WXZB-CDFG")
      mark_cli_session!(session.jti, status: :revoked, inserted_ago_days: 30)

      run_cleanup!(retention_days: 90)

      actor = SystemActor.system(:test)
      {:ok, reread} = CliSession.get_by_jti(session.jti, actor: actor)
      assert reread.status == :revoked
    end
  end

  ## Helpers

  defp run_cleanup!(opts \\ []) do
    retention_days = Keyword.get(opts, :retention_days, 90)

    previous = Application.get_env(:serviceradar_core, CliAuthCleanupWorker)

    Application.put_env(
      :serviceradar_core,
      CliAuthCleanupWorker,
      retention_days: retention_days
    )

    try do
      # perform/1 runs the four cleanup steps and a self-reschedule via
      # ObanSupport.safe_insert. In the test env Oban isn't running; the
      # safe_insert call returns {:error, _} which perform/1 ignores.
      CliAuthCleanupWorker.perform(%Oban.Job{args: %{}})
      :ok
    after
      if previous do
        Application.put_env(
          :serviceradar_core,
          CliAuthCleanupWorker,
          previous
        )
      else
        Application.delete_env(:serviceradar_core, CliAuthCleanupWorker)
      end
    end
  end

  defp mint_pending(user_code) do
    actor = SystemActor.system(:test)

    {:ok, row} =
      DeviceAuthorization.create(
        %{
          device_code_hash: :sha256 |> :crypto.hash(user_code) |> Base.encode16(case: :lower),
          user_code: user_code,
          client_id: "serviceradar-cli",
          scope: "dashboard.publish",
          expires_at: DateTime.add(DateTime.utc_now(), 900, :second),
          interval_seconds: 5
        },
        actor: actor
      )

    row
  end

  defp mint_session(user, user_code) do
    actor = SystemActor.system(:test)
    device_row = mint_pending(user_code)
    {:ok, _approved} = DeviceAuthorization.approve(device_row, user.id, actor: actor)

    {:ok, _jwt, claims} =
      ServiceRadarWebNG.Auth.Guardian.create_api_token(user, scopes: [:read], ttl: {30, :day})

    {:ok, session} =
      CliSession.create(
        %{
          jti: claims["jti"],
          device_authorization_id: device_row.id,
          user_id: user.id,
          client_id: "serviceradar-cli",
          scope: "dashboard.publish",
          issued_at: DateTime.from_unix!(claims["iat"]),
          expires_at: DateTime.from_unix!(claims["exp"])
        },
        actor: actor
      )

    session
  end

  defp backdate_device_authorization!(id, expires_at_ago: seconds) do
    past = DateTime.add(DateTime.utc_now(), -seconds, :second)

    SQL.query!(
      ServiceRadar.Repo,
      "UPDATE platform.device_authorizations SET expires_at = $1 WHERE id = $2",
      [past, Ecto.UUID.dump!(id)]
    )

    :ok
  end

  defp backdate_cli_session!(jti, expires_at_ago: seconds) do
    past = DateTime.add(DateTime.utc_now(), -seconds, :second)

    SQL.query!(
      ServiceRadar.Repo,
      "UPDATE platform.cli_sessions SET expires_at = $1 WHERE jti = $2",
      [past, jti]
    )

    :ok
  end

  defp mark_device_authorization!(id, opts) do
    status = opts |> Keyword.fetch!(:status) |> Atom.to_string()
    inserted_ago_days = Keyword.fetch!(opts, :inserted_ago_days)
    inserted_at = DateTime.add(DateTime.utc_now(), -inserted_ago_days * 86_400, :second)

    SQL.query!(
      ServiceRadar.Repo,
      "UPDATE platform.device_authorizations SET status = $1, inserted_at = $2 WHERE id = $3",
      [status, inserted_at, Ecto.UUID.dump!(id)]
    )

    :ok
  end

  defp mark_cli_session!(jti, opts) do
    status = opts |> Keyword.fetch!(:status) |> Atom.to_string()
    inserted_ago_days = Keyword.fetch!(opts, :inserted_ago_days)
    inserted_at = DateTime.add(DateTime.utc_now(), -inserted_ago_days * 86_400, :second)

    SQL.query!(
      ServiceRadar.Repo,
      "UPDATE platform.cli_sessions SET status = $1, inserted_at = $2 WHERE jti = $3",
      [status, inserted_at, jti]
    )

    :ok
  end

  defp deleted_device_authorization?(id) do
    %{rows: [[count]]} =
      SQL.query!(
        ServiceRadar.Repo,
        "SELECT count(*) FROM platform.device_authorizations WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    count == 0
  end

  defp deleted_cli_session?(jti) do
    %{rows: [[count]]} =
      SQL.query!(
        ServiceRadar.Repo,
        "SELECT count(*) FROM platform.cli_sessions WHERE jti = $1",
        [jti]
      )

    count == 0
  end
end
