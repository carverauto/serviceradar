defmodule UUID do
  @moduledoc """
  UUID generator and utilities for [Elixir](http://elixir-lang.org/).
  See [RFC 4122](http://www.ietf.org/rfc/rfc4122.txt).
  """

  @nanosec_intervals_offset 122_192_928_000_000_000 # 15 Oct 1582 to 1 Jan 1970.
  @nanosec_intervals_factor 10 # Microseconds to nanoseconds factor.

  @variant10 2 # Variant, corresponds to variant 1 0 of RFC 4122.
  @uuid_v1 1 # UUID v1 identifier.
  @uuid_v3 3 # UUID v3 identifier.
  @uuid_v4 4 # UUID v4 identifier.
  @uuid_v5 5 # UUID v5 identifier.

  @urn "urn:uuid:" # UUID URN prefix.

  @doc """
  Inspect a UUID and return tuple with `{:ok, result}`, where result is
  information about its 128-bit binary content, type,
  version and variant.

  Timestamp portion is not checked to see if it's in the future, and therefore
  not yet assignable. See "Validation mechanism" in section 3 of
  [RFC 4122](http://www.ietf.org/rfc/rfc4122.txt).

  Will return `{:error, message}` if the given string is not a UUID representation
  in a format like:
  * `"870df8e8-3107-4487-8316-81e089b8c2cf"`
  * `"8ea1513df8a14dea9bea6b8f4b5b6e73"`
  * `"urn:uuid:ef1b1a28-ee34-11e3-8813-14109ff1a304"`

  ## Examples

  ```elixir
  iex> UUID.info("870df8e8-3107-4487-8316-81e089b8c2cf")
  {:ok, [uuid: "870df8e8-3107-4487-8316-81e089b8c2cf",
   binary: <<135, 13, 248, 232, 49, 7, 68, 135, 131, 22, 129, 224, 137, 184, 194, 207>>,
   type: :default,
   version: 4,
   variant: :rfc4122]}

  iex> UUID.info("8ea1513df8a14dea9bea6b8f4b5b6e73")
  {:ok, [uuid: "8ea1513df8a14dea9bea6b8f4b5b6e73",
   binary: <<142, 161, 81, 61, 248, 161, 77, 234, 155,
              234, 107, 143, 75, 91, 110, 115>>,
   type: :hex,
   version: 4,
   variant: :rfc4122]}

  iex> UUID.info("urn:uuid:ef1b1a28-ee34-11e3-8813-14109ff1a304")
  {:ok, [uuid: "urn:uuid:ef1b1a28-ee34-11e3-8813-14109ff1a304",
   binary: <<239, 27, 26, 40, 238, 52, 17, 227, 136, 19, 20, 16, 159, 241, 163, 4>>,
   type: :urn,
   version: 1,
   variant: :rfc4122]}

  iex> UUID.info(<<39, 73, 196, 181, 29, 90, 74, 96, 157, 47, 171, 144, 84, 164, 155, 52>>)
  {:ok, [uuid: <<39, 73, 196, 181, 29, 90, 74, 96, 157, 47, 171, 144, 84, 164, 155, 52>>,
   binary: <<39, 73, 196, 181, 29, 90, 74, 96, 157, 47, 171, 144, 84, 164, 155, 52>>,
   type: :raw,
   version: 4,
   variant: :rfc4122]}

  iex> UUID.info("12345")
  {:error, "Invalid argument; Not a valid UUID: 12345"}

  ```

  """
  def info(uuid) do
    try do
      {:ok, UUID.info!(uuid)}
    rescue
      e in ArgumentError -> {:error, e.message}
    end
  end

  @doc """
  Inspect a UUID and return information about its 128-bit binary content, type,
  version and variant.

  Timestamp portion is not checked to see if it's in the future, and therefore
  not yet assignable. See "Validation mechanism" in section 3 of
  [RFC 4122](http://www.ietf.org/rfc/rfc4122.txt).

  Will raise an `ArgumentError` if the given string is not a UUID representation
  in a format like:
  * `"870df8e8-3107-4487-8316-81e089b8c2cf"`
  * `"8ea1513df8a14dea9bea6b8f4b5b6e73"`
  * `"urn:uuid:ef1b1a28-ee34-11e3-8813-14109ff1a304"`

  ## Examples

  ```elixir
  iex> UUID.info!("870df8e8-3107-4487-8316-81e089b8c2cf")
  [uuid: "870df8e8-3107-4487-8316-81e089b8c2cf",
   binary: <<135, 13, 248, 232, 49, 7, 68, 135, 131, 22, 129, 224, 137, 184, 194, 207>>,
   type: :default,
   version: 4,
   variant: :rfc4122]

  iex> UUID.info!("8ea1513df8a14dea9bea6b8f4b5b6e73")
  [uuid: "8ea1513df8a14dea9bea6b8f4b5b6e73",
   binary: <<142, 161, 81, 61, 248, 161, 77, 234, 155,
              234, 107, 143, 75, 91, 110, 115>>,
   type: :hex,
   version: 4,
   variant: :rfc4122]

  iex> UUID.info!("urn:uuid:ef1b1a28-ee34-11e3-8813-14109ff1a304")
  [uuid: "urn:uuid:ef1b1a28-ee34-11e3-8813-14109ff1a304",
   binary: <<239, 27, 26, 40, 238, 52, 17, 227, 136, 19, 20, 16, 159, 241, 163, 4>>,
   type: :urn,
   version: 1,
   variant: :rfc4122]

  iex> UUID.info!(<<39, 73, 196, 181, 29, 90, 74, 96, 157, 47, 171, 144, 84, 164, 155, 52>>)
  [uuid: <<39, 73, 196, 181, 29, 90, 74, 96, 157, 47, 171, 144, 84, 164, 155, 52>>,
   binary: <<39, 73, 196, 181, 29, 90, 74, 96, 157, 47, 171, 144, 84, 164, 155, 52>>,
   type: :raw,
   version: 4,
   variant: :rfc4122]

  ```

  """
  def info!(<<uuid::binary>> = uuid_string) do
    {type, <<uuid::128>>} = uuid_string_to_hex_pair(uuid)
    <<_::48, version::4, _::12, v0::1, v1::1, v2::1, _::61>> = <<uuid::128>>
    [uuid: uuid_string,
     binary: <<uuid::128>>,
     type: type,
     version: version,
     variant: variant(<<v0, v1, v2>>)]
  end
  def info!(_) do
    raise ArgumentError, message: "Invalid argument; Expected: String"
  end

  @doc """
  Convert binary UUID data to a string.

  Will raise an ArgumentError if the given binary is not valid UUID data, or
  the format argument is not one of: `:default`, `:hex`, `:urn`, or `:raw`.

  ## Examples

  ```elixir
  iex> UUID.binary_to_string!(<<135, 13, 248, 232, 49, 7, 68, 135,
  ...>        131, 22, 129, 224, 137, 184, 194, 207>>)
  "870df8e8-3107-4487-8316-81e089b8c2cf"

  iex> UUID.binary_to_string!(<<142, 161, 81, 61, 248, 161, 77, 234, 155,
  ...>        234, 107, 143, 75, 91, 110, 115>>, :hex)
  "8ea1513df8a14dea9bea6b8f4b5b6e73"

  iex> UUID.binary_to_string!(<<239, 27, 26, 40, 238, 52, 17, 227, 136,
  ...>        19, 20, 16, 159, 241, 163, 4>>, :urn)
  "urn:uuid:ef1b1a28-ee34-11e3-8813-14109ff1a304"

  iex> UUID.binary_to_string!(<<39, 73, 196, 181, 29, 90, 74, 96, 157,
  ...>        47, 171, 144, 84, 164, 155, 52>>, :raw)
  <<39, 73, 196, 181, 29, 90, 74, 96, 157, 47, 171, 144, 84, 164, 155, 52>>

  ```

  """
  def binary_to_string!(uuid, format \\ :default)
  def binary_to_string!(<<uuid::binary>>, format) do
    uuid_to_string(<<uuid::binary>>, format)
  end
  def binary_to_string!(_, _) do
    raise ArgumentError, message: "Invalid argument; Expected: <<uuid::128>>"
  end

  @doc """
  Convert a UUID string to its binary data equivalent.

  Will raise an ArgumentError if the given string is not a UUID representation
  in a format like:
  * `"870df8e8-3107-4487-8316-81e089b8c2cf"`
  * `"8ea1513df8a14dea9bea6b8f4b5b6e73"`
  * `"urn:uuid:ef1b1a28-ee34-11e3-8813-14109ff1a304"`

  ## Examples

  ```elixir
  iex> UUID.string_to_binary!("870df8e8-3107-4487-8316-81e089b8c2cf")
  <<135, 13, 248, 232, 49, 7, 68, 135, 131, 22, 129, 224, 137, 184, 194, 207>>

  iex> UUID.string_to_binary!("8ea1513df8a14dea9bea6b8f4b5b6e73")
  <<142, 161, 81, 61, 248, 161, 77, 234, 155, 234, 107, 143, 75, 91, 110, 115>>

  iex> UUID.string_to_binary!("urn:uuid:ef1b1a28-ee34-11e3-8813-14109ff1a304")
  <<239, 27, 26, 40, 238, 52, 17, 227, 136, 19, 20, 16, 159, 241, 163, 4>>

  iex> UUID.string_to_binary!(<<39, 73, 196, 181, 29, 90, 74, 96, 157, 47,
  ...>        171, 144, 84, 164, 155, 52>>)
  <<39, 73, 196, 181, 29, 90, 74, 96, 157, 47, 171, 144, 84, 164, 155, 52>>

  ```

  """
  def string_to_binary!(<<uuid::binary>>) do
    {_type, <<uuid::128>>} = uuid_string_to_hex_pair(uuid)
    <<uuid::128>>
  end
  def string_to_binary!(_) do
    raise ArgumentError, message: "Invalid argument; Expected: String"
  end

  @doc """
  Generate a new UUID v1. This version uses a combination of one or more of:
  unix epoch, random bytes, pid hash, and hardware address.

  ## Examples

  ```elixir
  iex> UUID.uuid1()
  "cdfdaf44-ee35-11e3-846b-14109ff1a304"

  iex> UUID.uuid1(:default)
  "cdfdaf44-ee35-11e3-846b-14109ff1a304"

  iex> UUID.uuid1(:hex)
  "cdfdaf44ee3511e3846b14109ff1a304"

  iex> UUID.uuid1(:urn)
  "urn:uuid:cdfdaf44-ee35-11e3-846b-14109ff1a304"

  iex> UUID.uuid1(:raw)
  <<205, 253, 175, 68, 238, 53, 17, 227, 132, 107, 20, 16, 159, 241, 163, 4>>

  iex> UUID.uuid1(:slug)
  "zf2vRO41EeOEaxQQn_GjBA"
  ```

  """
  def uuid1(format \\ :default) do
    uuid1(uuid1_clockseq(), uuid1_node(), format)
  end

  @doc """
  Generate a new UUID v1, with an existing clock sequence and node address. This
  version uses a combination of one or more of: unix epoch, random bytes,
  pid hash, and hardware address.

  ## Examples

  ```elixir
  iex> UUID.uuid1()
  "cdfdaf44-ee35-11e3-846b-14109ff1a304"

  iex> UUID.uuid1(:default)
  "cdfdaf44-ee35-11e3-846b-14109ff1a304"

  iex> UUID.uuid1(:hex)
  "cdfdaf44ee3511e3846b14109ff1a304"

  iex> UUID.uuid1(:urn)
  "urn:uuid:cdfdaf44-ee35-11e3-846b-14109ff1a304"

  iex> UUID.uuid1(:raw)
  <<205, 253, 175, 68, 238, 53, 17, 227, 132, 107, 20, 16, 159, 241, 163, 4>>

  iex> UUID.uuid1(:slug)
  "zf2vRO41EeOEaxQQn_GjBA"
  ```

  """
  def uuid1(clock_seq, node, format \\ :default)
  def uuid1(<<clock_seq::14>>, <<node::48>>, format) do
    <<time_hi::12, time_mid::16, time_low::32>> = uuid1_time()
    <<clock_seq_hi::6, clock_seq_low::8>> = <<clock_seq::14>>
    <<time_low::32, time_mid::16, @uuid_v1::4, time_hi::12, @variant10::2,
      clock_seq_hi::6, clock_seq_low::8, node::48>>
      |> uuid_to_string(format)
  end
  def uuid1(_, _, _) do
    raise ArgumentError, message:
    "Invalid argument; Expected: <<clock_seq::14>>, <<node::48>>"
  end

  @doc """
  Generate a new UUID v3. This version uses an MD5 hash of fixed value (chosen
  based on a namespace atom - see Appendix C of
  [RFC 4122](http://www.ietf.org/rfc/rfc4122.txt) and a name value. Can also be
  given an existing UUID String instead of a namespace atom.

  Accepted arguments are: `:dns`|`:url`|`:oid`|`:x500`|`:nil` OR uuid, String

  ## Examples

  ```elixir
  iex> UUID.uuid3(:dns, "my.domain.com")
  "03bf0706-b7e9-33b8-aee5-c6142a816478"

  iex> UUID.uuid3(:dns, "my.domain.com", :default)
  "03bf0706-b7e9-33b8-aee5-c6142a816478"

  iex> UUID.uuid3(:dns, "my.domain.com", :hex)
  "03bf0706b7e933b8aee5c6142a816478"

  iex> UUID.uuid3(:dns, "my.domain.com", :urn)
  "urn:uuid:03bf0706-b7e9-33b8-aee5-c6142a816478"

  iex> UUID.uuid3(:dns, "my.domain.com", :raw)
  <<3, 191, 7, 6, 183, 233, 51, 184, 174, 229, 198, 20, 42, 129, 100, 120>>

  iex> UUID.uuid3("cdfdaf44-ee35-11e3-846b-14109ff1a304", "my.domain.com")
  "8808f33a-3e11-3708-919e-15fba88908db"

  iex> UUID.uuid3(:dns, "my.domain.com", :slug)
  "A78HBrfpM7iu5cYUKoFkeA"
  ```

  """
  def uuid3(namespace_or_uuid, name, format \\ :default)
  def uuid3(:dns, <<name::binary>>, format) do
    namebased_uuid(:md5, <<0x6ba7b8109dad11d180b400c04fd430c8::128, name::binary>>)
      |> uuid_to_string(format)
  end
  def uuid3(:url, <<name::binary>>, format) do
    namebased_uuid(:md5, <<0x6ba7b8119dad11d180b400c04fd430c8::128, name::binary>>)
      |> uuid_to_string(format)
  end
  def uuid3(:oid, <<name::binary>>, format) do
    namebased_uuid(:md5, <<0x6ba7b8129dad11d180b400c04fd430c8::128, name::binary>>)
      |> uuid_to_string(format)
  end
  def uuid3(:x500, <<name::binary>>, format) do
    namebased_uuid(:md5, <<0x6ba7b8149dad11d180b400c04fd430c8::128, name::binary>>)
      |> uuid_to_string(format)
  end
  def uuid3(:nil, <<name::binary>>, format) do
    namebased_uuid(:md5, <<0::128, name::binary>>)
      |> uuid_to_string(format)
  end
  def uuid3(<<uuid::binary>>, <<name::binary>>, format) do
    {_type, <<uuid::128>>} = uuid_string_to_hex_pair(uuid)
    namebased_uuid(:md5, <<uuid::128, name::binary>>)
      |> uuid_to_string(format)
  end
  def uuid3(_, _, _) do
    raise ArgumentError, message:
    "Invalid argument; Expected: :dns|:url|:oid|:x500|:nil OR String, String"
  end

  @doc """
  Generate a new UUID v4. This version uses pseudo-random bytes generated by
  the `crypto` module.

  ## Examples

  ```elixir
  iex> UUID.uuid4()
  "fb49a0ec-d60c-4d20-9264-3b4cfe272106"

  iex> UUID.uuid4(:default)
  "fb49a0ec-d60c-4d20-9264-3b4cfe272106"

  iex> UUID.uuid4(:hex)
  "fb49a0ecd60c4d2092643b4cfe272106"

  iex> UUID.uuid4(:urn)
  "urn:uuid:fb49a0ec-d60c-4d20-9264-3b4cfe272106"

  iex> UUID.uuid4(:raw)
  <<251, 73, 160, 236, 214, 12, 77, 32, 146, 100, 59, 76, 254, 39, 33, 6>>

  iex> UUID.uuid4(:slug)
  "-0mg7NYMTSCSZDtM_ichBg"
  ```

  """
  def uuid4(), do: uuid4(:default)

  def uuid4(:strong), do: uuid4(:default) # For backwards compatibility.
  def uuid4(:weak),   do: uuid4(:default) # For backwards compatibility.
  def uuid4(format) do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    <<u0::48, @uuid_v4::4, u1::12, @variant10::2, u2::62>>
      |> uuid_to_string(format)
  end

  @doc """
  Generate a new UUID v5. This version uses an SHA1 hash of fixed value (chosen
  based on a namespace atom - see Appendix C of
  [RFC 4122](http://www.ietf.org/rfc/rfc4122.txt) and a name value. Can also be
  given an existing UUID String instead of a namespace atom.

  Accepted arguments are: `:dns`|`:url`|`:oid`|`:x500`|`:nil` OR uuid, String

  ## Examples

  ```elixir
  iex> UUID.uuid5(:dns, "my.domain.com")
  "016c25fd-70e0-56fe-9d1a-56e80fa20b82"

  iex> UUID.uuid5(:dns, "my.domain.com", :default)
  "016c25fd-70e0-56fe-9d1a-56e80fa20b82"

  iex> UUID.uuid5(:dns, "my.domain.com", :hex)
  "016c25fd70e056fe9d1a56e80fa20b82"

  iex> UUID.uuid5(:dns, "my.domain.com", :urn)
  "urn:uuid:016c25fd-70e0-56fe-9d1a-56e80fa20b82"

  iex> UUID.uuid5(:dns, "my.domain.com", :raw)
  <<1, 108, 37, 253, 112, 224, 86, 254, 157, 26, 86, 232, 15, 162, 11, 130>>

  iex> UUID.uuid5("fb49a0ec-d60c-4d20-9264-3b4cfe272106", "my.domain.com")
  "822cab19-df58-5eb4-98b5-c96c15c76d32"

  iex> UUID.uuid5("fb49a0ec-d60c-4d20-9264-3b4cfe272106", "my.domain.com", :slug)
  "giyrGd9YXrSYtclsFcdtMg"
  ```

  """
  def uuid5(namespace_or_uuid, name, format \\ :default)
  def uuid5(:dns, <<name::binary>>, format) do
    namebased_uuid(:sha1, <<0x6ba7b8109dad11d180b400c04fd430c8::128, name::binary>>)
      |> uuid_to_string(format)
  end
  def uuid5(:url, <<name::binary>>, format) do
    namebased_uuid(:sha1, <<0x6ba7b8119dad11d180b400c04fd430c8::128, name::binary>>)
      |> uuid_to_string(format)
  end
  def uuid5(:oid, <<name::binary>>, format) do
    namebased_uuid(:sha1, <<0x6ba7b8129dad11d180b400c04fd430c8::128, name::binary>>)
      |> uuid_to_string(format)
  end
  def uuid5(:x500, <<name::binary>>, format) do
    namebased_uuid(:sha1, <<0x6ba7b8149dad11d180b400c04fd430c8::128, name::binary>>)
      |> uuid_to_string(format)
  end
  def uuid5(:nil, <<name::binary>>, format) do
    namebased_uuid(:sha1, <<0::128, name::binary>>)
      |> uuid_to_string(format)
  end
  def uuid5(<<uuid::binary>>, <<name::binary>>, format) do
    {_type, <<uuid::128>>} = uuid_string_to_hex_pair(uuid)
    namebased_uuid(:sha1, <<uuid::128, name::binary>>)
      |> uuid_to_string(format)
  end
  def uuid5(_, _, _) do
    raise ArgumentError, message:
    "Invalid argument; Expected: :dns|:url|:oid|:x500|:nil OR String, String"
  end

  #
  # Internal utility functions.
  #

  # Convert UUID bytes to String.
  defp uuid_to_string(<<_::128>> = u, :default) do
    uuid_to_string_default(u)
  end
  defp uuid_to_string(<<_::128>> = u, :hex) do
    IO.iodata_to_binary(for <<part::4 <- u>>, do: e(part))
  end
  defp uuid_to_string(<<_::128>> = u, :urn) do
    @urn <> uuid_to_string(u, :default)
  end
  defp uuid_to_string(<<_::128>> = u, :raw) do
    u
  end
  defp uuid_to_string(<<_::128>> = u, :slug) do
    Base.url_encode64(u, [padding: false])
  end
  defp uuid_to_string(_u, format) when format in [:default, :hex, :urn, :slug] do
    raise ArgumentError, message:
    "Invalid binary data; Expected: <<uuid::128>>"
  end
  defp uuid_to_string(_u, format) do
    raise ArgumentError, message:
    "Invalid format #{format}; Expected: :default|:hex|:urn|:slug"
  end

  defp uuid_to_string_default(<<
         a1::4, a2::4, a3::4, a4::4,
         a5::4, a6::4, a7::4, a8::4,
         b1::4, b2::4, b3::4, b4::4,
         c1::4, c2::4, c3::4, c4::4,
         d1::4, d2::4, d3::4, d4::4,
         e1::4, e2::4, e3::4, e4::4,
         e5::4, e6::4, e7::4, e8::4,
         e9::4, e10::4, e11::4, e12::4 >>) do
    << e(a1), e(a2), e(a3), e(a4), e(a5), e(a6), e(a7), e(a8), ?-,
       e(b1), e(b2), e(b3), e(b4), ?-,
       e(c1), e(c2), e(c3), e(c4), ?-,
       e(d1), e(d2), e(d3), e(d4), ?-,
       e(e1), e(e2), e(e3), e(e4), e(e5), e(e6), e(e7), e(e8), e(e9), e(e10), e(e11), e(e12) >>
  end

  @compile {:inline, e: 1}

  defp e(0),  do: ?0
  defp e(1),  do: ?1
  defp e(2),  do: ?2
  defp e(3),  do: ?3
  defp e(4),  do: ?4
  defp e(5),  do: ?5
  defp e(6),  do: ?6
  defp e(7),  do: ?7
  defp e(8),  do: ?8
  defp e(9),  do: ?9
  defp e(10), do: ?a
  defp e(11), do: ?b
  defp e(12), do: ?c
  defp e(13), do: ?d
  defp e(14), do: ?e
  defp e(15), do: ?f

  # Extract the type (:default etc) and pure byte value from a UUID String.
  defp uuid_string_to_hex_pair(<<_::128>> = uuid) do
    {:raw, uuid}
  end
  defp uuid_string_to_hex_pair(<<uuid_in::binary>>) do
    uuid = String.downcase(uuid_in)
    {type, hex_str} = case uuid do
      <<u0::64, ?-, u1::32, ?-, u2::32, ?-, u3::32, ?-, u4::96>> ->
        {:default, <<u0::64, u1::32, u2::32, u3::32, u4::96>>}
      <<u::256>> ->
        {:hex, <<u::256>>}
      <<@urn, u0::64, ?-, u1::32, ?-, u2::32, ?-, u3::32, ?-, u4::96>> ->
        {:urn, <<u0::64, u1::32, u2::32, u3::32, u4::96>>}
      _ ->
        case uuid_in do
          _ when byte_size(uuid_in) == 22 ->
            case Base.url_decode64(uuid_in <> "==") do
              {:ok, decoded} -> {:slug, Base.encode16(decoded)}
              _ -> raise ArgumentError, message: "Invalid argument; Not a valid UUID: #{uuid}"
            end
          _ -> raise ArgumentError, message: "Invalid argument; Not a valid UUID: #{uuid}"
        end
    end

    try do
      {type, hex_str_to_binary(hex_str)}
    catch
      _, _ ->
        raise ArgumentError, message:
          "Invalid argument; Not a valid UUID: #{uuid}"
    end
  end

  # Get unix epoch as a 60-bit timestamp.
  defp uuid1_time() do
    {mega_sec, sec, micro_sec} = :os.timestamp()
    epoch = (mega_sec * 1_000_000_000_000 + sec * 1_000_000 + micro_sec)
    timestamp = @nanosec_intervals_offset + @nanosec_intervals_factor * epoch
    <<timestamp::60>>
  end

  # Generate random clock sequence.
  defp uuid1_clockseq() do
    <<rnd::14, _::2>> = :crypto.strong_rand_bytes(2)
    <<rnd::14>>
  end

  # Get local IEEE 802 (MAC) address, or a random node id if it can't be found.
  defp uuid1_node() do
    {:ok, ifs0} = :inet.getifaddrs()
    uuid1_node(ifs0)
  end

  defp uuid1_node([{_if_name, if_config} | rest]) do
    case :lists.keyfind(:hwaddr, 1, if_config) do
      :false ->
        uuid1_node(rest)
      {:hwaddr, hw_addr} ->
        if length(hw_addr) != 6 or Enum.all?(hw_addr, fn(n) -> n == 0 end) do
          uuid1_node(rest)
        else
          :erlang.list_to_binary(hw_addr)
        end
    end
  end
  defp uuid1_node(_) do
    <<rnd_hi::7, _::1, rnd_low::40>> = :crypto.strong_rand_bytes(6)
    <<rnd_hi::7, 1::1, rnd_low::40>>
  end

  # Generate a hash of the given data.
  defp namebased_uuid(:md5, data) do
    md5 = :crypto.hash(:md5, data)
    compose_namebased_uuid(@uuid_v3, md5)
  end
  defp namebased_uuid(:sha1, data) do
    <<sha1::128, _::32>> = :crypto.hash(:sha, data)
    compose_namebased_uuid(@uuid_v5, <<sha1::128>>)
  end

  # Format the given hash as a UUID.
  defp compose_namebased_uuid(version, hash) do
    <<time_low::32, time_mid::16, _::4, time_hi::12, _::2,
      clock_seq_hi::6, clock_seq_low::8, node::48>> = hash
    <<time_low::32, time_mid::16, version::4, time_hi::12, @variant10::2,
      clock_seq_hi::6, clock_seq_low::8, node::48>>
  end

  # Identify the UUID variant according to section 4.1.1 of RFC 4122.
  defp variant(<<1, 1, 1>>) do
    :reserved_future
  end
  defp variant(<<1, 1, _v>>) do
    :reserved_microsoft
  end
  defp variant(<<1, 0, _v>>) do
    :rfc4122
  end
  defp variant(<<0, _v::2-binary>>) do
    :reserved_ncs
  end
  defp variant(_) do
    raise ArgumentError, message: "Invalid argument; Not valid variant bits"
  end
  
  defp hex_str_to_binary(<< a1, a2, a3, a4, a5, a6, a7, a8,
                            b1, b2, b3, b4,
                            c1, c2, c3, c4,
                            d1, d2, d3, d4,
                            e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12 >>) do
    << d(a1)::4, d(a2)::4, d(a3)::4, d(a4)::4,
        d(a5)::4, d(a6)::4, d(a7)::4, d(a8)::4,
        d(b1)::4, d(b2)::4, d(b3)::4, d(b4)::4,
        d(c1)::4, d(c2)::4, d(c3)::4, d(c4)::4,
        d(d1)::4, d(d2)::4, d(d3)::4, d(d4)::4,
        d(e1)::4, d(e2)::4, d(e3)::4, d(e4)::4,
        d(e5)::4, d(e6)::4, d(e7)::4, d(e8)::4,
        d(e9)::4, d(e10)::4, d(e11)::4, d(e12)::4 >>
  end
  
  @compile {:inline, d: 1}

  defp d(?0), do: 0
  defp d(?1), do: 1
  defp d(?2), do: 2
  defp d(?3), do: 3
  defp d(?4), do: 4
  defp d(?5), do: 5
  defp d(?6), do: 6
  defp d(?7), do: 7
  defp d(?8), do: 8
  defp d(?9), do: 9
  defp d(?A), do: 10
  defp d(?B), do: 11
  defp d(?C), do: 12
  defp d(?D), do: 13
  defp d(?E), do: 14
  defp d(?F), do: 15
  defp d(?a), do: 10
  defp d(?b), do: 11
  defp d(?c), do: 12
  defp d(?d), do: 13
  defp d(?e), do: 14
  defp d(?f), do: 15
  defp d(_), do: throw(:error)
end
