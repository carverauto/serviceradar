defmodule ServiceRadar.Logging.SecretRedactionTest do
  # Installs a global :logger handler, so it cannot share the VM with other
  # tests' log assertions.
  use ExUnit.Case, async: false

  alias ServiceRadar.Logging.SecretRedaction

  @moduletag :capture_log

  # Every value below is invented. The struct mirrors the shape of a TURN
  # client after a failed allocation: a long-term-credential password, the
  # HMAC key derived from it, and a pending STUN request carrying the key in
  # its `integrity` field. The ICE map mirrors an ICE agent's passwords.
  @password "synthetic-turn-password-0001"
  @local_pwd "synthetic-ice-local-pwd-0002"
  @remote_pwd "synthetic-ice-remote-pwd-0003"
  @hmac_key :crypto.hash(:md5, "1700000000:synthetic-user:realm.example.com:" <> @password)
  # Other credential-shaped fields a crashing process can hold.
  @other_credentials %{
    seed: "synthetic-seed-value-0004",
    user_seed: "synthetic-user-seed-0005",
    nkey: "synthetic-nkey-value-0006",
    bearer: "synthetic-bearer-value-0007",
    credentials: "synthetic-credentials-0008",
    credential: "synthetic-credential-0009",
    integrity: "synthetic-mac-value-0010",
    message_integrity: <<251, 7, 133, 64, 18, 222>>
  }

  defmodule TurnClient do
    @moduledoc false
    defstruct [:username, :password, :realm, :nonce, :key, :state, transactions: %{}]
  end

  defmodule CrashingServer do
    @moduledoc false
    use GenServer

    # The reply is kept in the state so the failing match is decided at run
    # time, as it is in the TURN client, rather than flagged by the compiler.
    def init(client), do: {:ok, %{client: client, reply: {:ok, client}}}

    def handle_info(:crash, state) do
      # The same failure shape as a TURN client in :error: a hard match on a
      # return value that carries the whole client.
      {:send, _addr, _data, _client} = state.reply
      {:noreply, state}
    end
  end

  defmodule ForwardingHandler do
    @moduledoc false
    # Stands in for the OTLP log handler: it receives the event after the
    # handler-scoped filters ran, exactly as the exporter would.
    def log(event, %{config: %{test_pid: test_pid}}), do: send(test_pid, {:handled, event})
  end

  defp turn_client do
    %TurnClient{
      username: "1700000000:synthetic-user",
      password: @password,
      realm: "realm.example.com",
      nonce: "synthetic-nonce",
      key: @hmac_key,
      state: :error,
      transactions: %{
        1 => %{method: :channel_bind, integrity: {true, @hmac_key}},
        2 => %{ice: %{local_pwd: @local_pwd, remote_pwd: @remote_pwd}},
        3 => @other_credentials
      }
    }
  end

  # The key as each renderer prints its leading bytes: `<<203, 17, 254` from
  # inspect/2, `<<203,17,254` from io_lib.
  defp key_renderings do
    [a, b, c | _] = :binary.bin_to_list(@hmac_key)
    ["#{a}, #{b}, #{c}", "#{a},#{b},#{c}"]
  end

  # Prefixes, so a value that a depth-limited renderer cut short still counts.
  defp assert_no_credentials(text) do
    secrets = [
      "synthetic-turn-pa",
      "synthetic-ice-lo",
      "synthetic-ice-re",
      "synthetic-seed",
      "synthetic-user-seed",
      "synthetic-nkey",
      "synthetic-bearer",
      "synthetic-credential",
      "synthetic-mac",
      "251, 7, 133",
      "251,7,133" | key_renderings()
    ]

    for secret <- secrets do
      refute text =~ secret, "#{inspect(secret)} survived redaction in:\n#{text}"
    end
  end

  describe "a crashed process's log event" do
    setup do
      handler = :"secret_redaction_test_#{System.unique_integer([:positive])}"

      :ok =
        :logger.add_handler(handler, ForwardingHandler, %{
          level: :all,
          filter_default: :log,
          filters: [redact_secrets: {&SecretRedaction.filter/2, :no_arg}],
          config: %{test_pid: self()}
        })

      on_exit(fn -> :logger.remove_handler(handler) end)
    end

    test "reaches the OTLP export with no credential in its body or attributes" do
      {:ok, pid} = GenServer.start(CrashingServer, turn_client())
      send(pid, :crash)

      event = receive_crash_report(pid)

      exported =
        %{undefined: [event]}
        |> :otel_exporter_logs_otlp.prepare_logs_for_export()
        |> :otel_otlp_logs.to_proto(:otel_resource.create(%{}), %{})

      rendered = inspect(exported, limit: :infinity, printable_limit: :infinity)

      assert_no_credentials(rendered)
      assert rendered =~ "[REDACTED]"
      # The crash itself is still readable.
      assert rendered =~ "MatchError"
      assert rendered =~ "realm.example.com"
    end
  end

  defp receive_crash_report(pid) do
    receive do
      {:handled, %{meta: %{crash_reason: _}, msg: {:report, %{elixir_translation: _}}} = event} ->
        if event.meta[:pid] == pid, do: event, else: receive_crash_report(pid)

      {:handled, _other} ->
        receive_crash_report(pid)
    after
      5_000 -> flunk("no crash report was logged for #{inspect(pid)}")
    end
  end

  describe "redact_text/1" do
    test "removes credentials from every rendering of a credential-holding term" do
      term = {:badmatch, {:ok, turn_client()}}

      renderings = %{
        "inspect" => inspect(term, limit: :infinity),
        "inspect pretty" => inspect(term, pretty: true, limit: :infinity),
        "erlang ~p" => IO.chardata_to_string(:io_lib.format(~c"~p", [term])),
        "erlang ~0tp" => IO.chardata_to_string(:io_lib.format(~c"~0tp", [term])),
        "erlang ~P depth-limited" => IO.chardata_to_string(:io_lib.format(~c"~P", [term, 12])),
        "erlang ~0tp of a credentials map" =>
          IO.chardata_to_string(
            :io_lib.format(~c"~0tp", [%{credentials: %{password: @password}}])
          ),
        "inspect of a list-valued password" => inspect(%{password: [@password]}),
        "json" =>
          Jason.encode!(%{
            "password" => @password,
            "ice" => %{"local_pwd" => @local_pwd, "remote_pwd" => @remote_pwd}
          })
      }

      for {name, rendering} <- renderings do
        assert rendering =~ "synthetic-turn-pa", "#{name} lost the fixture"

        redacted = SecretRedaction.redact_text(rendering)

        assert_no_credentials(redacted)
        assert SecretRedaction.redact_text(redacted) == redacted, "#{name} is not idempotent"
        refute redacted =~ "[REDACTED]]", "#{name} doubled the marker"
      end
    end

    test "repairs text that an earlier redaction left with the value behind the marker" do
      for mangled <- [
            ~s(password =[REDACTED] <<"#{@password}">>),
            ~s(password =[REDACTED]] <<"#{@password}">>)
          ] do
        assert SecretRedaction.redact_text(mangled) == "password =[REDACTED]"
      end
    end

    test "keeps values that only look like credentials" do
      text =
        ~s(key: "objects/camera-01.mp4" cache_key=abc password_hash: kept token_count: 5 ) <>
          ~s(nonce: "synthetic-nonce" realm: "realm.example.com" credential_secret_id: 7 seed_count: 3)

      assert SecretRedaction.redact_text(text) == text
    end
  end
end
