defmodule ServiceRadar.Edge.AgentCommandRecordScrubWorkerTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.AgentCommandRecordScrubWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  # Invented credentials: userinfo, an alias token in the path, a query token.
  @leaky_url "rtsps://viewer:hunter2@camera01.example.com:7441/AbCdEf0123TokenXyz?enableSrtp"
  @secrets ["viewer", "hunter2", "AbCdEf0123TokenXyz", "enableSrtp", "lease-invented-01"]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "rewrites rows written before the record policy, once, with the runtime rules" do
    legacy_open =
      insert_legacy_row(
        "camera.open_relay",
        %{
          "source_url" => @leaky_url,
          "lease_token" => "lease-invented-01",
          "relay_session_id" => "r1"
        },
        %{"source_url" => @leaky_url, "relay_session_id" => "r1"},
        ~s(parse rtsp source_url: parse "#{@leaky_url}": invalid port)
      )

    legacy_other =
      insert_legacy_row(
        "future.command",
        %{"stream_url" => "https://viewer:hunter2@downloads.example.com/a.tgz?sig=enableSrtp"},
        %{},
        nil
      )

    clean = insert_legacy_row("test.run", %{"payload" => "ok"}, %{"scope" => "test"}, "done")
    clean_before = row(clean)

    assert AgentCommandRecordScrubWorker.pending() >= 2
    assert {:ok, %{rewritten: rewritten}} = AgentCommandRecordScrubWorker.run(batch_size: 2)
    assert rewritten >= 2

    open = row(legacy_open)
    assert open["payload"]["source_url"] == "rtsps://camera01.example.com:7441/[redacted]"
    assert open["payload"]["lease_token"] == "REDACTED"
    assert open["payload"]["relay_session_id"] == "r1"
    assert open["context"]["source_url"] == "rtsps://camera01.example.com:7441/[redacted]"

    assert open["message"] ==
             ~s(parse rtsp source_url: parse "rtsps://camera01.example.com:7441": invalid port)

    assert row(legacy_other)["payload"] == %{
             "stream_url" => "https://downloads.example.com/a.tgz"
           }

    assert row(clean) == clean_before

    for id <- [legacy_open, legacy_other], secret <- @secrets do
      refute inspect(row(id)) =~ secret
    end

    # Re-running finds nothing left to change and leaves the rows as they are.
    scrubbed = Enum.map([legacy_open, legacy_other], &row/1)
    assert AgentCommandRecordScrubWorker.pending() == 0
    assert {:ok, %{rewritten: 0}} = AgentCommandRecordScrubWorker.run(batch_size: 2)
    assert Enum.map([legacy_open, legacy_other], &row/1) == scrubbed
  end

  test "a concurrent write to message does not stop the payload and context scrub" do
    id =
      insert_legacy_row(
        "camera.open_relay",
        %{"source_url" => @leaky_url, "lease_token" => "lease-invented-01"},
        %{"source_url" => @leaky_url},
        ~s(dial "#{@leaky_url}": connection refused)
      )

    Process.put(:concurrent_message_write, {id, "progress reported by the agent"})

    assert {:ok, %{skipped: skipped}} =
             AgentCommandRecordScrubWorker.run(repo: __MODULE__.ConcurrentWriterRepo)

    assert skipped >= 1

    scrubbed = row(id)
    assert scrubbed["message"] == "progress reported by the agent"
    assert scrubbed["payload"]["source_url"] == "rtsps://camera01.example.com:7441/[redacted]"
    assert scrubbed["payload"]["lease_token"] == "REDACTED"
    assert scrubbed["context"]["source_url"] == "rtsps://camera01.example.com:7441/[redacted]"

    for secret <- @secrets do
      refute inspect(scrubbed) =~ secret
    end
  end

  test "a later pass scrubs a row inserted behind the cursor of an earlier pass" do
    assert {:ok, _} = AgentCommandRecordScrubWorker.run()
    assert AgentCommandRecordScrubWorker.pending() == 0

    behind_cursor =
      insert_legacy_row(
        "camera.open_relay",
        %{"source_url" => @leaky_url, "lease_token" => "lease-invented-01"},
        %{"source_url" => @leaky_url},
        nil,
        lowest_sorting_uuid()
      )

    assert AgentCommandRecordScrubWorker.pending() == 1
    assert AgentCommandRecordScrubWorker.perform(job(1)) == :ok
    assert AgentCommandRecordScrubWorker.pending() == 0

    for secret <- @secrets do
      refute inspect(row(behind_cursor)) =~ secret
    end
  end

  test "the job snoozes while rows remain pending after a pass" do
    insert_dirty_row()
    pending = AgentCommandRecordScrubWorker.pending()
    assert pending >= 1

    assert {:snooze, seconds} =
             AgentCommandRecordScrubWorker.run_pass(1, repo: __MODULE__.LosingWriterRepo)

    assert seconds >= 60
    assert AgentCommandRecordScrubWorker.pending() == pending
  end

  test "the job reports an error with the remaining count when the last pass leaves rows" do
    insert_dirty_row()
    pending = AgentCommandRecordScrubWorker.pending()

    assert {:error, reason} =
             AgentCommandRecordScrubWorker.run_pass(60, repo: __MODULE__.LosingWriterRepo)

    assert reason =~ "#{pending} agent command rows still pending"
  end

  test "the last permitted pass that cleans the remaining rows completes" do
    id = insert_dirty_row()

    assert AgentCommandRecordScrubWorker.perform(job(59)) == :ok
    assert AgentCommandRecordScrubWorker.pending() == 0

    for secret <- @secrets do
      refute inspect(row(id)) =~ secret
    end
  end

  defmodule LosingWriterRepo do
    @moduledoc false
    def query!(sql, params) do
      if String.contains?(sql, "UPDATE platform.agent_commands") do
        %{num_rows: 0}
      else
        Repo.query!(sql, params)
      end
    end
  end

  defmodule ConcurrentWriterRepo do
    @moduledoc false
    def query!(sql, params) do
      case Process.get(:concurrent_message_write) do
        {id, message} ->
          if String.contains?(sql, "UPDATE platform.agent_commands") do
            Process.delete(:concurrent_message_write)

            Repo.query!(
              "UPDATE platform.agent_commands SET message = $2 WHERE command_id = $1::text::uuid",
              [id, message]
            )
          end

        nil ->
          :ok
      end

      Repo.query!(sql, params)
    end
  end

  defp insert_dirty_row do
    insert_legacy_row(
      "camera.open_relay",
      %{"source_url" => @leaky_url, "lease_token" => "lease-invented-01"},
      %{"source_url" => @leaky_url},
      nil
    )
  end

  defp job(snoozed),
    do: %Oban.Job{args: %{"trigger" => "migration"}, meta: %{"snoozed" => snoozed}}

  defp lowest_sorting_uuid do
    <<_::binary-size(8), rest::binary>> = Ecto.UUID.generate()
    "00000000" <> rest
  end

  # A raw insert stands in for a row written before the policy existed; the
  # command bus and the AgentCommand create actions now redact on write.
  defp insert_legacy_row(command_type, payload, context, message, command_id \\ nil) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO platform.agent_commands (
          command_id, command_type, agent_id, partition_id, status, payload, context,
          message, ttl_seconds, expires_at, inserted_at, updated_at
        )
        VALUES (
          COALESCE($5::text::uuid, gen_random_uuid()), $1, 'agent-invented-01', 'default',
          'failed', $2::jsonb, $3::jsonb, $4, 60, now() AT TIME ZONE 'utc',
          now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc'
        )
        RETURNING command_id::text
        """,
        [command_type, payload, context, message, command_id]
      )

    id
  end

  defp row(id) do
    %{columns: columns, rows: [values]} =
      Repo.query!(
        """
        SELECT payload, context, message, failure_reason, result_payload, progress_payload
        FROM platform.agent_commands
        WHERE command_id = $1::text::uuid
        """,
        [id]
      )

    columns |> Enum.zip(values) |> Map.new()
  end
end
