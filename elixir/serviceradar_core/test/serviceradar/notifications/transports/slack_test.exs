defmodule ServiceRadar.Notifications.Transports.SlackTestBroker do
  @moduledoc """
  Stands in for `ServiceRadar.Credentials.SecretBroker` so the credential path is
  exercised without a database.

  The stubbed secrets and the reply target travel through `:broker_opts`, which
  the transport merges into the real broker options - so a test that gets an
  answer here has also proved the transport forwards those options.
  """

  def resolve_network_credential_secret(secret_id, opts) do
    if pid = Keyword.get(opts, :reply_to), do: send(pid, {:broker, secret_id, opts})

    case opts |> Keyword.get(:stub, %{}) |> Map.fetch(secret_id) do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, {:raise, message}} -> raise message
      {:ok, value} -> {:ok, %{value: value, source_type: :internal_encrypted, secret: %{}}}
      :error -> {:error, :credential_not_found}
    end
  end
end

defmodule ServiceRadar.Notifications.Transports.SlackTest do
  @moduledoc """
  Database-free, network-free transport tests.

  Every request is answered by a `Plug` function handed to the real
  `Transports.HTTP` through `:req_options`, so the outbound URL policy, the
  header assembly, the JSON encoding, and the status classification under test
  are the production ones - only the socket is replaced. Transport failures such
  as a timeout come from `Req.Test.transport_error/2`, which is the same code
  path a real `:timeout` takes.

  The hosts are literal public IP addresses. That is deliberate: the URL policy
  resolves a hostname through DNS, and `:inet.parse_address/1` short-circuits
  that for a literal, so these tests exercise the real guard with no name
  lookup and no network of any kind.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Transport
  alias ServiceRadar.Notifications.Transport.Request
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.Notifications.Transports.Registry
  alias ServiceRadar.Notifications.Transports.Slack
  alias ServiceRadar.Notifications.Transports.SlackTestBroker

  @public_ip "93.184.216.34"
  @webhook_url "https://93.184.216.34/services/T00000000/B00000000/abcdefghijklmnopqrst"
  @bot_token "xoxb-0000000000-1111111111-abcdefghijklmnopqrstuvwx"
  @api_base "https://93.184.216.34/api"
  @credential_ref "credentialref:network-credential-secret:cred-123"

  describe "contract" do
    test "declares the mandatory capabilities and conforms to the behaviour" do
      assert :send in Slack.capabilities()
      assert :test in Slack.capabilities()
      assert Transport.declares_required_capabilities?(Slack.capabilities())
      assert Registry.conforms?(Slack)
    end

    test "a value that is not a Request never raises and never returns an error tuple" do
      assert %Result{disposition: :permanent_failure} = Slack.deliver(%{}, [])
      assert %Result{disposition: :permanent_failure} = Slack.test(:nonsense, [])
    end
  end

  describe "validate_config/1" do
    test "requires an explicit mode" do
      assert {:error, errors} = Slack.validate_config(%{})
      assert error_for(errors, "mode") =~ "is required"

      assert {:error, errors} = Slack.validate_config(%{"mode" => "carrier_pigeon"})
      assert error_for(errors, "mode") =~ "incoming_webhook"
    end

    test "refuses interactive mode without the app id that finds the signing secret" do
      # The one misconfiguration Slack never reports: no Interactivity Request
      # URL, an inert button, no request and no log. So the part we CAN check is
      # checked at save time, where an operator is present to read it.
      assert {:error, errors} =
               Slack.validate_config(%{
                 "mode" => "incoming_webhook",
                 "webhook_url" => @credential_ref,
                 "interactive" => true
               })

      assert error_for(errors, "api_app_id") =~ "required when interactive is enabled"
    end

    test "accepts interactive mode with an app id" do
      assert :ok =
               Slack.validate_config(%{
                 "mode" => "incoming_webhook",
                 "webhook_url" => @credential_ref,
                 "interactive" => true,
                 "api_app_id" => "A0123456789"
               })
    end

    test "does not demand an app id when interactive is off or absent" do
      for config <- [%{}, %{"interactive" => false}] do
        assert :ok =
                 Slack.validate_config(
                   Map.merge(
                     %{"mode" => "incoming_webhook", "webhook_url" => @credential_ref},
                     config
                   )
                 )
      end
    end

    test "accepts an incoming webhook whose URL is a stored credential reference" do
      assert :ok =
               Slack.validate_config(%{
                 "mode" => "incoming_webhook",
                 "webhook_url" => @credential_ref
               })
    end

    test "refuses a webhook URL saved as plain text" do
      assert {:error, errors} =
               Slack.validate_config(%{
                 "mode" => "incoming_webhook",
                 "webhook_url" => @webhook_url
               })

      assert error_for(errors, "webhook_url") =~ "credential reference"
    end

    test "requires a webhook URL at all" do
      assert {:error, errors} = Slack.validate_config(%{"mode" => "incoming_webhook"})
      assert error_for(errors, "webhook_url") =~ "is required"
    end

    test "accepts a bot token channel and refuses one without a channel" do
      valid = %{"mode" => "bot_token", "bot_token" => @credential_ref, "channel" => "#noc"}
      assert :ok = Slack.validate_config(valid)

      assert {:error, errors} = Slack.validate_config(Map.delete(valid, "channel"))
      assert error_for(errors, "channel") =~ "required"
    end

    test "refuses a non-https API base URL" do
      assert {:error, errors} =
               Slack.validate_config(%{
                 "mode" => "bot_token",
                 "bot_token" => @credential_ref,
                 "channel" => "#noc",
                 "api_base_url" => "http://#{@public_ip}/api"
               })

      assert error_for(errors, "api_base_url") =~ "https"
    end

    test "refuses the edge_agent route for an incoming webhook" do
      assert {:error, errors} =
               Slack.validate_config(%{
                 "mode" => "incoming_webhook",
                 "webhook_url" => @credential_ref,
                 "execution_route" => "edge_agent"
               })

      assert error_for(errors, "execution_route") =~ "bot_token"
    end

    test "the edge_agent route is fine in the bot_token mode" do
      assert :ok =
               Slack.validate_config(%{
                 "mode" => "bot_token",
                 "bot_token" => @credential_ref,
                 "channel" => "#noc",
                 "execution_route" => "edge_agent"
               })
    end

    test "a non-map configuration is reported rather than raised" do
      assert {:error, [%{message: message}]} = Slack.validate_config("nope")
      assert message =~ "configuration map"
    end
  end

  describe "incoming webhook delivery" do
    test "posts the rendered blocks and reports delivered" do
      result = deliver(plug: responder(200, "ok"))

      assert %Result{disposition: :delivered} = result
      assert Result.outcome(result, true) == :sent

      assert_receive {:request, request}
      assert request.method == "POST"
      assert request.host == @public_ip
      assert request.path == "/services/T00000000/B00000000/abcdefghijklmnopqrst"
      assert request.body["blocks"] == [%{"type" => "section", "text" => "Disk is full"}]
      assert request.headers["content-type"] =~ "application/json"
    end

    test "refuses the edge_agent route before any request is made" do
      result = deliver([plug: responder(200, "ok")], execution_route: :edge_agent)

      assert %Result{disposition: :permanent_failure, error_class: "slack_route_unsupported"} =
               result

      assert result.error_message =~ "URL path"
      refute_receive {:request, _request}
    end
  end

  describe "bot token delivery" do
    test "authenticates with a bearer token, addresses a channel, and carries back ts" do
      body = %{"ok" => true, "channel" => "C123", "ts" => "1717171717.000100"}
      result = bot_deliver(plug: responder(200, body))

      assert %Result{disposition: :delivered} = result
      assert result.external_correlation_id == "1717171717.000100"
      assert result.result_summary["slack_channel"] == "C123"

      assert_receive {:request, request}
      assert request.path == "/api/chat.postMessage"
      assert request.headers["authorization"] == "Bearer " <> @bot_token
      assert request.body["channel"] == "#noc"
    end

    test "threads a reply when thread_ts is configured" do
      body = %{"ok" => true, "ts" => "1717171717.000200"}
      result = bot_deliver([plug: responder(200, body)], %{"thread_ts" => "1717171717.000100"})

      assert %Result{disposition: :delivered} = result
      assert_receive {:request, request}
      assert request.body["thread_ts"] == "1717171717.000100"
    end
  end

  describe "HTTP 200 with ok:false" do
    test "channel_not_found is a permanent failure, not a delivery" do
      body = %{"ok" => false, "error" => "channel_not_found"}
      result = bot_deliver(plug: responder(200, body))

      assert %Result{disposition: :permanent_failure} = result
      assert result.error_class == "slack_channel_not_found"
      assert Result.outcome(result, true) == :failed
      assert result.result_summary["slack_error"] == "channel_not_found"
    end

    test "invalid_auth and not_in_channel are permanent" do
      for error <- ~w(invalid_auth not_in_channel msg_too_long token_revoked) do
        result = bot_deliver(plug: responder(200, %{"ok" => false, "error" => error}))

        assert %Result{disposition: :permanent_failure} = result
        assert result.error_class == "slack_" <> error
      end
    end

    test "ratelimited is retryable and honours Retry-After" do
      result =
        bot_deliver(
          plug:
            responder(200, %{"ok" => false, "error" => "ratelimited"}, [{"retry-after", "30"}])
        )

      assert %Result{disposition: :retryable_failure} = result
      assert result.error_class == "slack_ratelimited"
      assert result.retry_after_ms == 30_000
      assert Result.outcome(result, true) == :retry
      assert Result.outcome(result, false) == :failed
    end

    test "internal_error is retryable" do
      result = bot_deliver(plug: responder(200, %{"ok" => false, "error" => "internal_error"}))

      assert %Result{disposition: :retryable_failure, error_class: "slack_internal_error"} =
               result
    end

    test "an unrecognised ok:false error defaults to permanent" do
      result = bot_deliver(plug: responder(200, %{"ok" => false, "error" => "brand_new_error"}))
      assert %Result{disposition: :permanent_failure} = result
      assert result.error_class == "slack_brand_new_error"
    end

    test "ok:true is a delivery even when an error key is absent" do
      assert %Result{disposition: :delivered} = bot_deliver(plug: responder(200, %{"ok" => true}))
    end
  end

  describe "HTTP status classification" do
    test "500 is retryable" do
      result = deliver(plug: responder(500, "server error"))

      assert %Result{disposition: :retryable_failure, error_class: "http_500"} = result
      assert Result.outcome(result, true) == :retry
    end

    test "429 is retryable" do
      result = deliver(plug: responder(429, "rate limited", [{"retry-after", "12"}]))

      assert %Result{disposition: :retryable_failure, error_class: "http_429"} = result
      assert result.retry_after_ms == 12_000
    end

    test "400 is permanent" do
      result = deliver(plug: responder(400, "invalid_payload"))

      assert %Result{disposition: :permanent_failure, error_class: "http_400"} = result
      assert Result.outcome(result, true) == :failed
      assert result.error_message =~ "invalid_payload"
    end

    test "a 429 body carrying a Slack error keeps the Slack class and stays retryable" do
      result =
        bot_deliver(
          plug: responder(429, %{"ok" => false, "error" => "ratelimited"}, [{"retry-after", "5"}])
        )

      assert %Result{disposition: :retryable_failure, error_class: "slack_ratelimited"} = result
      assert result.retry_after_ms == 5000
    end

    test "a 503 body carrying an unknown Slack error stays retryable" do
      result = bot_deliver(plug: responder(503, %{"ok" => false, "error" => "brand_new_error"}))

      assert %Result{disposition: :retryable_failure} = result
      assert result.error_class == "slack_brand_new_error"
    end
  end

  describe "transport failures" do
    test "a timeout is retryable" do
      result = deliver(plug: transport_error(:timeout))

      assert %Result{disposition: :retryable_failure, error_class: "timeout"} = result
      assert Result.outcome(result, true) == :retry
    end

    test "a closed connection is retryable" do
      assert %Result{disposition: :retryable_failure, error_class: "closed"} =
               deliver(plug: transport_error(:closed))
    end
  end

  describe "outbound URL policy" do
    test "an http:// webhook URL is refused and no request is made" do
      result =
        deliver([plug: responder(200, "ok")], secrets: %{"webhook_url" => plain_http_url()})

      assert %Result{disposition: :permanent_failure, error_class: "blocked_url"} = result
      refute_receive {:request, _request}
    end

    test "a private-network webhook URL is refused" do
      result =
        deliver([plug: responder(200, "ok")],
          secrets: %{"webhook_url" => "https://10.1.2.3/services/T/B/abcdefghijklmnop"}
        )

      assert %Result{disposition: :permanent_failure, error_class: "blocked_url"} = result
      refute_receive {:request, _request}
    end

    test "a loopback webhook URL is refused" do
      for host <- ["127.0.0.1", "localhost"] do
        result =
          deliver([plug: responder(200, "ok")],
            secrets: %{"webhook_url" => "https://#{host}/services/T/B/abcdefghijklmnop"}
          )

        assert %Result{disposition: :permanent_failure, error_class: "blocked_url"} = result
      end

      refute_receive {:request, _request}
    end
  end

  describe "credentials" do
    test "a missing credential is a permanent failure" do
      result = deliver([plug: responder(200, "ok")], secrets: %{}, config: base_config())

      assert %Result{disposition: :permanent_failure, error_class: "slack_missing_secret"} =
               result

      refute_receive {:request, _request}
    end

    test "a stored reference resolves through the secret broker" do
      result =
        deliver(
          [
            plug: responder(200, "ok"),
            secret_broker: SlackTestBroker,
            broker_opts: [stub: %{"cred-123" => @webhook_url}, reply_to: self()]
          ],
          secrets: %{},
          config: Map.put(base_config(), "webhook_url", @credential_ref)
        )

      assert %Result{disposition: :delivered} = result

      assert_receive {:broker, "cred-123", broker_opts}
      assert broker_opts[:allow_external_resolution?] == true
      assert broker_opts[:resolution_location] == :control_plane
      assert broker_opts[:consumer_id] == "channel-1"

      assert_receive {:request, request}
      assert request.path == "/services/T00000000/B00000000/abcdefghijklmnopqrst"
    end

    test "a broker failure is retryable rather than a lost page" do
      result =
        deliver(
          [
            plug: responder(200, "ok"),
            secret_broker: SlackTestBroker,
            broker_opts: [stub: %{}]
          ],
          secrets: %{},
          config: Map.put(base_config(), "webhook_url", @credential_ref)
        )

      assert %Result{disposition: :retryable_failure} = result
      assert result.error_class == "slack_secret_unavailable"
      refute_receive {:request, _request}
    end
  end

  describe "secret hygiene" do
    test "a response echoing the webhook URL cannot carry it into the result" do
      result = deliver(plug: responder(400, "no_service for #{@webhook_url}"))

      assert %Result{disposition: :permanent_failure} = result
      assert result.error_message =~ "[REDACTED]"
      refute inspect(result) =~ @webhook_url
    end

    test "a bot token never appears in a result, a summary, or an error" do
      result = bot_deliver(plug: responder(401, %{"ok" => false, "error" => "invalid_auth"}))

      assert %Result{disposition: :permanent_failure} = result
      refute inspect(result) =~ @bot_token
    end

    test "a raising destination yields a retryable result with the URL scrubbed out" do
      plug = fn _conn -> raise "boom #{@webhook_url}" end
      result = deliver(plug: plug)

      assert %Result{disposition: :retryable_failure} = result
      refute inspect(result) =~ @webhook_url
      assert result.error_message =~ "[REDACTED]"
    end

    # The guard of last resort: an exception raised outside the HTTP layer, which
    # has its own rescue. Only the exception's module name survives, because an
    # exception message can carry the resolved webhook URL.
    test "an exception during credential resolution is contained, message and all" do
      result =
        deliver(
          [
            plug: responder(200, "ok"),
            secret_broker: SlackTestBroker,
            broker_opts: [stub: %{"cred-123" => {:raise, "boom #{@webhook_url}"}}]
          ],
          secrets: %{},
          config: Map.put(base_config(), "webhook_url", @credential_ref)
        )

      assert %Result{disposition: :retryable_failure, error_class: "transport_exception"} = result
      refute inspect(result) =~ @webhook_url
      refute inspect(result) =~ "boom"
      refute_receive {:request, _request}
    end
  end

  describe "payload negotiation" do
    test "a markdown payload is sent as text" do
      result =
        deliver([plug: responder(200, "ok")],
          payload_format: :markdown,
          payload: %{"text" => "### Disk is full", "body" => "Disk is full"}
        )

      assert %Result{disposition: :delivered} = result
      assert_receive {:request, request}
      assert request.body == %{"text" => "### Disk is full"}
    end

    test "a format Slack cannot carry is a permanent failure" do
      result =
        deliver([plug: responder(200, "ok")],
          payload_format: :pagerduty_v2,
          payload: %{"payload" => %{}}
        )

      assert %Result{disposition: :permanent_failure} = result
      assert result.error_class == "slack_unsupported_payload"
      refute_receive {:request, _request}
    end
  end

  describe "test/2" do
    test "exercises the same transport path as deliver/2" do
      result = Slack.test(build_request([]), req_options: [plug: responder(200, "ok")])

      assert %Result{disposition: :delivered} = result
      assert_receive {:request, request}
      assert request.path == "/services/T00000000/B00000000/abcdefghijklmnopqrst"
    end
  end

  # --- helpers --------------------------------------------------------------

  defp deliver(opts, overrides \\ []) do
    {plug, opts} = Keyword.pop!(opts, :plug)

    Slack.deliver(build_request(overrides), Keyword.put(opts, :req_options, plug: plug))
  end

  defp bot_deliver(opts, config_extras \\ %{}) do
    config =
      Map.merge(
        %{
          "mode" => "bot_token",
          "channel" => "#noc",
          "api_base_url" => @api_base
        },
        config_extras
      )

    deliver(opts, config: config, secrets: %{"bot_token" => @bot_token})
  end

  defp build_request(overrides) do
    defaults = [
      delivery_id: "delivery-1",
      channel_id: "channel-1",
      provider_key: "slack",
      payload_format: :slack_blocks,
      payload: %{
        "text" => "Disk is full",
        "blocks" => [%{"type" => "section", "text" => "Disk is full"}]
      },
      config: base_config(),
      secrets: %{"webhook_url" => @webhook_url}
    ]

    struct!(Request, Keyword.merge(defaults, overrides))
  end

  defp base_config, do: %{"mode" => "incoming_webhook"}

  defp plain_http_url, do: "http://93.184.216.34/services/T/B/abcdefghijklmnop"

  defp responder(status, body, resp_headers \\ []) do
    parent = self()

    fn conn ->
      send(parent, {:request, capture(conn)})

      resp_headers
      |> Enum.reduce(conn, fn {name, value}, acc ->
        Plug.Conn.put_resp_header(acc, name, value)
      end)
      |> respond(status, body)
    end
  end

  defp transport_error(reason) do
    parent = self()

    fn conn ->
      send(parent, {:request, capture(conn)})
      Req.Test.transport_error(conn, reason)
    end
  end

  defp respond(conn, status, body) when is_map(body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp respond(conn, status, body) when is_binary(body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(status, body)
  end

  defp capture(conn) do
    %{
      method: conn.method,
      host: conn.host,
      path: conn.request_path,
      query: URI.decode_query(conn.query_string || ""),
      headers: Map.new(conn.req_headers),
      body: conn.body_params
    }
  end

  defp error_for(errors, field) do
    Enum.find_value(errors, "", fn error -> if error.field == field, do: error.message end)
  end
end
