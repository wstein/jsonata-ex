defmodule Jsonata.FormatNumber do
  @moduledoc """
  `$formatNumber` — the XPath F&O `fn:format-number` DecimalFormat (ported from
  `functions.js`).

  Supports the full sub-picture grammar: mandatory/optional digits, grouping
  separators (regular and irregular), the decimal separator, percent/per-mille
  scaling, exponent notation, prefixes/suffixes, the positive;negative pattern
  pair, and a `properties` options object overriding the formatting symbols.
  Picture validation raises the `D3080`–`D3093` error codes.
  """

  alias Jsonata.{Error, Functions}

  @defaults %{
    "decimal-separator" => ".",
    "grouping-separator" => ",",
    "exponent-separator" => "e",
    "infinity" => "Infinity",
    "minus-sign" => "-",
    "NaN" => "NaN",
    "percent" => "%",
    "per-mille" => "‰",
    "zero-digit" => "0",
    "digit" => "#",
    "pattern-separator" => ";"
  }

  @doc "Formats `value` using DecimalFormat `picture`, with optional `options` overrides."
  @spec format_number(term(), String.t(), map() | :undefined) :: term()
  def format_number(:undefined, _picture, _options), do: :undefined

  def format_number(value, picture, options) do
    props = merge_options(options)
    family = digit_family(props)
    active = active_chars(family, props)

    sub_pictures = String.split(picture, props["pattern-separator"])
    if length(sub_pictures) > 2, do: raise(Error.new("D3080"))

    variables =
      sub_pictures
      |> Enum.map(&split_parts(&1, props, active))
      |> tap(fn parts -> Enum.each(parts, &validate(&1, props, family, active)) end)
      |> Enum.map(&analyse(&1, props, family))
      |> with_negative_picture(props)

    pic = if value >= 0, do: Enum.at(variables, 0), else: Enum.at(variables, 1)
    do_format(value * 1.0, pic, props, family)
  end

  # --- properties -----------------------------------------------------------

  defp merge_options(:undefined), do: @defaults
  # the options object may be an ordered Jsonata.Object — normalise to a plain map
  defp merge_options(options), do: Map.merge(@defaults, Map.new(Jsonata.Object.pairs(options)))

  defp digit_family(props) do
    <<zero::utf8>> = props["zero-digit"]
    Enum.map(zero..(zero + 9), &<<&1::utf8>>)
  end

  defp active_chars(family, props) do
    family ++
      [
        props["decimal-separator"],
        props["exponent-separator"],
        props["grouping-separator"],
        props["digit"],
        props["pattern-separator"]
      ]
  end

  # --- sub-picture splitting (F&O 4.7.3) ------------------------------------

  defp split_parts(subpicture, props, active) do
    exp_sep = props["exponent-separator"]
    chars = String.graphemes(subpicture)
    prefix = take_prefix(chars, active, exp_sep)
    suffix = take_suffix(chars, active, exp_sep)
    active_part = slice_between(subpicture, String.length(prefix), String.length(suffix))

    {mantissa, exponent} = split_exponent(subpicture, prefix, suffix, active_part, props)
    {integer, fractional} = split_decimal(mantissa, suffix, props)

    %{
      prefix: prefix,
      suffix: suffix,
      active_part: active_part,
      mantissa_part: mantissa,
      exponent_part: exponent,
      integer_part: integer,
      fractional_part: fractional,
      subpicture: subpicture
    }
  end

  # leading run of passive characters (before the first non-exponent active char)
  defp take_prefix(chars, active, exp_sep) do
    chars
    |> Enum.take_while(&(&1 not in active or &1 == exp_sep))
    |> Enum.join()
  end

  defp take_suffix(chars, active, exp_sep) do
    chars
    |> Enum.reverse()
    |> Enum.take_while(&(&1 not in active or &1 == exp_sep))
    |> Enum.reverse()
    |> Enum.join()
  end

  defp slice_between(string, prefix_len, suffix_len) do
    String.slice(string, prefix_len, String.length(string) - prefix_len - suffix_len)
  end

  defp split_exponent(subpicture, prefix, suffix, active_part, props) do
    exp_pos = index_of(subpicture, props["exponent-separator"], String.length(prefix))
    boundary = String.length(subpicture) - String.length(suffix)

    if exp_pos == -1 or exp_pos > boundary do
      {active_part, :undefined}
    else
      pos = index_of(active_part, props["exponent-separator"], 0)
      {String.slice(active_part, 0, pos), String.slice(active_part, (pos + 1)..-1//1)}
    end
  end

  defp split_decimal(mantissa, suffix, props) do
    case index_of(mantissa, props["decimal-separator"], 0) do
      -1 -> {mantissa, suffix}
      pos -> {String.slice(mantissa, 0, pos), String.slice(mantissa, (pos + 1)..-1//1)}
    end
  end

  # --- validation (F&O 4.7.3) -----------------------------------------------

  defp validate(parts, props, family, active) do
    sub = parts.subpicture

    [
      {single?(sub, props["decimal-separator"]), "D3081"},
      {single?(sub, props["percent"]), "D3082"},
      {single?(sub, props["per-mille"]), "D3083"},
      {not (contains?(sub, props["percent"]) and contains?(sub, props["per-mille"])), "D3084"},
      {has_digit?(parts.mantissa_part, family, props), "D3085"},
      {no_passive_in_active?(parts.active_part, active), "D3086"},
      {grouping_not_adjacent_decimal?(parts, props), "D3087"},
      {not String.ends_with?(parts.integer_part, props["grouping-separator"]) or
         contains?(sub, props["decimal-separator"]), "D3088"},
      {not contains?(sub, props["grouping-separator"] <> props["grouping-separator"]), "D3089"},
      {integer_digits_before_optional_ok?(parts.integer_part, family, props), "D3090"},
      {fraction_optional_before_digits_ok?(parts.fractional_part, family, props), "D3091"},
      {exponent_no_percent?(parts, sub, props), "D3092"},
      {exponent_well_formed?(parts, family), "D3093"}
    ]
    |> Enum.find(fn {ok?, _code} -> not ok? end)
    |> case do
      nil -> :ok
      {_ok?, code} -> raise(Error.new(code))
    end
  end

  defp single?(string, char), do: index_of(string, char, 0) == last_index_of(string, char)

  defp has_digit?(part, family, props) do
    part |> String.graphemes() |> Enum.any?(&(&1 in family or &1 == props["digit"]))
  end

  defp no_passive_in_active?(active_part, active) do
    not (active_part |> String.graphemes() |> Enum.any?(&(&1 not in active)))
  end

  defp grouping_not_adjacent_decimal?(parts, props) do
    sub = parts.subpicture
    sep = props["grouping-separator"]

    case index_of(sub, props["decimal-separator"], 0) do
      -1 -> true
      pos -> char_at(sub, pos - 1) != sep and char_at(sub, pos + 1) != sep
    end
  end

  defp integer_digits_before_optional_ok?(integer_part, family, props) do
    case index_of(integer_part, props["digit"], 0) do
      -1 ->
        true

      pos ->
        not (integer_part
             |> String.slice(0, pos)
             |> String.graphemes()
             |> Enum.any?(&(&1 in family)))
    end
  end

  defp fraction_optional_before_digits_ok?(fractional_part, family, props) do
    case last_index_of(fractional_part, props["digit"]) do
      -1 ->
        true

      pos ->
        not (fractional_part
             |> String.slice(pos..-1//1)
             |> String.graphemes()
             |> Enum.any?(&(&1 in family)))
    end
  end

  defp exponent_no_percent?(parts, sub, props) do
    exp = parts.exponent_part

    not (is_binary(exp) and exp != "" and
           (contains?(sub, props["percent"]) or contains?(sub, props["per-mille"])))
  end

  defp exponent_well_formed?(parts, family) do
    case parts.exponent_part do
      exp when is_binary(exp) ->
        exp != "" and not (exp |> String.graphemes() |> Enum.any?(&(&1 not in family)))

      _ ->
        true
    end
  end

  # --- analysis (F&O 4.7.4) -------------------------------------------------

  defp analyse(parts, props, family) do
    integer_positions = grouping_positions(parts.integer_part, props, family, false)
    fractional_positions = grouping_positions(parts.fractional_part, props, family, true)
    min_integer = count(parts.integer_part, family)
    frac_chars = String.graphemes(parts.fractional_part)
    min_fraction = Enum.count(frac_chars, &(&1 in family))
    max_fraction = Enum.count(frac_chars, &(&1 in family or &1 == props["digit"]))
    exponent? = is_binary(parts.exponent_part)

    {min_integer, min_fraction, max_fraction} =
      adjust_sizes(min_integer, min_fraction, max_fraction, exponent?, parts, props, family)

    %{
      integer_part_grouping_positions: integer_positions,
      regular_grouping: regular(integer_positions),
      minimum_integer_part_size: min_integer,
      scaling_factor: count(parts.integer_part, family),
      prefix: parts.prefix,
      fractional_part_grouping_positions: fractional_positions,
      minimum_fractional_part_size: min_fraction,
      maximum_fractional_part_size: max_fraction,
      minimum_exponent_size: minimum_exponent_size(parts, family),
      suffix: parts.suffix,
      picture: parts.subpicture
    }
  end

  defp adjust_sizes(min_int, min_frac, max_frac, exponent?, parts, props, _family) do
    {min_int, min_frac, max_frac}
    |> adjust_empty(exponent?)
    |> adjust_exponent_integer(exponent?, parts, props)
    |> adjust_min_fraction()
  end

  # an empty mantissa defaults to one integer digit (or one fractional, with an exponent)
  defp adjust_empty({0, _min_frac, 0}, true), do: {0, 1, 1}
  defp adjust_empty({0, min_frac, 0}, false), do: {1, min_frac, 0}
  defp adjust_empty(sizes, _exponent?), do: sizes

  defp adjust_exponent_integer({0, min_frac, max_frac}, true, parts, props) do
    min_int = if contains?(parts.integer_part, props["digit"]), do: 1, else: 0
    {min_int, min_frac, max_frac}
  end

  defp adjust_exponent_integer(sizes, _exponent?, _parts, _props), do: sizes

  defp adjust_min_fraction({0, 0, max_frac}), do: {0, 1, max_frac}
  defp adjust_min_fraction(sizes), do: sizes

  defp minimum_exponent_size(parts, family) do
    case parts.exponent_part do
      exp when is_binary(exp) -> count(exp, family)
      _ -> 0
    end
  end

  # number of digit/optional positions to the right (or left) of each separator
  defp grouping_positions(part, props, family, to_left) do
    sep = props["grouping-separator"]

    part
    |> all_indexes(sep)
    |> Enum.map(fn pos ->
      segment = if to_left, do: String.slice(part, 0, pos), else: String.slice(part, pos..-1//1)
      segment |> String.graphemes() |> Enum.count(&(&1 in family or &1 == props["digit"]))
    end)
  end

  # the grouping interval if positions are evenly spaced, else 0
  defp regular([]), do: 0

  defp regular(positions) do
    factor = Enum.reduce(positions, &Integer.gcd/2)

    if Enum.all?(1..length(positions), &((&1 * factor) in positions)), do: factor, else: 0
  end

  defp count(part, family), do: part |> String.graphemes() |> Enum.count(&(&1 in family))

  defp with_negative_picture([positive] = _variables, props) do
    [positive, %{positive | prefix: props["minus-sign"] <> positive.prefix}]
  end

  defp with_negative_picture(variables, _props), do: variables

  # --- formatting (F&O 4.7.4 bullets 1-14) ----------------------------------

  defp do_format(value, pic, props, family) do
    zero = props["zero-digit"]
    adjusted = scale(value, pic, props)
    {mantissa, exponent} = mantissa_exponent(adjusted, pic)
    rounded = round_to(mantissa, pic.maximum_fractional_part_size)

    string_value =
      rounded
      |> make_string(pic.maximum_fractional_part_size, family)
      |> ensure_decimal(props)
      |> strip_outer_zeros(zero)

    decimal_pos = index_of(string_value, props["decimal-separator"], 0)

    string_value
    |> pad(decimal_pos, pic, zero, props)
    |> integer_grouping(pic, props)
    |> fractional_grouping(pic, props)
    |> trim_trailing_separator(pic, props)
    |> append_exponent(exponent, pic, props, family)
    |> then(&(pic.prefix <> &1 <> pic.suffix))
  end

  defp scale(value, pic, props) do
    cond do
      contains?(pic.picture, props["percent"]) -> value * 100
      contains?(pic.picture, props["per-mille"]) -> value * 1000
      true -> value
    end
  end

  defp mantissa_exponent(adjusted, %{minimum_exponent_size: 0}), do: {adjusted, :undefined}

  defp mantissa_exponent(adjusted, pic) do
    max_mantissa = :math.pow(10, pic.scaling_factor)
    min_mantissa = :math.pow(10, pic.scaling_factor - 1)

    if adjusted == 0.0,
      do: {0.0, 0},
      else: normalise_mantissa(adjusted, 0, min_mantissa, max_mantissa)
  end

  defp normalise_mantissa(m, e, min, max) when abs(m) < min,
    do: normalise_mantissa(m * 10, e - 1, min, max)

  defp normalise_mantissa(m, e, min, max) when abs(m) > max,
    do: normalise_mantissa(m / 10, e + 1, min, max)

  defp normalise_mantissa(m, e, _min, _max), do: {m, e}

  defp ensure_decimal(string_value, props) do
    sep = props["decimal-separator"]

    case index_of(string_value, ".", 0) do
      -1 -> string_value <> sep
      _ -> String.replace(string_value, ".", sep)
    end
  end

  defp strip_outer_zeros(string_value, zero) do
    string_value
    |> strip_leading(zero)
    |> strip_trailing(zero)
  end

  defp strip_leading(<<>>, _zero), do: <<>>

  defp strip_leading(string, zero) do
    if String.starts_with?(string, zero),
      do:
        strip_leading(
          binary_part(string, byte_size(zero), byte_size(string) - byte_size(zero)),
          zero
        ),
      else: string
  end

  defp strip_trailing(<<>>, _zero), do: <<>>

  defp strip_trailing(string, zero) do
    if String.ends_with?(string, zero),
      do: strip_trailing(binary_part(string, 0, byte_size(string) - byte_size(zero)), zero),
      else: string
  end

  defp pad(string_value, decimal_pos, pic, zero, _props) do
    pad_left = pic.minimum_integer_part_size - decimal_pos
    pad_right = pic.minimum_fractional_part_size - (String.length(string_value) - decimal_pos - 1)
    left = if pad_left > 0, do: String.duplicate(zero, pad_left), else: ""
    right = if pad_right > 0, do: String.duplicate(zero, pad_right), else: ""
    left <> string_value <> right
  end

  defp integer_grouping(string_value, %{regular_grouping: factor}, props) when factor > 0 do
    decimal_pos = index_of(string_value, props["decimal-separator"], 0)
    sep = props["grouping-separator"]
    group_count = div(decimal_pos - 1, factor)

    Enum.reduce(1..group_count//1, string_value, fn group, acc ->
      insert_at(acc, decimal_pos - group * factor, sep)
    end)
  end

  defp integer_grouping(string_value, pic, props) do
    sep = props["grouping-separator"]
    decimal_pos = index_of(string_value, props["decimal-separator"], 0)

    {result, _pos} =
      Enum.reduce(pic.integer_part_grouping_positions, {string_value, decimal_pos}, fn pos,
                                                                                       {acc, dpos} ->
        {insert_at(acc, dpos - pos, sep), dpos + 1}
      end)

    result
  end

  defp fractional_grouping(string_value, pic, props) do
    sep = props["grouping-separator"]
    decimal_pos = index_of(string_value, props["decimal-separator"], 0)

    Enum.reduce(pic.fractional_part_grouping_positions, string_value, fn pos, acc ->
      insert_at(acc, pos + decimal_pos + 1, sep)
    end)
  end

  defp trim_trailing_separator(string_value, pic, props) do
    sep = props["decimal-separator"]
    decimal_pos = index_of(string_value, sep, 0)

    if not contains?(pic.picture, sep) or decimal_pos == String.length(string_value) - 1,
      do: String.slice(string_value, 0, String.length(string_value) - 1),
      else: string_value
  end

  defp append_exponent(string_value, :undefined, _pic, _props, _family), do: string_value

  defp append_exponent(string_value, exponent, pic, props, family) do
    string_exp = make_string(exponent, 0, family)
    pad_left = pic.minimum_exponent_size - String.length(string_exp)

    string_exp =
      if pad_left > 0,
        do: String.duplicate(props["zero-digit"], pad_left) <> string_exp,
        else: string_exp

    sign = if exponent < 0, do: props["minus-sign"], else: ""
    string_value <> props["exponent-separator"] <> sign <> string_exp
  end

  # --- rounding & digit rendering -------------------------------------------

  # $round (round half to even), via decimal-shift on the string form to dodge
  # the float-precision errors that scaling by powers of ten introduces.
  defp round_to(arg, 0), do: fix_negative_zero(round_half_even(arg))

  defp round_to(arg, precision) do
    shifted = shift(arg, precision)
    rounded = round_half_even(shifted)
    fix_negative_zero(shift(rounded, -precision))
  end

  defp shift(value, precision) do
    [mantissa | exp] = String.split(Functions.number_to_string(value), "e")
    exponent = if exp == [], do: precision, else: String.to_integer(hd(exp)) + precision
    {number, ""} = Float.parse(mantissa <> "e" <> Integer.to_string(exponent))
    number
  end

  defp round_half_even(arg) do
    result = Float.floor(arg + 0.5)
    diff = result - arg

    if abs(diff) == 0.5 and abs(rem(trunc(result), 2)) == 1, do: result - 1, else: result
  end

  # normalise -0.0 to +0.0 (JSON has no negative zero)
  defp fix_negative_zero(value), do: value + 0.0

  defp make_string(value, dp, family) do
    str = :erlang.float_to_binary(abs(value) * 1.0, [{:decimals, dp}])
    if hd(family) == "0", do: str, else: remap_digits(str, family)
  end

  defp remap_digits(str, family) do
    str
    |> String.graphemes()
    |> Enum.map_join(fn
      <<code>> when code in ?0..?9 -> Enum.at(family, code - ?0)
      other -> other
    end)
  end

  # --- string index helpers (0-based, JS semantics) -------------------------

  defp index_of(string, sub, from) do
    case string |> String.slice(from..-1//1) |> :binary.match(sub) do
      {pos, _len} -> from + byte_offset_to_grapheme(string, from, pos)
      :nomatch -> -1
    end
  end

  # the picture symbols are single graphemes, so byte and grapheme offsets align
  defp byte_offset_to_grapheme(string, from, byte_pos) do
    string |> String.slice(from..-1//1) |> binary_part(0, byte_pos) |> String.length()
  end

  defp last_index_of(string, sub) do
    graphemes = String.graphemes(string)
    width = String.length(sub)
    last = String.length(string) - width

    last
    |> max(-1)
    |> find_last(graphemes, sub, width)
  end

  defp find_last(pos, _graphemes, _sub, _width) when pos < 0, do: -1

  defp find_last(pos, graphemes, sub, width) do
    if graphemes |> Enum.slice(pos, width) |> Enum.join() == sub,
      do: pos,
      else: find_last(pos - 1, graphemes, sub, width)
  end

  defp all_indexes(string, sub), do: all_indexes(string, sub, 0, [])

  defp all_indexes(string, sub, from, acc) do
    case index_of(string, sub, from) do
      -1 -> Enum.reverse(acc)
      pos -> all_indexes(string, sub, pos + 1, [pos | acc])
    end
  end

  defp char_at(_string, pos) when pos < 0, do: ""
  defp char_at(string, pos), do: String.at(string, pos) || ""

  defp contains?(string, sub), do: String.contains?(string, sub)

  defp insert_at(string, pos, insertion) do
    String.slice(string, 0, pos) <> insertion <> String.slice(string, pos..-1//1)
  end
end
