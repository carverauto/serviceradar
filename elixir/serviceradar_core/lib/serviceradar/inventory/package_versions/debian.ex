defmodule ServiceRadar.Inventory.PackageVersions.Debian do
  @moduledoc """
  Compares Debian package versions using the ordering defined by Debian Policy.
  """

  @type ordering :: :lt | :eq | :gt

  @spec compare(String.t(), String.t()) :: {:ok, ordering()} | {:error, :invalid_version}
  def compare(left, right) when is_binary(left) and is_binary(right) do
    with {:ok, left_version} <- parse(left),
         {:ok, right_version} <- parse(right) do
      {:ok, compare_parsed(left_version, right_version)}
    end
  end

  def compare(_left, _right), do: {:error, :invalid_version}

  defp parse(version) do
    with {:ok, epoch, package_version} <- split_epoch(version),
         {:ok, upstream, revision} <- split_revision(package_version),
         :ok <- validate_upstream(upstream),
         :ok <- validate_revision(revision) do
      {:ok, %{epoch: epoch, upstream: upstream, revision: revision}}
    else
      _ -> {:error, :invalid_version}
    end
  end

  defp split_epoch(version) do
    case String.split(version, ":", parts: 2) do
      [package_version] -> {:ok, 0, package_version}
      [epoch, package_version] -> parse_epoch(epoch, package_version)
    end
  end

  defp parse_epoch(epoch, package_version) do
    if epoch != "" and package_version != "" and String.match?(epoch, ~r/\A\d+\z/) and
         not String.contains?(package_version, ":") do
      {:ok, String.to_integer(epoch), package_version}
    else
      {:error, :invalid_version}
    end
  end

  defp split_revision(package_version) do
    case String.split(package_version, "-", trim: false) do
      [upstream] ->
        {:ok, upstream, "0"}

      segments ->
        revision = List.last(segments)
        upstream = segments |> Enum.drop(-1) |> Enum.join("-")
        {:ok, upstream, revision}
    end
  end

  defp validate_upstream(<<first, _rest::binary>> = upstream) when first >= ?0 and first <= ?9 do
    if String.match?(upstream, ~r/\A[A-Za-z0-9.+~\-]+\z/),
      do: :ok,
      else: {:error, :invalid_version}
  end

  defp validate_upstream(_upstream), do: {:error, :invalid_version}

  defp validate_revision(revision) do
    if String.match?(revision, ~r/\A[A-Za-z0-9.+~]+\z/), do: :ok, else: {:error, :invalid_version}
  end

  defp compare_parsed(left, right) do
    case compare_integers(left.epoch, right.epoch) do
      :eq ->
        case compare_part(left.upstream, right.upstream) do
          :eq -> compare_part(left.revision, right.revision)
          ordering -> ordering
        end

      ordering ->
        ordering
    end
  end

  defp compare_part(left, right) do
    {left_non_digits, left_digits_and_rest} = take_non_digits(left)
    {right_non_digits, right_digits_and_rest} = take_non_digits(right)

    case compare_non_digits(left_non_digits, right_non_digits) do
      :eq ->
        {left_digits, left_rest} = take_digits(left_digits_and_rest)
        {right_digits, right_rest} = take_digits(right_digits_and_rest)

        case compare_digits(left_digits, right_digits) do
          :eq ->
            if left_rest == "" and right_rest == "" do
              :eq
            else
              compare_part(left_rest, right_rest)
            end

          ordering ->
            ordering
        end

      ordering ->
        ordering
    end
  end

  defp take_non_digits(version), do: take_non_digits(version, version, 0)

  defp take_non_digits(original, <<digit, _rest::binary>>, size)
       when digit >= ?0 and digit <= ?9 do
    {binary_part(original, 0, size), binary_part(original, size, byte_size(original) - size)}
  end

  defp take_non_digits(original, <<_character, rest::binary>>, size) do
    take_non_digits(original, rest, size + 1)
  end

  defp take_non_digits(original, <<>>, size) do
    {binary_part(original, 0, size), ""}
  end

  defp take_digits(version), do: take_digits(version, version, 0)

  defp take_digits(original, <<digit, rest::binary>>, size) when digit >= ?0 and digit <= ?9 do
    take_digits(original, rest, size + 1)
  end

  defp take_digits(original, _rest, size) do
    {binary_part(original, 0, size), binary_part(original, size, byte_size(original) - size)}
  end

  defp compare_non_digits(<<>>, <<>>), do: :eq

  defp compare_non_digits(<<>>, <<right, right_rest::binary>>) do
    0
    |> compare_integers(character_order(right))
    |> continue_non_digit_comparison(<<>>, right_rest)
  end

  defp compare_non_digits(<<left, left_rest::binary>>, <<>>) do
    left
    |> character_order()
    |> compare_integers(0)
    |> continue_non_digit_comparison(left_rest, <<>>)
  end

  defp compare_non_digits(<<left, left_rest::binary>>, <<right, right_rest::binary>>) do
    left
    |> character_order()
    |> compare_integers(character_order(right))
    |> continue_non_digit_comparison(left_rest, right_rest)
  end

  defp continue_non_digit_comparison(:eq, left, right), do: compare_non_digits(left, right)
  defp continue_non_digit_comparison(ordering, _left, _right), do: ordering

  defp character_order(?~), do: -1
  defp character_order(character) when character in ?A..?Z, do: character
  defp character_order(character) when character in ?a..?z, do: character
  defp character_order(character), do: character + 256

  defp compare_digits(left, right) do
    left = String.trim_leading(left, "0")
    right = String.trim_leading(right, "0")

    case compare_integers(byte_size(left), byte_size(right)) do
      :eq -> compare_binaries(left, right)
      ordering -> ordering
    end
  end

  defp compare_integers(left, right) when left < right, do: :lt
  defp compare_integers(left, right) when left > right, do: :gt
  defp compare_integers(_left, _right), do: :eq

  defp compare_binaries(left, right) when left < right, do: :lt
  defp compare_binaries(left, right) when left > right, do: :gt
  defp compare_binaries(_left, _right), do: :eq
end
