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
        {:allow, %{publish: publish, subscribe: subscribe, expires_at: expires_at}} ->
          user =
            encode(
              %{
                "sub" => request.user_nkey,
                "aud" => account,
                "name" => request.fingerprint,
                "exp" => expires_at,
                "nats" => %{
                  "type" => "user",
                  "version" => 2,
                  "pub" => %{"allow" => publish},
                  "sub" => %{"allow" => subscribe},
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
