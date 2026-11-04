defmodule ServiceRadar.NATS.CertificateAuthorizationToken do
  @moduledoc """
  NATS authorization request verification and response signing.

  The request must arrive on the protected authorization account subscription.
  A verified server signature proves the request bytes; it does not grant a
  certificate access. The caller must consult the durable certificate authority
  before signing an allow response. Only NATS-verified TLS chains are accepted.
  """

  alias NKEYS.Keypair

  @header %{"typ" => "JWT", "alg" => "ed25519-nkey"}
  @audience "nats-authorization-request"
  @max_request_bytes 65_536

  @doc "Generate a persistent NATS account or user signing key."
  def new_key(type) when type in [:account, :user] do
    prefix = if type == :account, do: 0, else: 20
    # nkeys 0.3.1 new_* returns an empty seed and encode_seed uses the wrong
    # seed prefix. Encode the NATS seed wire format before using its signer.
    bytes = <<18::5, prefix::5, 0::6, :crypto.strong_rand_bytes(32)::binary>>
    seed = Base.encode32(<<bytes::binary, NKEYS.CRC.compute(bytes)::little-16>>, padding: false)
    {:ok, key} = Keypair.from_seed(seed)
    %{seed: seed, public_key: Keypair.public_key(key)}
  end

  @doc "Validate a broker request addressed to this authorization issuer."
  def decode_request(token, issuer_nkey, now \\ System.system_time(:second))

  def decode_request(token, issuer_nkey, now)
      when is_binary(token) and byte_size(token) <= @max_request_bytes and is_integer(now) do
    with [header, body, signature] <- String.split(token, "."),
         {:ok, header_json} <- decode_json(header),
         true <- header_json == @header,
         {:ok, claims} <- decode_json(body),
         %{
           "iss" => "N" <> _ = server_id,
           "sub" => ^issuer_nkey,
           "aud" => @audience,
           "iat" => issued_at,
           "exp" => expires_at,
           "nats" => %{
             "type" => "authorization_request",
             "version" => 2,
             "server_id" => %{"id" => server_id},
             "client_info" => %{"id" => connection_id},
             "user_nkey" => "U" <> _ = user_nkey,
             "client_tls" => %{"verified_chains" => [[leaf_pem | _] | _]}
           }
         } <- claims,
         true <- is_integer(issued_at) and is_integer(expires_at),
         true <- issued_at <= now + 1 and expires_at > now and expires_at <= now + 60,
         true <- is_integer(connection_id) and connection_id > 0,
         {:ok, _user_key} <- public_key(user_nkey, 160),
         {:ok, server_key} <- public_key(server_id, 104),
         {:ok, signature} <- Base.url_decode64(signature, padding: false),
         true <-
           :crypto.verify(:eddsa, :none, header <> "." <> body, signature, [server_key, :ed25519]),
         [{:Certificate, der, :not_encrypted}] <- :public_key.pem_decode(leaf_pem) do
      {:ok,
       %{
         user_nkey: user_nkey,
         server_id: server_id,
         connection_id: connection_id,
         fingerprint: Base.encode16(:crypto.hash(:sha256, der), case: :lower),
         certificate_der: der
       }}
    else
      _ -> {:error, :invalid_authorization_request}
    end
  rescue
    _ -> {:error, :invalid_authorization_request}
  end

  def decode_request(_, _, _), do: {:error, :invalid_authorization_request}

  @doc "Bound a hub session by its certificate and a jittered broker-enforced grant."
  def grant_expiry(%DateTime{} = not_after) do
    ttl = Application.get_env(:serviceradar, :nats_certificate_grant_ttl_seconds, 43_200)
    jitter = div(ttl, 5)
    seconds = ttl - jitter + :rand.uniform(2 * jitter + 1) - 1
    min(System.system_time(:second) + seconds, DateTime.to_unix(not_after))
  end

  @doc "Sign an allow or deny response for a previously verified request."
  def encode_response(
        request,
        decision,
        %Keypair{} = signer,
        account,
        now \\ System.system_time(:second)
      ) do
    result =
      case decision do
        {:allow, %{expires_at: expires_at} = permissions} ->
          {publish, subscribe} = user_permissions(permissions)

          user =
            encode(
              %{
                "sub" => request.user_nkey,
                "aud" => account,
                "name" => grant_name(request.fingerprint, permissions),
                "exp" => expires_at,
                "nats" => %{
                  "type" => "user",
                  "version" => 2,
                  "pub" => publish,
                  "sub" => subscribe,
                  "subs" => -1,
                  "data" => -1,
                  "payload" => -1
                }
              },
              signer,
              now
            )

          %{"jwt" => user}

        {:deny, reason} when is_binary(reason) ->
          %{"error" => reason}
      end

    encode(
      %{
        "sub" => request.user_nkey,
        "aud" => request.server_id,
        "exp" => now + 30,
        "nats" => Map.merge(result, %{"type" => "authorization_response", "version" => 2})
      },
      signer,
      now
    )
  end

  @doc """
  The user name an allow response signs: the certificate fingerprint, a dot,
  and the SHA-256 of the publish and subscribe permissions the user JWT carries.

  NATS 2.14 makes a callout user's JWT `name` the connection's
  `authorized_user` in an authenticated CONNZ listing, so the hub scan can find
  a session whose grant is not the current one, including one an earlier
  release granted under the bare fingerprint.
  """
  def grant_name(fingerprint, permissions) do
    {publish, subscribe} = user_permissions(permissions)

    digest =
      [publish["allow"], publish["deny"], subscribe["allow"], subscribe["deny"]]
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    fingerprint <> "." <> digest
  end

  defp user_permissions(%{publish: publish, subscribe: subscribe} = permissions) do
    {subject_permissions(publish, Map.get(permissions, :publish_deny, [])),
     subject_permissions(subscribe, Map.get(permissions, :subscribe_deny, []))}
  end

  # An empty JWT allow list means unrestricted access to NATS, while the
  # managed policy uses an empty list to grant no subjects.
  defp subject_permissions([], _deny), do: %{"deny" => [">"]}
  defp subject_permissions(allow, deny), do: %{"allow" => allow, "deny" => deny}

  defp encode(claims, signer, now) do
    claims = Map.merge(claims, %{"iss" => Keypair.public_key(signer), "iat" => now})

    id =
      claims
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode32(padding: false)

    header = @header |> Jason.encode!() |> Base.url_encode64(padding: false)
    body = claims |> Map.put("jti", id) |> Jason.encode!() |> Base.url_encode64(padding: false)
    unsigned = header <> "." <> body
    unsigned <> "." <> Base.url_encode64(Keypair.sign(signer, unsigned), padding: false)
  end

  defp decode_json(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false), do: Jason.decode(json)
  end

  # nkeys 0.3.1 from_public/1 computes CRC over the key alone. NATS includes
  # the prefix byte; verify the complete encoded payload before using the key.
  defp public_key(encoded, prefix) do
    with {:ok, <<^prefix, key::binary-size(32), checksum::little-16>>} <-
           Base.decode32(encoded, padding: false),
         true <- NKEYS.CRC.compute(<<prefix, key::binary>>) == checksum do
      {:ok, key}
    else
      _ -> {:error, :invalid_nkey}
    end
  end
end
