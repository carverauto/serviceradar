defmodule ServiceRadar.Notifications.Transports.DiscordTestBroker do
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

defmodule ServiceRadar.Notifications.Transports.DiscordTest do
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
  that for a literal, so these tests exercise the real guard with no name lookup
  and no network of any kind.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Transport
  alias ServiceRadar.Notifications.Transport.Request
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.Notifications.Transports.Discord
  alias ServiceRadar.Notifications.Transports.DiscordTestBroker
  alias ServiceRadar.Notifications.Transports.Registry

  @public_ip "93.184.216.34"
  @webhook_url "https://93.184.216.34/api/webhooks/1234567890/abcdefghijklmnopqrstuvwxyz012345"
  @credential_ref "credentialref:network-credential-secret:cred-123"

  describe "contract" do
    test "declares the mandatory capabilities and conforms to the behaviour" do
      assert :send in Discord.capabilities()
      assert :test in Discord.capabilities()
      assert Transport.declares_required_capabilities?(Discord.capabilities())
      assert Registry.conforms?(Discord)
    end

    test "a value that is not a Request never raises and never returns an error tuple" do
      assert %Result{disposition: :permanent_failure} = Discord.deliver(%{}, [])
      assert %Result{disposition: :permanent_failure} = Discord.test(:nonsense, [])
    end
  end

  describe "validate_config/1" do
    test "accepts a webhook URL held as a stored credential reference" do
      assert :ok = Discord.validate_config(%{"webhook_url" => @credential_ref})
    end

    test "refuses a webhook URL saved as plain text" do
      assert {:error, errors} = Discord.validate_config(%{"webhook_url" => @webhook_url})
      assert error_for(errors, "webhook_url") =~ "credential reference"
    end

    test "requires a webhook URL at all" do
      assert {:error, errors} = Discord.validate_config(%{})
      assert error_for(errors, "webhook_url") =~ "is required"
    end

    test "refuses a non-boolean wait" do
      assert {:error, errors} =
               Discord.validate_config(%{"webhook_url" => @credential_ref, "wait" => "maybe"})

      assert error_for(errors, "wait") =~ "true or false"
    end

    test "refuses the edge_agent route" do
      assert {:error, errors} =
               Discord.validate_config(%{
                 "webhook_url" => @credential_ref,
                 "execution_route" => "edge_agent"
               })

      assert error_for(errors, "execution_route") =~ "URL path"
    end

    test "a non-map configuration is reported rather than raised" do
      assert {:error, [%{message: message}]} = Discord.validate_config("nope")
      assert message =~ "configuration map"
    end
  end

  describe "delivery" do
    test "posts the rendered embed with ?wait=true and reports delivered" do
      body = %{"id" => "1122334455667788", "channel_id" => "999"}
      result = deliver(plug: responder(200, body))

      assert %Result{disposition: :delivered} = result
      assert result.external_correlation_id == "1122334455667788"
      assert Result.outcome(result, true) == :sent

      assert_receive {:request, request}
      assert request.method == "POST"
      assert request.host == @public_ip
      assert request.path == "/api/webhooks/1234567890/abcdefghijklmnopqrstuvwxyz012345"
      assert request.query["wait"] == "true"
      assert [%{"title" => "Disk is full"}] = request.body["embeds"]
    end

    test "a 204 with no body is a delivery that simply has no correlation id" do
      result = deliver(plug: no_content())

      assert %Result{disposition: :delivered} = result
      assert result.external_correlation_id == nil
    end

    test "wait can be turned off, at the cost of the correlation id" do
      result = deliver([plug: no_content()], config: %{"wait" => false})

      assert %Result{disposition: :delivered} = result
      assert_receive {:request, request}
      refute Map.has_key?(request.query, "wait")
    end

    test "a thread_id is carried as a query parameter alongside wait" do
      result = deliver([plug: responder(200, %{"id" => "1"})], config: %{"thread_id" => "42"})

      assert %Result{disposition: :delivered} = result
      assert_receive {:request, request}
      assert request.query["thread_id"] == "42"
      assert request.query["wait"] == "true"
    end

    test "refuses the edge_agent route before any request is made" do
      result = deliver([plug: no_content()], execution_route: :edge_agent)

      assert %Result{disposition: :permanent_failure, error_class: "discord_route_unsupported"} =
               result

      assert result.error_message =~ "URL path"
      refute_receive {:request, _request}
    end
  end

  describe "429 retry_after" do
    # The trap: Discord answers in SECONDS and the value is routinely fractional.
    # Reading 0.75 as milliseconds backs off for under a millisecond, and
    # `Integer.parse("0.75")` yields 0 - both of which re-hit the rate limit
    # immediately.
    test "a fractional retry_after is seconds, not milliseconds" do
      body = %{
        "message" => "You are being rate limited.",
        "retry_after" => 0.75,
        "global" => false
      }

      result = deliver(plug: responder(429, body))

      assert %Result{disposition: :retryable_failure, error_class: "http_429"} = result
      assert result.retry_after_ms == 750
      assert Result.outcome(result, true) == :retry
      assert Result.outcome(result, false) == :failed
    end

    test "a whole-second retry_after is still seconds" do
      result = deliver(plug: responder(429, %{"retry_after" => 2}))

      assert %Result{disposition: :retryable_failure} = result
      assert result.retry_after_ms == 2000
    end

    test "the body wins over the Retry-After header" do
      body = %{"retry_after" => 0.5}
      result = deliver(plug: responder(429, body, [{"retry-after", "60"}]))

      assert result.retry_after_ms == 500
    end

    test "X-RateLimit-Reset-After is the fallback and is also seconds" do
      result = deliver(plug: responder(429, "", [{"x-ratelimit-reset-after", "1.5"}]))

      assert %Result{disposition: :retryable_failure} = result
      assert result.retry_after_ms == 1500
    end
  end

  describe "HTTP status classification" do
    test "400 is permanent and carries Discord's message" do
      body = %{"message" => "Invalid Form Body", "code" => 50_035}
      result = deliver(plug: responder(400, body))

      assert %Result{disposition: :permanent_failure, error_class: "http_400"} = result
      assert Result.outcome(result, true) == :failed
      assert result.error_message =~ "Invalid Form Body"
      assert result.result_summary["discord_code"] == 50_035
    end

    test "500 is retryable" do
      result = deliver(plug: responder(500, "server error"))

      assert %Result{disposition: :retryable_failure, error_class: "http_500"} = result
      assert Result.outcome(result, true) == :retry
    end

    test "404 for a deleted webhook is permanent" do
      result = deliver(plug: responder(404, %{"message" => "Unknown Webhook", "code" => 10_015}))

      assert %Result{disposition: :permanent_failure, error_class: "http_404"} = result
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
        deliver([plug: no_content()],
          secrets: %{"webhook_url" => "http://93.184.216.34/api/webhooks/1/abcdefghijklmnop"}
        )

      assert %Result{disposition: :permanent_failure, error_class: "blocked_url"} = result
      refute_receive {:request, _request}
    end

    test "a private-network webhook URL is refused" do
      result =
        deliver([plug: no_content()],
          secrets: %{"webhook_url" => "https://192.168.1.10/api/webhooks/1/abcdefghijklmnop"}
        )

      assert %Result{disposition: :permanent_failure, error_class: "blocked_url"} = result
      refute_receive {:request, _request}
    end

    test "a loopback webhook URL is refused" do
      for host <- ["127.0.0.1", "localhost"] do
        result =
          deliver([plug: no_content()],
            secrets: %{"webhook_url" => "https://#{host}/api/webhooks/1/abcdefghijklmnop"}
          )

        assert %Result{disposition: :permanent_failure, error_class: "blocked_url"} = result
      end

      refute_receive {:request, _request}
    end
  end

  describe "credentials" do
    test "a missing credential is a permanent failure" do
      result = deliver([plug: no_content()], secrets: %{})

      assert %Result{disposition: :permanent_failure, error_class: "discord_missing_secret"} =
               result

      refute_receive {:request, _request}
    end

    test "a stored reference resolves through the secret broker" do
      result =
        deliver(
          [
            plug: responder(200, %{"id" => "7"}),
            secret_broker: DiscordTestBroker,
            broker_opts: [stub: %{"cred-123" => @webhook_url}, reply_to: self()]
          ],
          secrets: %{},
          config: %{"webhook_url" => @credential_ref}
        )

      assert %Result{disposition: :delivered} = result

      assert_receive {:broker, "cred-123", broker_opts}
      assert broker_opts[:allow_external_resolution?] == true
      assert broker_opts[:resolution_location] == :control_plane
      assert broker_opts[:consumer_id] == "channel-1"

      assert_receive {:request, request}
      assert request.path == "/api/webhooks/1234567890/abcdefghijklmnopqrstuvwxyz012345"
    end

    test "a broker failure is retryable rather than a lost page" do
      result =
        deliver(
          [
            plug: no_content(),
            secret_broker: DiscordTestBroker,
            broker_opts: [stub: %{}]
          ],
          secrets: %{},
          config: %{"webhook_url" => @credential_ref}
        )

      assert %Result{disposition: :retryable_failure} = result
      assert result.error_class == "discord_secret_unavailable"
      refute_receive {:request, _request}
    end
  end

  describe "secret hygiene" do
    test "a response echoing the webhook URL cannot carry it into the result" do
      result = deliver(plug: responder(404, "Unknown Webhook #{@webhook_url}"))

      assert %Result{disposition: :permanent_failure} = result
      assert result.error_message =~ "[REDACTED]"
      refute inspect(result) =~ @webhook_url
    end

    test "a body echoing the URL with its query string is scrubbed as well" do
      result = deliver(plug: responder(400, "rejected #{@webhook_url}?wait=true"))

      assert %Result{disposition: :permanent_failure} = result
      assert result.error_message =~ "[REDACTED]"
      refute inspect(result) =~ @webhook_url
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
            plug: no_content(),
            secret_broker: DiscordTestBroker,
            broker_opts: [stub: %{"cred-123" => {:raise, "boom #{@webhook_url}"}}]
          ],
          secrets: %{},
          config: %{"webhook_url" => @credential_ref}
        )

      assert %Result{disposition: :retryable_failure, error_class: "transport_exception"} = result
      refute inspect(result) =~ @webhook_url
      refute inspect(result) =~ "boom"
      refute_receive {:request, _request}
    end
  end

  describe "payload negotiation" do
    test "a markdown payload is sent as content" do
      result =
        deliver([plug: responder(200, %{"id" => "9"})],
          payload_format: :markdown,
          payload: %{"text" => "### Disk is full", "body" => "Disk is full"}
        )

      assert %Result{disposition: :delivered} = result
      assert_receive {:request, request}
      assert request.body == %{"content" => "### Disk is full"}
    end

    test "a format Discord cannot carry is a permanent failure" do
      result =
        deliver([plug: no_content()],
          payload_format: :slack_blocks,
          payload: %{"blocks" => []}
        )

      assert %Result{disposition: :permanent_failure} = result
      assert result.error_class == "discord_unsupported_payload"
      refute_receive {:request, _request}
    end
  end

  describe "test/2" do
    test "exercises the same transport path as deliver/2" do
      result =
        Discord.test(build_request([]), req_options: [plug: responder(200, %{"id" => "3"})])

      assert %Result{disposition: :delivered} = result
      assert_receive {:request, request}
      assert request.path == "/api/webhooks/1234567890/abcdefghijklmnopqrstuvwxyz012345"
    end
  end

  # --- helpers --------------------------------------------------------------

  defp deliver(opts, overrides \\ []) do
    {plug, opts} = Keyword.pop!(opts, :plug)

    Discord.deliver(build_request(overrides), Keyword.put(opts, :req_options, plug: plug))
  end

  defp build_request(overrides) do
    defaults = [
      delivery_id: "delivery-1",
      channel_id: "channel-1",
      provider_key: "discord",
      payload_format: :discord_embed,
      payload: %{"embeds" => [%{"title" => "Disk is full", "color" => 14_038_051}]},
      config: %{},
      secrets: %{"webhook_url" => @webhook_url}
    ]

    struct!(Request, Keyword.merge(defaults, overrides))
  end

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

  defp no_content do
    parent = self()

    fn conn ->
      send(parent, {:request, capture(conn)})
      Plug.Conn.send_resp(conn, 204, "")
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
