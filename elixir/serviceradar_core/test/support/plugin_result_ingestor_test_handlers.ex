defmodule ServiceRadar.Observability.PluginResultIngestorTest.FailingHandler do
  @moduledoc false

  def supports?(_payload, _status), do: true

  def ingest(payload, _status, _opts) do
    notify_test({:failing_handler_ingest, payload})
    {:error, :forced_failure}
  end

  defp notify_test(message) do
    if pid = Application.get_env(:serviceradar_core, :plugin_result_ingestor_test_pid) do
      send(pid, message)
    end
  end
end

defmodule ServiceRadar.Observability.PluginResultIngestorTest.SuccessfulHandler do
  @moduledoc false

  def supports?(_payload, _status), do: true

  def ingest(payload, _status, _opts) do
    if pid = Application.get_env(:serviceradar_core, :plugin_result_ingestor_test_pid) do
      send(pid, {:successful_handler_ingest, payload})
    end

    :ok
  end
end

defmodule ServiceRadar.Observability.PluginResultIngestorTest.RaisingSupportHandler do
  @moduledoc false

  def supports?(_payload, _status) do
    raise "support check failed api_token: \"do-not-persist\""
  end

  def ingest(_payload, _status, _opts) do
    send(
      Application.fetch_env!(:serviceradar_core, :plugin_result_ingestor_test_pid),
      :unexpected_support_handler_ingest
    )

    :ok
  end
end

defmodule ServiceRadar.Observability.PluginResultIngestorTest.LongErrorHandler do
  @moduledoc false

  def supports?(_payload), do: true

  def ingest(_payload, _status, _opts) do
    {:error,
     %{
       api_token: "do-not-persist",
       bearer: "bearer-structured-secret",
       credential: "credential-structured-secret",
       privateKey: "private-key-structured-secret",
       token: "bare-token-structured-secret",
       detail:
         "Authorization: Bearer bearer-text-secret " <>
           "token=bare-token-text-secret credential 'credential-text-secret' " <>
           "private_key=private-key-text-secret " <>
           "-----BEGIN PRIVATE KEY-----pem-text-secret-----END PRIVATE KEY----- " <>
           String.duplicate("x", 2_000)
     }}
  end
end

defmodule ServiceRadar.Observability.PluginResultIngestorTest.ReplayHandler do
  @moduledoc false

  @outcomes_key {__MODULE__, :outcomes}

  def put_outcomes(outcomes), do: Process.put(@outcomes_key, outcomes)

  def supports?(_payload, _status), do: true

  def ingest(_payload, _status, _opts) do
    case Process.get(@outcomes_key, []) do
      [outcome | rest] ->
        Process.put(@outcomes_key, rest)
        outcome

      [] ->
        :ok
    end
  end
end

defmodule ServiceRadar.Observability.PluginResultIngestorTest.SecondaryReplayHandler do
  @moduledoc false

  @outcomes_key {__MODULE__, :outcomes}

  def put_outcomes(outcomes), do: Process.put(@outcomes_key, outcomes)

  def supports?(_payload, _status), do: true

  def ingest(_payload, _status, _opts) do
    case Process.get(@outcomes_key, []) do
      [outcome | rest] ->
        Process.put(@outcomes_key, rest)
        outcome

      [] ->
        :ok
    end
  end
end

defmodule ServiceRadar.Observability.PluginResultIngestorTest.TextErrorHandler do
  @moduledoc false

  def supports?(_payload, _status), do: true

  def ingest(_payload, _status, _opts) do
    {:error,
     "Authorization: Bearer bearer-text-secret " <>
       "token=bare-token-text-secret credential 'credential-text-secret' " <>
       "private_key=private-key-text-secret " <>
       "-----BEGIN PRIVATE KEY-----pem-text-secret-----END PRIVATE KEY-----"}
  end
end

defmodule ServiceRadar.Observability.PluginResultIngestorTest.SensitiveCredentialHandler do
  @moduledoc false

  def supports?(_payload, _status), do: true

  def ingest(_payload, _status, _opts) do
    private_key_begin = "-----BEGIN " <> "PRIVATE KEY-----\n"
    private_key_end = "\n-----END " <> "PRIVATE KEY-----"
    rsa_private_key_begin = "-----BEGIN RSA " <> "PRIVATE KEY-----\n"

    {:error,
     %{
       detail:
         "Authorization: Basic basic-auth-secret\n" <>
           private_key_begin <>
           String.duplicate("long-pem-secret-", 100) <>
           private_key_end,
       unterminated:
         rsa_private_key_begin <>
           String.duplicate("unterminated-pem-secret-", 100)
     }}
  end
end

defmodule ServiceRadar.Observability.PluginResultIngestorTest.ThrowingHandler do
  @moduledoc false

  def supports?(_payload, _status), do: true
  def ingest(_payload, _status, _opts), do: throw({:token, "throw-token-secret"})
end

defmodule ServiceRadar.Observability.PluginResultIngestorTest.ExitingHandler do
  @moduledoc false

  def supports?(_payload, _status), do: true
  def ingest(_payload, _status, _opts), do: exit({:credential, "exit-credential-secret"})
end

defmodule ServiceRadar.Observability.PluginResultIngestorTest.RejectingStateRegistry do
  @moduledoc false

  def upsert_from_status_strict(_status) do
    {:error,
     %{
       credential: "state-credential-secret",
       private_key: "state-private-key-secret",
       token: "state-token-secret"
     }}
  end
end

defmodule ServiceRadar.Observability.PluginResultIngestorTest.AcceptingStateRegistry do
  @moduledoc false

  def upsert_from_status_strict_with_notifications(_status), do: {:ok, [], []}
end
