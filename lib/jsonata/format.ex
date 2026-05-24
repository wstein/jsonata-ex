defmodule Jsonata.Format do
  @moduledoc """
  Integer formatting and parsing for `$formatInteger`/`$parseInteger`
  (ported from `datetime.js`).

  Supports the XPath F&O integer picture forms: decimal-digit patterns
  (`0`/`#`/grouping, with the `;o` ordinal modifier), Roman numerals (`i`/`I`),
  letter sequences (`a`/`A`), and spelled-out words (`w`/`W`/`Ww`). ASCII digit
  groups only; the numbering-sequence form is unsupported (`D3130`).
  """

  alias Jsonata.Error

  @few ~w(Zero One Two Three Four Five Six Seven Eight Nine Ten Eleven Twelve Thirteen Fourteen Fifteen Sixteen Seventeen Eighteen Nineteen)
  @ordinals ~w(Zeroth First Second Third Fourth Fifth Sixth Seventh Eighth Ninth Tenth Eleventh Twelfth Thirteenth Fourteenth Fifteenth Sixteenth Seventeenth Eighteenth Nineteenth)
  @decades ~w(Twenty Thirty Forty Fifty Sixty Seventy Eighty Ninety Hundred)
  @magnitudes ~w(Thousand Million Billion Trillion)
  @roman [
    {1000, "m"},
    {900, "cm"},
    {500, "d"},
    {400, "cd"},
    {100, "c"},
    {90, "xc"},
    {50, "l"},
    {40, "xl"},
    {10, "x"},
    {9, "ix"},
    {5, "v"},
    {4, "iv"},
    {1, "i"}
  ]

  @roman_values %{?M => 1000, ?D => 500, ?C => 100, ?L => 50, ?X => 10, ?V => 5, ?I => 1}

  # spelled-out word -> numeric value (lower-case keys), for $parseInteger
  @word_values (
                 cardinals =
                   (@few ++ @ordinals)
                   |> Enum.with_index()
                   |> Map.new(fn {w, i} -> {String.downcase(w), rem(i, 20)} end)

                 decades =
                   @decades
                   |> Enum.with_index()
                   |> Enum.flat_map(fn {w, i} ->
                     lw = String.downcase(w)
                     value = (i + 2) * 10
                     ieth = String.slice(lw, 0, String.length(lw) - 1) <> "ieth"
                     [{lw, value}, {ieth, value}]
                   end)
                   |> Map.new()

                 magnitudes =
                   @magnitudes
                   |> Enum.with_index()
                   |> Enum.flat_map(fn {w, i} ->
                     lw = String.downcase(w)
                     value = trunc(:math.pow(10, (i + 1) * 3))
                     [{lw, value}, {lw <> "th", value}]
                   end)
                   |> Map.new()

                 cardinals
                 |> Map.merge(decades)
                 |> Map.put("hundredth", 100)
                 |> Map.merge(magnitudes)
               )

  @doc "Formats an integer `value` according to an XPath integer `picture`."
  @spec format_integer(term(), String.t()) :: term()
  def format_integer(:undefined, _picture), do: :undefined

  def format_integer(value, picture) do
    format = analyse(picture)
    integer = if is_integer(value), do: value, else: value |> Float.floor() |> trunc()
    sign = if integer < 0, do: "-", else: ""
    sign <> format_value(abs(integer), format)
  end

  @doc "Parses a `value` string formatted per an XPath integer `picture` back to an integer."
  @spec parse_integer(term(), String.t()) :: term()
  def parse_integer(:undefined, _picture), do: :undefined

  def parse_integer(value, picture), do: parse_value(value, analyse(picture))

  @doc "Analyses an integer picture into a reusable spec (for `$formatInteger` and date/time)."
  @spec analyse_integer(String.t()) :: map()
  def analyse_integer(picture), do: analyse(picture)

  @doc "Formats an integer `value` using a spec from `analyse_integer/1` (sign-aware)."
  @spec format_spec(integer(), map()) :: String.t()
  def format_spec(value, spec) do
    sign = if value < 0, do: "-", else: ""
    sign <> format_value(abs(value), spec)
  end

  @doc "Whether a spec's grouping separators are regularly spaced (vs. irregular/none)."
  @spec regular?(map()) :: boolean()
  def regular?(%{grouping: {:regular, _interval, _char}}), do: true
  def regular?(_spec), do: false

  defp parse_value(value, %{primary: :letters, case: :upper}), do: letters_to_decimal(value, ?A)
  defp parse_value(value, %{primary: :letters, case: :lower}), do: letters_to_decimal(value, ?a)
  defp parse_value(value, %{primary: :roman}), do: roman_to_decimal(String.upcase(value))
  defp parse_value(value, %{primary: :words}), do: words_to_number(String.downcase(value))

  defp parse_value(value, %{primary: :decimal} = format) do
    digits = if format.ordinal, do: String.slice(value, 0..-3//1), else: value
    digits |> strip_separators(format.grouping) |> String.to_integer()
  end

  # --- picture analysis -----------------------------------------------------

  # non-decimal primary token -> {kind, case}
  @primaries %{
    "A" => {:letters, :upper},
    "a" => {:letters, :lower},
    "I" => {:roman, :upper},
    "i" => {:roman, :lower},
    "W" => {:words, :upper},
    "Ww" => {:words, :title},
    "w" => {:words, :lower}
  }

  defp analyse(picture) do
    {primary, ordinal} =
      case String.split(picture, ";", parts: 2) do
        [primary, modifier] -> {primary, String.starts_with?(modifier, "o")}
        [primary] -> {primary, false}
      end

    case @primaries do
      %{^primary => {kind, kase}} -> %{primary: kind, case: kase, ordinal: ordinal}
      _ -> analyse_decimal(primary, ordinal)
    end
  end

  defp analyse_decimal(picture, ordinal) do
    {mandatory, optional, separators} =
      picture
      |> String.to_charlist()
      |> Enum.reverse()
      |> Enum.reduce({0, 0, []}, fn code, {mandatory, optional, separators} ->
        # a separator sits after this many digit slots (counted from the right)
        position = mandatory + optional

        cond do
          code in ?0..?9 -> {mandatory + 1, optional, separators}
          code == ?# -> {mandatory, optional + 1, separators}
          true -> {mandatory, optional, [{position, <<code::utf8>>} | separators]}
        end
      end)

    if mandatory == 0 do
      raise Error.new("D3130", value: picture)
    end

    %{
      primary: :decimal,
      mandatory_digits: mandatory,
      optional_digits: optional,
      grouping: grouping(Enum.reverse(separators)),
      ordinal: ordinal
    }
  end

  # Grouping separators are "regular" when they are evenly spaced and identical.
  defp grouping([]), do: :none
  defp grouping([{pos, char}]), do: {:regular, pos, char}

  defp grouping(separators) do
    chars = separators |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    positions = Enum.map(separators, &elem(&1, 0))
    factor = Enum.reduce(positions, &Integer.gcd/2)

    regular? =
      chars == [hd(chars)] and Enum.all?(1..length(positions), &((&1 * factor) in positions))

    if regular?, do: {:regular, factor, hd(chars)}, else: {:irregular, separators}
  end

  # --- value formatting -----------------------------------------------------

  defp format_value(value, %{primary: :letters} = format),
    do: apply_case(to_letters(value, ?a), format.case)

  defp format_value(value, %{primary: :roman} = format),
    do: apply_case(to_roman(value), format.case)

  defp format_value(value, %{primary: :words} = format),
    do: apply_case(to_words(value, format.ordinal), format.case)

  defp format_value(value, %{primary: :decimal} = format) do
    digits = value |> Integer.to_string() |> String.pad_leading(format.mandatory_digits, "0")
    digits = insert_grouping(digits, format.grouping)
    if format.ordinal, do: digits <> ordinal_suffix(digits), else: digits
  end

  defp apply_case(string, :upper), do: String.upcase(string)
  defp apply_case(string, :lower), do: String.downcase(string)
  defp apply_case(string, _title), do: string

  defp to_letters(0, _a), do: ""

  defp to_letters(value, a) do
    to_letters(div(value - 1, 26), a) <> <<rem(value - 1, 26) + a>>
  end

  defp to_roman(0), do: ""

  defp to_roman(value) do
    {n, numeral} = Enum.find(@roman, fn {n, _} -> value >= n end)
    numeral <> to_roman(value - n)
  end

  # --- spelled-out words ----------------------------------------------------

  defp to_words(value, ordinal), do: words(value, false, ordinal)

  defp words(num, prev, ordinal) when num <= 19 do
    prefix(prev, " and ") <> Enum.at(if(ordinal, do: @ordinals, else: @few), num)
  end

  defp words(num, prev, ordinal) when num < 100 do
    tens = div(num, 10)
    base = prefix(prev, " and ") <> Enum.at(@decades, tens - 2)

    cond do
      rem(num, 10) > 0 -> base <> "-" <> words(rem(num, 10), false, ordinal)
      ordinal -> String.trim_trailing(base, "y") <> "ieth"
      true -> base
    end
  end

  defp words(num, prev, ordinal) when num < 1000 do
    base = prefix(prev, ", ") <> Enum.at(@few, div(num, 100)) <> " Hundred"
    append_remainder(base, rem(num, 100), ordinal)
  end

  defp words(num, prev, ordinal) do
    mag = min(div(String.length(Integer.to_string(num)) - 1, 3), length(@magnitudes))
    factor = trunc(:math.pow(10, mag * 3))

    base =
      prefix(prev, ", ") <>
        words(div(num, factor), false, false) <> " " <> Enum.at(@magnitudes, mag - 1)

    append_remainder(base, rem(num, factor), ordinal)
  end

  defp append_remainder(base, 0, true), do: base <> "th"
  defp append_remainder(base, 0, false), do: base
  defp append_remainder(base, remainder, ordinal), do: base <> words(remainder, true, ordinal)

  defp prefix(true, sep), do: sep
  defp prefix(false, _sep), do: ""

  # --- decimal grouping & ordinal suffix ------------------------------------

  defp insert_grouping(digits, :none), do: digits

  defp insert_grouping(digits, {:regular, interval, char}) do
    count = div(String.length(digits) - 1, interval)

    Enum.reduce(count..1//-1, digits, fn ii, acc ->
      pos = String.length(acc) - ii * interval
      String.slice(acc, 0, pos) <> char <> String.slice(acc, pos..-1//1)
    end)
  end

  defp insert_grouping(digits, {:irregular, separators}) do
    separators
    |> Enum.reverse()
    |> Enum.reduce(digits, fn {position, char}, acc ->
      pos = String.length(acc) - position

      if pos > 0,
        do: String.slice(acc, 0, pos) <> char <> String.slice(acc, pos..-1//1),
        else: acc
    end)
  end

  defp ordinal_suffix(digits) do
    last_two = String.slice(digits, -2..-1//1)
    last = String.last(digits)

    cond do
      String.length(last_two) == 2 and String.at(last_two, 0) == "1" -> "th"
      last == "1" -> "st"
      last == "2" -> "nd"
      last == "3" -> "rd"
      true -> "th"
    end
  end

  # --- parsing helpers ($parseInteger) --------------------------------------

  defp strip_separators(digits, :none), do: digits

  defp strip_separators(digits, {:regular, _interval, char}),
    do: String.replace(digits, char, "")

  defp strip_separators(digits, {:irregular, separators}) do
    Enum.reduce(separators, digits, fn {_position, char}, acc ->
      String.replace(acc, char, "")
    end)
  end

  defp letters_to_decimal(letters, a_code) do
    letters
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce(0, fn {code, i}, acc ->
      acc + (code - a_code + 1) * trunc(:math.pow(26, i))
    end)
  end

  # Walk right-to-left, subtracting any numeral smaller than the running maximum.
  defp roman_to_decimal(roman) do
    roman
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.reduce({0, 0}, fn code, {decimal, max} ->
      value = Map.fetch!(@roman_values, code)
      if value < max, do: {decimal - value, max}, else: {decimal + value, value}
    end)
    |> elem(0)
  end

  # Sum the word values into segments, multiplying a segment by a magnitude word.
  defp words_to_number(text) do
    text
    |> String.split(~r/,\s|\sand\s|[\s\-]/)
    |> Enum.map(&Map.fetch!(@word_values, &1))
    |> Enum.reduce([0], &combine_word_value/2)
    |> Enum.sum()
  end

  defp combine_word_value(value, [top | rest]) when value < 100 and top >= 1000,
    do: [value, top | rest]

  defp combine_word_value(value, [top | rest]) when value < 100, do: [top + value | rest]
  defp combine_word_value(value, [top | rest]), do: [top * value | rest]
end
