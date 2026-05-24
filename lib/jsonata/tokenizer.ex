defmodule Jsonata.Tokenizer do
  @moduledoc """
  Binary-pattern-matching lexer for JSONata source.

  The lexer is *pull-based*: `next/3` returns one token at a time and takes a
  `prefix` flag that disambiguates `/` — when a value/operand has just been
  consumed (`prefix: true`) a `/` is division, otherwise it begins a regular
  expression. This mirrors the reference implementation, where the parser drives
  the lexer and supplies that context.

  `tokenize/1` is a convenience that produces the full token list, applying the
  same operand-completion rule the parser uses to set `prefix`.
  """

  alias Jsonata.{Error, Token}

  @ws_bytes ~c" \t\n\r\v"
  @op_bytes ~c".[]{}(),@#;:?+-*/%|=<>^&!~"
  @stop_bytes @ws_bytes ++ @op_bytes

  @number_regex ~r/\A(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[Ee][-+]?[0-9]+)?/

  @typedoc "Result of scanning one token."
  @type result ::
          {:ok, Token.t() | :eof, non_neg_integer()} | {:error, Error.t()}

  @doc """
  Tokenizes `source` into a list of `Jsonata.Token` structs.

  Returns `{:ok, tokens}` or `{:error, %Jsonata.Error{}}` on the first lexical
  error.
  """
  @spec tokenize(binary()) :: {:ok, [Token.t()]} | {:error, Error.t()}
  def tokenize(source) when is_binary(source), do: collect(source, 0, false, [])

  defp collect(source, pos, prefix, acc) do
    case next(source, pos, prefix) do
      {:ok, :eof, _pos} -> {:ok, Enum.reverse(acc)}
      {:ok, token, new_pos} -> collect(source, new_pos, operand?(token), [token | acc])
      {:error, _error} = error -> error
    end
  end

  # Whether a `/` immediately after this token is division rather than a regex.
  defp operand?(%Token{type: type})
       when type in [:number, :string, :name, :variable, :value, :regex],
       do: true

  defp operand?(%Token{type: :operator, value: value}) when value in [")", "]", "}"], do: true
  defp operand?(_token), do: false

  @doc """
  Scans the next token from `source` starting at byte offset `pos`.

  `prefix: true` indicates an operand has just been read, so a leading `/` is
  treated as the division operator instead of the start of a regex.
  """
  @spec next(binary(), non_neg_integer(), boolean()) :: result()
  def next(source, pos \\ 0, prefix \\ false) when is_binary(source) do
    rest = binary_part(source, pos, byte_size(source) - pos)
    {rest, pos} = skip_whitespace(rest, pos)
    scan(rest, pos, source, prefix)
  end

  defp skip_whitespace(<<c, rest::binary>>, pos) when c in @ws_bytes,
    do: skip_whitespace(rest, pos + 1)

  defp skip_whitespace(rest, pos), do: {rest, pos}

  # End of input.
  defp scan(<<>>, pos, _source, _prefix), do: {:ok, :eof, pos}

  # Block comment.
  defp scan(<<"/*", rest::binary>>, pos, source, prefix) do
    case skip_comment(rest, pos + 2) do
      {:ok, rest, pos} ->
        {rest, pos} = skip_whitespace(rest, pos)
        scan(rest, pos, source, prefix)

      :error ->
        {:error, Error.new("S0106", position: pos)}
    end
  end

  # Regex literal (only when an operand is not expected).
  defp scan(<<"/", rest::binary>>, pos, source, false),
    do: scan_regex(rest, pos + 1, source)

  # Two-character operators (must precede the single-character clause).
  for op <- ~w(.. := != >= <= ** ~> ?: ??) do
    defp scan(<<unquote(op), _::binary>>, pos, _source, _prefix),
      do: operator(unquote(op), pos, 2)
  end

  # Single-character operators.
  defp scan(<<c, _::binary>>, pos, _source, _prefix) when c in @op_bytes,
    do: operator(<<c>>, pos, 1)

  # String literals.
  defp scan(<<q, rest::binary>>, pos, _source, _prefix) when q in [?", ?'],
    do: scan_string(rest, pos + 1, q, [])

  # Numbers.
  defp scan(<<c, _::binary>> = rest, pos, _source, _prefix) when c in ?0..?9,
    do: scan_number(rest, pos)

  # Backtick-quoted names.
  defp scan(<<"`", rest::binary>>, pos, source, _prefix) do
    case :binary.match(rest, "`") do
      {idx, 1} ->
        name = binary_part(rest, 0, idx)
        token(:name, name, pos + 1 + idx + 1)

      :nomatch ->
        {:error, Error.new("S0105", position: byte_size(source))}
    end
  end

  # Names, variables, and keywords.
  defp scan(rest, pos, _source, _prefix) do
    len = name_length(rest, 0)
    raw = binary_part(rest, 0, len)
    classify_name(raw, pos + len)
  end

  defp classify_name("$" <> name, end_pos), do: token(:variable, name, end_pos)
  defp classify_name(kw, end_pos) when kw in ~w(and or in), do: token(:operator, kw, end_pos)
  defp classify_name("true", end_pos), do: token(:value, true, end_pos)
  defp classify_name("false", end_pos), do: token(:value, false, end_pos)
  defp classify_name("null", end_pos), do: token(:value, nil, end_pos)
  defp classify_name(name, end_pos), do: token(:name, name, end_pos)

  defp name_length(<<c, rest::binary>>, n) when c not in @stop_bytes,
    do: name_length(rest, n + 1)

  defp name_length(_rest, n), do: n

  defp skip_comment(<<"*/", rest::binary>>, pos), do: {:ok, rest, pos + 2}
  defp skip_comment(<<>>, _pos), do: :error
  defp skip_comment(<<_c, rest::binary>>, pos), do: skip_comment(rest, pos + 1)

  defp scan_string(<<>>, pos, _q, _acc), do: {:error, Error.new("S0101", position: pos)}

  defp scan_string(<<"\\u", rest::binary>>, pos, q, acc),
    do: scan_unicode(rest, pos + 2, q, acc)

  defp scan_string(<<?\\, c, rest::binary>>, pos, q, acc) do
    case unescape(c) do
      {:ok, ch} -> scan_string(rest, pos + 2, q, [acc, ch])
      :error -> {:error, Error.new("S0103", position: pos + 1, token: <<c>>)}
    end
  end

  defp scan_string(<<?\\>>, pos, _q, _acc), do: {:error, Error.new("S0101", position: pos + 1)}

  defp scan_string(<<q, _rest::binary>>, pos, q, acc),
    do: token(:string, IO.iodata_to_binary(acc), pos + 1)

  defp scan_string(<<c::utf8, rest::binary>>, pos, q, acc) do
    char = <<c::utf8>>
    scan_string(rest, pos + byte_size(char), q, [acc, char])
  end

  defp unescape(?"), do: {:ok, "\""}
  defp unescape(?\\), do: {:ok, "\\"}
  defp unescape(?/), do: {:ok, "/"}
  defp unescape(?b), do: {:ok, "\b"}
  defp unescape(?f), do: {:ok, "\f"}
  defp unescape(?n), do: {:ok, "\n"}
  defp unescape(?r), do: {:ok, "\r"}
  defp unescape(?t), do: {:ok, "\t"}
  defp unescape(_other), do: :error

  defp scan_unicode(<<hex::binary-size(4), rest::binary>>, pos, q, acc) do
    case Integer.parse(hex, 16) do
      {codepoint, ""} -> append_codepoint(codepoint, rest, pos + 4, q, acc)
      _not_hex -> {:error, Error.new("S0104", position: pos)}
    end
  end

  defp scan_unicode(_short, pos, _q, _acc), do: {:error, Error.new("S0104", position: pos)}

  # High surrogate followed by a valid low surrogate: combine into one codepoint.
  defp append_codepoint(hi, <<"\\u", low_hex::binary-size(4), rest::binary>>, pos, q, acc)
       when hi in 0xD800..0xDBFF do
    case Integer.parse(low_hex, 16) do
      {lo, ""} when lo in 0xDC00..0xDFFF ->
        codepoint = 0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)
        scan_string(rest, pos + 6, q, [acc, <<codepoint::utf8>>])

      _invalid_pair ->
        {:error, Error.new("S0104", position: pos)}
    end
  end

  # Lone surrogate: not representable as UTF-8 (Divergence DV-1).
  defp append_codepoint(codepoint, _rest, pos, _q, _acc) when codepoint in 0xD800..0xDFFF,
    do: {:error, Error.new("S0104", position: pos)}

  defp append_codepoint(codepoint, rest, pos, q, acc),
    do: scan_string(rest, pos, q, [acc, <<codepoint::utf8>>])

  defp scan_number(rest, pos) do
    [match] = Regex.run(@number_regex, rest, capture: :first)
    len = byte_size(match)

    case parse_number(match) do
      {:ok, number} -> token(:number, number, pos + len)
      :error -> {:error, Error.new("S0102", position: pos, token: match)}
    end
  end

  defp parse_number(text) do
    parsed =
      if String.contains?(text, [".", "e", "E"]),
        do: Float.parse(text),
        else: Integer.parse(text)

    case parsed do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

  defp scan_regex(rest, pos, source) do
    case find_regex_end(rest, 0, 0, false) do
      {:ok, 0} ->
        {:error, Error.new("S0301", position: pos)}

      {:ok, end_idx} ->
        pattern = binary_part(rest, 0, end_idx)
        after_slash = binary_part(rest, end_idx + 1, byte_size(rest) - end_idx - 1)
        {flags, flags_len} = take_flags(after_slash, [])
        end_pos = pos + end_idx + 1 + flags_len
        token(:regex, %{pattern: pattern, flags: flags}, end_pos)

      :error ->
        {:error, Error.new("S0302", position: byte_size(source))}
    end
  end

  defp find_regex_end(<<>>, _idx, _depth, _escaped), do: :error

  defp find_regex_end(<<_c, rest::binary>>, idx, depth, true),
    do: find_regex_end(rest, idx + 1, depth, false)

  defp find_regex_end(<<?\\, rest::binary>>, idx, depth, false),
    do: find_regex_end(rest, idx + 1, depth, true)

  defp find_regex_end(<<?/, _rest::binary>>, idx, 0, false), do: {:ok, idx}

  defp find_regex_end(<<c, rest::binary>>, idx, depth, false) when c in [?(, ?[, ?{],
    do: find_regex_end(rest, idx + 1, depth + 1, false)

  defp find_regex_end(<<c, rest::binary>>, idx, depth, false) when c in [?), ?], ?}],
    do: find_regex_end(rest, idx + 1, depth - 1, false)

  defp find_regex_end(<<_c, rest::binary>>, idx, depth, false),
    do: find_regex_end(rest, idx + 1, depth, false)

  defp take_flags(<<?i, rest::binary>>, acc), do: take_flags(rest, [acc, ?i])
  defp take_flags(<<?m, rest::binary>>, acc), do: take_flags(rest, [acc, ?m])

  defp take_flags(_rest, acc) do
    flags = IO.iodata_to_binary(acc)
    {flags, byte_size(flags)}
  end

  defp operator(value, pos, len), do: token(:operator, value, pos + len)

  defp token(type, value, end_pos),
    do: {:ok, %Token{type: type, value: value, position: end_pos}, end_pos}
end
