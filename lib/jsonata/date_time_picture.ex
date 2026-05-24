defmodule Jsonata.DateTimePicture do
  @moduledoc """
  XPath F&O date/time **picture strings** (`fn:format-dateTime` and
  `fn:parse-dateTime`), ported from `datetime.js`. Drives the picture-string
  forms of `$fromMillis`/`$now` (`format/3`) and `$toMillis` (`parse/3`).

  A picture is a sequence of literal text and `[component]` markers (e.g.
  `[Y0001]-[M01]-[D01]`). Each marker names a component (`Y` year, `M` month,
  `D` day, `d` day-of-year, `F` day-of-week, `W`/`w` week-of-year/month, `X`/`x`
  ISO week-numbering year/month, `H`/`h` hour, `P` am/pm, `m` minute, `s` second,
  `f` fractional second, `Z`/`z` timezone) with optional presentation and width
  modifiers. Integer components reuse `Jsonata.Format`'s picture machinery.
  """

  import Bitwise

  alias Jsonata.{Error, Format}

  @day_millis 86_400_000

  @days ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  @months ~w(January February March April May June July August September October November December)

  @default_presentation %{
    "Y" => "1",
    "M" => "1",
    "D" => "1",
    "d" => "1",
    "F" => "n",
    "W" => "1",
    "w" => "1",
    "X" => "1",
    "x" => "1",
    "H" => "1",
    "h" => "1",
    "P" => "n",
    "m" => "01",
    "s" => "01",
    "f" => "1",
    "Z" => "01:01",
    "z" => "01:01",
    "C" => "n",
    "E" => "n"
  }

  @integer_components ~c"YMDdFWwXxHhmsf"

  @iso8601_picture "[Y0001]-[M01]-[D01]T[H01]:[m01]:[s01].[f001][Z01:01t]"

  @doc """
  Formats `millis` (epoch milliseconds) per `picture`, applying `timezone`
  (a `±hhmm` string, or `:undefined` for UTC). A `:undefined` picture uses ISO 8601.
  """
  @spec format(integer(), String.t() | :undefined, String.t() | :undefined) :: String.t()
  def format(millis, picture, timezone) do
    {offset_hours, offset_minutes} = parse_timezone(timezone)
    spec = analyse_picture(if picture == :undefined, do: @iso8601_picture, else: picture)

    offset_millis = (60 * offset_hours + offset_minutes) * 60 * 1000
    fields = fields(millis + offset_millis)

    Enum.map_join(spec, fn
      {:literal, value} -> value
      marker -> format_component(fields, marker, offset_hours, offset_minutes)
    end)
  end

  defp parse_timezone(:undefined), do: {0, 0}

  defp parse_timezone(timezone) do
    offset = String.to_integer(String.trim_leading(timezone, "+"))
    {div(offset, 100), rem(offset, 100)}
  end

  # --- picture analysis -----------------------------------------------------

  @doc "Parses `picture` into a list of `{:literal, text}` and marker maps."
  @spec analyse_picture(String.t()) :: [tuple() | map()]
  def analyse_picture(picture) do
    picture
    |> tokenize(0, 0, [])
    |> Enum.reduce([], &reduce_token/2)
    |> Enum.reverse()
  end

  # split the picture into raw literal/marker tokens, handling [[ ]] escapes
  defp tokenize(picture, start, pos, acc) when pos >= byte_size(picture) do
    Enum.reverse(add_literal(picture, start, pos, acc))
  end

  defp tokenize(picture, start, pos, acc) do
    case :binary.at(picture, pos) do
      ?[ ->
        if pos + 1 < byte_size(picture) and :binary.at(picture, pos + 1) == ?[ do
          acc = [{:literal, "["} | add_literal(picture, start, pos, acc)]
          tokenize(picture, pos + 2, pos + 2, acc)
        else
          acc = add_literal(picture, start, pos, acc)
          close = find_close(picture, pos + 1)
          marker = picture |> binary_part(pos + 1, close - pos - 1) |> strip_whitespace()
          tokenize(picture, close + 1, close + 1, [{:marker, marker} | acc])
        end

      _ ->
        tokenize(picture, start, pos + 1, acc)
    end
  end

  defp find_close(picture, pos) do
    case :binary.match(picture, "]", scope: {pos, byte_size(picture) - pos}) do
      {at, _len} -> at
      :nomatch -> raise Error.new("D3135")
    end
  end

  defp add_literal(_picture, start, pos, acc) when pos <= start, do: acc

  defp add_literal(picture, start, pos, acc) do
    literal = picture |> binary_part(start, pos - start) |> String.replace("]]", "]")
    [{:literal, literal} | acc]
  end

  defp strip_whitespace(string), do: String.replace(string, ~r/\s+/, "")

  # 0-based index of the last occurrence of `sub` in `string`, or -1
  defp last_index(string, sub) do
    case :binary.matches(string, sub) do
      [] -> -1
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp reduce_token({:literal, value}, acc), do: [{:literal, value} | acc]

  defp reduce_token({:marker, marker}, acc) do
    part = analyse_marker(marker, acc)
    [part | fix_previous_parse_width(part, acc)]
  end

  # An integer component adjacent to a preceding integer part (no literal between)
  # forces that part to a fixed parse width, so the digit runs don't merge.
  defp fix_previous_parse_width(part, [%{integer_format: prev} = previous | rest]) do
    if integer_component?(part) do
      [%{previous | integer_format: Map.put(prev, :parse_width, prev[:mandatory_digits])} | rest]
    else
      [previous | rest]
    end
  end

  defp fix_previous_parse_width(_part, acc), do: acc

  defp integer_component?(%{integer_format: _, component: component}),
    do: :binary.first(component) in @integer_components

  defp integer_component?(_part), do: false

  defp analyse_marker(marker, previous_parts) do
    component = String.first(marker)
    {width, pres_mod} = split_width(marker)

    %{component: component, width: width}
    |> add_presentation(pres_mod, component)
    |> add_format(component, previous_parts)
  end

  defp split_width(marker) do
    case last_index(marker, ",") do
      -1 ->
        {nil, String.slice(marker, 1..-1//1)}

      comma ->
        width_mod = String.slice(marker, (comma + 1)..-1//1)
        {parse_width_mod(width_mod), String.slice(marker, 1, comma - 1)}
    end
  end

  defp parse_width_mod(width_mod) do
    case String.split(width_mod, "-", parts: 2) do
      [min] -> %{min: parse_width(min), max: nil}
      [min, max] -> %{min: parse_width(min), max: parse_width(max)}
    end
  end

  defp parse_width(""), do: nil
  defp parse_width("*"), do: nil
  defp parse_width(value), do: String.to_integer(value)

  defp add_presentation(def, pres_mod, component) do
    case String.length(pres_mod) do
      1 -> Map.put(def, :presentation1, pres_mod)
      0 -> default_presentation(def, component)
      _ -> split_presentation(def, pres_mod)
    end
  end

  defp default_presentation(def, component) do
    case Map.get(@default_presentation, component) do
      nil -> raise Error.new("D3132", value: component)
      pres -> Map.put(def, :presentation1, pres)
    end
  end

  defp split_presentation(def, pres_mod) do
    last_char = String.last(pres_mod)

    if last_char in ["a", "t", "c", "o"] do
      def
      |> Map.put(:presentation2, last_char)
      |> Map.put(:ordinal, last_char == "o")
      |> Map.put(:presentation1, String.slice(pres_mod, 0..-2//1))
    else
      Map.put(def, :presentation1, pres_mod)
    end
  end

  defp add_format(def, component, previous_parts) do
    pres1 = def.presentation1

    cond do
      String.first(pres1) == "n" ->
        Map.put(def, :names, :lower)

      String.first(pres1) == "N" ->
        Map.put(def, :names, if(String.at(pres1, 1) == "n", do: :title, else: :upper))

      component in ["Z", "z"] ->
        Map.put(def, :integer_format, Format.analyse_integer(pres1))

      :binary.first(component) in @integer_components ->
        add_integer_format(def, component, previous_parts)

      true ->
        def
    end
  end

  defp add_integer_format(def, component, _previous_parts) do
    pattern =
      if def[:presentation2],
        do: def.presentation1 <> ";" <> def.presentation2,
        else: def.presentation1

    format = pattern |> Format.analyse_integer() |> apply_min_width(def[:width])

    def
    |> Map.put(:integer_format, format)
    |> apply_year_width(component)
  end

  defp apply_min_width(format, %{min: min})
       when is_integer(min) and is_map_key(format, :mandatory_digits),
       do: Map.update!(format, :mandatory_digits, &max(&1, min))

  defp apply_min_width(format, _width), do: format

  defp apply_year_width(%{component: "Y", width: %{max: max}} = def, "Y") when is_integer(max) do
    %{def | integer_format: Map.put(def.integer_format, :mandatory_digits, max)}
    |> Map.put(:n, max)
  end

  defp apply_year_width(%{component: "Y"} = def, "Y") do
    format = def.integer_format
    width = Map.get(format, :mandatory_digits, 0) + Map.get(format, :optional_digits, 0)
    Map.put(def, :n, if(width >= 2, do: width, else: -1))
  end

  defp apply_year_width(def, _component), do: def

  # --- component value extraction -------------------------------------------

  defp fields(millis) do
    datetime = DateTime.from_unix!(millis, :millisecond)
    %{datetime: datetime, date: DateTime.to_date(datetime), millis: millis}
  end

  defp fragment(f, "Y"), do: f.datetime.year
  defp fragment(f, "M"), do: f.datetime.month
  defp fragment(f, "D"), do: f.datetime.day
  defp fragment(f, "d"), do: Date.day_of_year(f.date)
  defp fragment(f, "F"), do: Date.day_of_week(f.date, :monday)
  defp fragment(f, "H"), do: f.datetime.hour
  defp fragment(f, "m"), do: f.datetime.minute
  defp fragment(f, "s"), do: f.datetime.second
  defp fragment(f, "f"), do: elem(f.datetime.microsecond, 0) |> div(1000)
  defp fragment(f, "P"), do: if(f.datetime.hour >= 12, do: "pm", else: "am")
  defp fragment(_f, "C"), do: "ISO"
  defp fragment(_f, "E"), do: "ISO"

  defp fragment(f, "h") do
    case rem(f.datetime.hour, 12) do
      0 -> 12
      h -> h
    end
  end

  defp fragment(f, "W"), do: week_of(f, f.datetime.year, 1, 52)
  defp fragment(f, "w"), do: week_of(f, f.datetime.year, f.datetime.month, 4)
  defp fragment(f, "X"), do: iso_week_year(f)
  defp fragment(f, "x"), do: iso_week_month(f)
  defp fragment(_f, _component), do: nil

  defp midnight_millis(f) do
    first_of_month_millis(f.datetime.year, f.datetime.month) + (f.datetime.day - 1) * @day_millis
  end

  defp week_of(f, year, month, max_weeks) do
    today = midnight_millis(f)
    week = delta_weeks(start_of_first_week(year, month), today)

    week =
      cond do
        week > max_weeks ->
          wrap_forward(today, year, month, week)

        week < 1 ->
          delta_weeks(start_of_first_week_of(prev_period(year, month, max_weeks)), today)

        true ->
          week
      end

    floor(week)
  end

  defp wrap_forward(today, year, month, week) do
    {next_year, next_month} = next_period(year, month)

    if today >= start_of_first_week(next_year, next_month), do: 1, else: week
  end

  # 'W' works on whole years (month stays 1); 'w' steps months
  defp next_period(year, 1), do: {year + 1, 1}
  defp next_period(year, month), do: next_month(year, month)

  defp prev_period(year, 1, 52), do: {year - 1, 1}
  defp prev_period(year, month, _max), do: prev_month(year, month)

  defp start_of_first_week_of({year, month}), do: start_of_first_week(year, month)

  defp iso_week_year(f) do
    year = f.datetime.year
    start_iso = start_of_first_week(year, 1)
    end_iso = start_of_first_week(year + 1, 1)

    cond do
      f.millis < start_iso -> year - 1
      f.millis >= end_iso -> year + 1
      true -> year
    end
  end

  defp iso_week_month(f) do
    year = f.datetime.year
    month = f.datetime.month
    start_iso = start_of_first_week(year, month)
    {next_year, next_month} = next_month(year, month)
    end_iso = start_of_first_week(next_year, next_month)

    cond do
      f.millis < start_iso -> prev_month(year, month) |> elem(1)
      f.millis >= end_iso -> next_month
      true -> month
    end
  end

  defp next_month(year, 12), do: {year + 1, 1}
  defp next_month(year, month), do: {year, month + 1}
  defp prev_month(year, 1), do: {year - 1, 12}
  defp prev_month(year, month), do: {year, month - 1}

  defp first_of_month_millis(year, month) do
    year
    |> Date.new!(month, 1)
    |> DateTime.new!(~T[00:00:00.000], "Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  # ISO 8601: week 1 contains the first Thursday; the week starts on Monday
  defp start_of_first_week(year, month) do
    first = first_of_month_millis(year, month)
    day_of = year |> Date.new!(month, 1) |> Date.day_of_week(:monday)

    if day_of > 4,
      do: first + (8 - day_of) * @day_millis,
      else: first - (day_of - 1) * @day_millis
  end

  defp delta_weeks(start, finish), do: (finish - start) / (@day_millis * 7) + 1

  # --- component formatting -------------------------------------------------

  defp format_component(fields, %{component: component} = marker, offset_hours, offset_minutes) do
    value = fragment(fields, component)

    cond do
      :binary.first(component) in ~c"YMDdFWwXxHhms" -> format_integer_component(value, marker)
      component == "f" -> Format.format_spec(value, marker.integer_format)
      component in ["Z", "z"] -> format_timezone(marker, offset_hours, offset_minutes)
      component == "P" -> format_period(value, marker)
      true -> to_string(value)
    end
  end

  defp format_integer_component(value, %{names: names} = marker) when not is_nil(names) do
    marker.component
    |> component_name(value)
    |> apply_names_case(names)
    |> truncate(marker[:width])
  end

  defp format_integer_component(value, %{component: "Y"} = marker) do
    value = if marker.n != -1, do: Integer.mod(value, trunc(:math.pow(10, marker.n))), else: value
    Format.format_spec(value, marker.integer_format)
  end

  defp format_integer_component(value, marker),
    do: Format.format_spec(value, marker.integer_format)

  defp component_name(component, value) when component in ["M", "x"],
    do: Enum.at(@months, value - 1)

  defp component_name("F", value), do: Enum.at(@days, value - 1)
  defp component_name(component, _value), do: raise(Error.new("D3133", value: component))

  defp apply_names_case(name, :upper), do: String.upcase(name)
  defp apply_names_case(name, :lower), do: String.downcase(name)
  defp apply_names_case(name, _title), do: name

  defp truncate(name, %{max: max}) when is_integer(max), do: String.slice(name, 0, max)
  defp truncate(name, _width), do: name

  defp format_period(value, %{names: :upper}), do: String.upcase(value)
  defp format_period(value, _marker), do: value

  defp format_timezone(marker, offset_hours, offset_minutes) do
    offset = offset_hours * 100 + offset_minutes
    body = timezone_body(marker.integer_format, offset, offset_hours, offset_minutes)
    body = if offset >= 0, do: "+" <> body, else: body
    body = if marker.component == "z", do: "GMT" <> body, else: body
    if offset == 0 and marker[:presentation2] == "t", do: "Z", else: body
  end

  defp timezone_body(format, offset, offset_hours, offset_minutes) do
    if Format.regular?(format) do
      Format.format_spec(offset, format)
    else
      irregular_timezone(format, offset, offset_hours, offset_minutes)
    end
  end

  defp irregular_timezone(format, offset, offset_hours, offset_minutes) do
    case format.mandatory_digits do
      digits when digits in [1, 2] ->
        hours = Format.format_spec(offset_hours, format)

        if offset_minutes != 0,
          do: hours <> ":" <> Format.format_integer(offset_minutes, "00"),
          else: hours

      digits when digits in [3, 4] ->
        Format.format_spec(offset, format)

      digits ->
        raise Error.new("D3134", value: digits)
    end
  end

  # --- parsing ($toMillis with a picture) -----------------------------------

  # date/time component combinations, as bit masks over Y X M x W w d D / P H h m s f
  @date_a 161
  @date_b 130
  @date_c 84
  @date_d 72
  @time_a 23
  @time_b 47

  @doc """
  Parses `timestamp` per `picture` into epoch milliseconds, defaulting the most
  significant unspecified components from `now_millis`. Returns `:undefined` if
  the string does not match the picture.
  """
  @spec parse(String.t(), String.t(), integer()) :: integer() | :undefined
  def parse(timestamp, picture, now_millis) do
    matchers = picture |> analyse_picture() |> Enum.map(&matcher_for/1)

    regex =
      Regex.compile!("^" <> Enum.map_join(matchers, &"(#{elem(&1, 0)})") <> "$", [:caseless])

    case Regex.run(regex, timestamp) do
      nil -> :undefined
      [_whole | captures] -> resolve(extract(captures, matchers), now_millis)
    end
  end

  defp extract(captures, matchers) do
    captures
    |> Enum.zip(matchers)
    |> Enum.reduce(%{}, fn
      {capture, {_regex, parse_fn, component}}, acc when is_function(parse_fn) ->
        Map.put(acc, component, parse_fn.(capture))

      _literal, acc ->
        acc
    end)
  end

  # --- per-part regex + capture parser --------------------------------------

  defp matcher_for({:literal, value}), do: {Regex.escape(value), nil, nil}

  defp matcher_for(%{component: "f"} = marker),
    do: {"[0-9]+", &parse_fractional/1, marker.component}

  defp matcher_for(%{component: component} = marker) when component in ["Z", "z"],
    do: timezone_matcher(marker)

  defp matcher_for(%{names: names} = marker) when not is_nil(names),
    do: {"[a-zA-Z]+", name_parser(marker), marker.component}

  defp matcher_for(%{integer_format: format} = marker),
    do: {integer_regex(format), &Format.parse_spec(&1, format), marker.component}

  defp parse_fractional(value) do
    {fraction, _} = Float.parse("0." <> String.slice(value, 0, 3))
    round(fraction * 1000)
  end

  defp integer_regex(%{primary: :decimal} = format) do
    width = if format[:parse_width], do: "{#{format.parse_width}}", else: "+"
    ordinal = if format.ordinal, do: "(?:th|st|nd|rd)", else: ""
    "[0-9]" <> width <> ordinal
  end

  defp integer_regex(%{primary: :letters, case: :upper}), do: "[A-Z]+"
  defp integer_regex(%{primary: :letters}), do: "[a-z]+"
  defp integer_regex(%{primary: :roman, case: :upper}), do: "[MDCLXVI]+"
  defp integer_regex(%{primary: :roman}), do: "[mdclxvi]+"

  defp integer_regex(%{primary: :words}) do
    # match only sequences of recognised number words, "and", and separators
    # (longest-first to steer the alternation, e.g. "seventeen" before "seven")
    words =
      Format.word_keys()
      |> Enum.sort_by(&(-String.length(&1)))
      |> Enum.map(&Regex.escape/1)

    "(?:" <> Enum.join(words ++ ["and", "[\\-, ]"], "|") <> ")+"
  end

  defp name_parser(%{component: component, width: width}) do
    lookup = name_lookup(component, width)
    fn value -> Map.get(lookup, value) end
  end

  defp name_lookup(component, width) when component in ["M", "x"],
    do: indexed_lookup(@months, 1, width)

  defp name_lookup("F", width), do: indexed_lookup(@days, 1, width)
  defp name_lookup("P", _width), do: %{"am" => 0, "AM" => 0, "pm" => 1, "PM" => 1}

  defp indexed_lookup(names, base, width) do
    names
    |> Enum.with_index(base)
    |> Map.new(fn {name, index} -> {truncate(name, width), index} end)
  end

  defp timezone_matcher(%{component: component, integer_format: format} = marker) do
    separator = if Format.regular?(format), do: timezone_separator(format), else: nil
    prefix = if component == "z", do: "GMT", else: ""

    regex =
      prefix <> "[-+][0-9]+" <> if(separator, do: "#{Regex.escape(separator)}[0-9]+", else: "")

    {regex, &parse_timezone_offset(&1, marker, separator), component}
  end

  defp timezone_separator(%{grouping: {:regular, _interval, char}}), do: char

  defp parse_timezone_offset(value, %{component: component}, separator) do
    value = if component == "z", do: String.replace_prefix(value, "GMT", ""), else: value

    {hours, minutes} =
      cond do
        separator ->
          split_offset(value, separator)

        String.length(value) - 1 <= 2 ->
          {String.to_integer(value), 0}

        true ->
          {value |> String.slice(0, 3) |> String.to_integer(),
           value |> String.slice(3..-1//1) |> String.to_integer()}
      end

    hours * 60 + minutes
  end

  defp split_offset(value, separator) do
    [hours, minutes] = String.split(value, separator, parts: 2)
    {String.to_integer(hours), String.to_integer(minutes)}
  end

  # --- component resolution (F&O rules) -------------------------------------

  defp resolve(components, _now_millis) when map_size(components) == 0, do: :undefined

  defp resolve(components, now_millis) do
    date_mask = mask(components, ~w(Y X M x W w d D))
    date_a = type?(date_mask, @date_a)
    date_b = not date_a and type?(date_mask, @date_b)
    date_c = type?(date_mask, @date_c)
    date_d = not date_c and type?(date_mask, @date_d)

    time_mask = mask(components, ~w(P H h m s f))
    time_b = not type?(time_mask, @time_a) and type?(time_mask, @time_b)

    date_comps =
      cond do
        date_b -> ~w(Y D)
        date_c -> ~w(X x w F)
        date_d -> ~w(X W F)
        true -> ~w(Y M D)
      end

    time_comps = if time_b, do: ~w(P h m s f), else: ~w(H m s f)

    components
    |> default_components(date_comps ++ time_comps, fields(now_millis))
    |> build_millis(date_b, date_c, date_d, time_b)
  end

  defp mask(components, keys) do
    Enum.reduce(keys, 0, fn key, mask ->
      mask * 2 + if(Map.has_key?(components, key), do: 1, else: 0)
    end)
  end

  # mask has no bits outside `type`, and at least one of `type`'s bits
  defp type?(mask, type), do: band(bnot(type), mask) == 0 and band(type, mask) != 0

  defp default_components(components, comps, now) do
    {result, _started, _ended} =
      Enum.reduce(comps, {components, false, false}, fn part, {map, started, ended} ->
        cond do
          Map.has_key?(map, part) and ended -> raise(Error.new("D3136"))
          Map.has_key?(map, part) -> {map, true, ended}
          started -> {Map.put(map, part, trailing_default(part)), started, true}
          true -> {Map.put(map, part, fragment(now, part)), started, ended}
        end
      end)

    result
  end

  defp trailing_default(part) when part in ~w(M D d), do: 1
  defp trailing_default(_part), do: 0

  defp build_millis(_components, _date_b, date_c, date_d, _time_b) when date_c or date_d,
    do: raise(Error.new("D3136"))

  defp build_millis(components, date_b, _date_c, _date_d, time_b) do
    get = fn key -> Map.get(components, key, 0) end
    date_millis = date_millis(components, date_b, get)
    hour = resolve_hour(get.("H"), get.("h"), get.("P"), time_b)
    millis = date_millis + ((hour * 60 + get.("m")) * 60 + get.("s")) * 1000 + get.("f")

    case get.("Z") + get.("z") do
      0 -> millis
      offset_minutes -> millis - offset_minutes * 60 * 1000
    end
  end

  defp date_millis(components, true = _date_b, get),
    do: first_of_month_millis(get.("Y"), 1) + (components["d"] - 1) * @day_millis

  defp date_millis(_components, _date_b, get) do
    month = if get.("M") > 0, do: get.("M"), else: 1
    first_of_month_millis(get.("Y"), month) + (get.("D") - 1) * @day_millis
  end

  defp resolve_hour(hour, h, period, time_b) do
    if time_b do
      base = if h == 12, do: 0, else: h
      if period == 1, do: base + 12, else: base
    else
      hour
    end
  end
end
