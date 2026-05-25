defmodule Jsonata.Functions do
  @moduledoc """
  The JSONata built-in function library. Each registry entry pairs a name with
  its signature and an implementation taking the validated argument list.

  Covers aggregation, numeric, string, array/object, boolean, and control
  functions; the regex matchers (`$match` and the regex forms of `$contains`/
  `$split`/`$replace`); higher-order functions (`$map`, `$filter`, `$reduce`,
  `$single`, `$sift`, `$each`, comparator `$sort`); the date/time functions
  (`$fromMillis`/`$toMillis`/`$now`/`$millis`, `$formatBase`, including date/time
  picture-string formatting and parsing via `Jsonata.DateTimePicture`); the
  integer picture strings `$formatInteger`/`$parseInteger` (`Jsonata.Format`); and
  `$formatNumber` (DecimalFormat — `Jsonata.FormatNumber`).

  The `$match` custom-matcher protocol is not yet implemented.
  """

  alias Jsonata.{Environment, Error, Function, Sequence, Signature, Value}

  @undefined :undefined

  # $error always raises (it has no normal return path) — this is intentional.
  @dialyzer {:nowarn_function, error: 1}

  @doc """
  Merges the built-in functions into `env` (existing bindings win).

  The built-in map — which requires parsing/compiling every signature — is built
  once and cached in `:persistent_term`, so repeated `Jsonata.evaluate/3` calls
  do not re-parse signatures.
  """
  @spec bind_all(Environment.t()) :: Environment.t()
  def bind_all(%Environment{} = env) do
    %{env | bindings: Map.merge(builtins(), env.bindings)}
  end

  @doc "The cached map of built-in name → `Jsonata.Function`."
  @spec builtins() :: %{optional(String.t()) => Function.t()}
  def builtins do
    case :persistent_term.get({__MODULE__, :builtins}, nil) do
      nil ->
        map = build_builtins()
        :persistent_term.put({__MODULE__, :builtins}, map)
        map

      map ->
        map
    end
  end

  defp build_builtins do
    Map.new(registry(), fn {name, signature, impl} ->
      parsed = Signature.parse(signature)

      {name,
       %Function{name: name, impl: impl, signature: parsed, arity: builtin_arity(parsed.params)}}
    end)
  end

  # The number of leading required parameters — used by higher-order functions to
  # decide how many of (value, index, array) to pass (mirrors JS `function.length`).
  defp builtin_arity(params) do
    params |> Enum.take_while(&(not String.ends_with?(&1.regex, "?"))) |> length()
  end

  defp registry do
    [
      # --- aggregation ---
      {"sum", "<a<n>:n>", &sum/1},
      {"count", "<a:n>", &count/1},
      {"max", "<a<n>:n>", fn args -> agg(args, &Enum.max/1) end},
      {"min", "<a<n>:n>", fn args -> agg(args, &Enum.min/1) end},
      {"average", "<a<n>:n>", &average/1},
      # --- numeric ---
      {"number", "<(nsb)-:n>", &number/1},
      {"abs", "<n-:n>", fn args -> num1(args, &abs/1) end},
      {"floor", "<n-:n>", fn args -> num1(args, &floor_num/1) end},
      {"ceil", "<n-:n>", fn args -> num1(args, &ceil_num/1) end},
      {"round", "<n-n?:n>", &round_fn/1},
      {"power", "<n-n:n>", &power/1},
      {"sqrt", "<n-:n>", &sqrt/1},
      {"formatBase", "<n-n?:s>", &format_base/1},
      {"formatInteger", "<n-s:s>",
       fn [value, picture] -> Jsonata.Format.format_integer(value, picture) end},
      {"parseInteger", "<s-s:n>",
       fn [value, picture] -> Jsonata.Format.parse_integer(value, picture) end},
      {"formatNumber", "<n-so?:s>", &format_number/1},
      # --- date/time (Phase 5; date/time picture strings deferred) ---
      {"fromMillis", "<n-s?s?:s>", &Jsonata.DateTime.from_millis/1},
      {"toMillis", "<s-s?:n>", &Jsonata.DateTime.to_millis/1},
      {"now", "<s?s?:s>", &Jsonata.DateTime.now/1},
      {"millis", "<:n>", &Jsonata.DateTime.millis/1},
      # --- string ---
      {"string", "<x-b?:s>", &string/1},
      {"length", "<s-:n>", fn args -> str1(args, &String.length/1) end},
      {"uppercase", "<s-:s>", fn args -> str1(args, &String.upcase/1) end},
      {"lowercase", "<s-:s>", fn args -> str1(args, &String.downcase/1) end},
      {"trim", "<s-:s>", fn args -> str1(args, &trim/1) end},
      {"substring", "<s-nn?:s>", &substring/1},
      {"substringBefore", "<s-s:s>", &substring_before/1},
      {"substringAfter", "<s-s:s>", &substring_after/1},
      {"pad", "<s-ns?:s>", &pad/1},
      {"contains", "<s-(sf):b>", &contains/1},
      {"split", "<s-(sf)n?:a<s>>", &split/1},
      {"join", "<a<s>s?:s>", &join/1},
      {"replace", "<s-(sf)(sf)n?:s>", &replace/1},
      {"match", "<s-f<s:o>n?:a<o>>", &match/1},
      {"base64encode", "<s-:s>", fn args -> str1(args, &Base.encode64/1) end},
      {"base64decode", "<s-:s>", fn args -> str1(args, &Base.decode64!/1) end},
      {"encodeUrlComponent", "<s-:s>", fn args -> str1(args, &encode_component/1) end},
      {"encodeUrl", "<s-:s>", fn args -> str1(args, &encode_url/1) end},
      {"decodeUrlComponent", "<s-:s>", fn args -> str1(args, &URI.decode/1) end},
      {"decodeUrl", "<s-:s>", fn args -> str1(args, &URI.decode/1) end},
      # --- array / object ---
      {"append", "<xx:a>", &append/1},
      {"reverse", "<a:a>", &reverse/1},
      {"shuffle", "<a:a>", &shuffle/1},
      {"distinct", "<x:x>", &distinct/1},
      {"sort", "<af?:a>", &sort/1},
      {"zip", "<a+>", &zip/1},
      {"keys", "<x-:a<s>>", &keys/1},
      {"lookup", "<x-s:x>", &lookup/1},
      {"spread", "<x-:a<o>>", &spread/1},
      {"merge", "<a<o>:o>", &merge/1},
      {"exists", "<x:b>", &exists/1},
      {"type", "<x:s>", &type/1},
      # --- boolean ---
      {"boolean", "<x-:b>", fn args -> bool1(args, fn b -> b end) end},
      {"not", "<x-:b>", &not_fn/1},
      # --- higher-order (function arguments arrive as Jsonata.Function closures) ---
      {"map", "<af>", &map/1},
      {"filter", "<af>", &filter/1},
      {"single", "<af?>", &single/1},
      {"reduce", "<afj?:j>", &reduce/1},
      {"sift", "<o-f?:o>", &sift/1},
      {"each", "<o-f:a>", &each/1},
      # --- control ---
      {"error", "<s?:x>", &error/1},
      {"assert", "<bs?:x>", &assert/1}
    ]
  end

  # --- higher-order functions -----------------------------------------------

  defp map([@undefined, _func]), do: @undefined

  defp map([arr, func]) do
    arr
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      case call_hof(func, item, index, arr) do
        @undefined -> []
        result -> [result]
      end
    end)
    |> Sequence.from_value()
  end

  defp filter([@undefined, _func]), do: @undefined

  defp filter([arr, func]) do
    arr
    |> Enum.with_index()
    |> Enum.filter(fn {item, index} -> jboolean(call_hof(func, item, index, arr)) end)
    |> Enum.map(&elem(&1, 0))
    |> Sequence.from_value()
  end

  defp single([@undefined | _]), do: @undefined
  defp single([arr]), do: single([arr, nil])

  defp single([arr, func]) do
    matches =
      arr
      |> Enum.with_index()
      |> Enum.filter(fn {item, index} -> single_match?(func, item, index, arr) end)

    case matches do
      [{item, _index}] -> item
      [] -> raise Error.new("D3139")
      _many -> raise Error.new("D3138")
    end
  end

  defp single_match?(func, _item, _index, _arr) when func in [nil, @undefined], do: true
  defp single_match?(func, item, index, arr), do: jboolean(call_hof(func, item, index, arr))

  defp reduce([@undefined | _]), do: @undefined
  defp reduce([seq, func]), do: reduce([seq, func, :undefined])

  defp reduce([_seq, %Function{arity: arity}, _init]) when arity < 2,
    do: raise(Error.new("D3050"))

  defp reduce([[first | rest], func, :undefined]),
    do: do_reduce(rest, func, first, 1, [first | rest])

  defp reduce([seq, func, init]), do: do_reduce(seq, func, init, 0, seq)

  defp do_reduce([], _func, acc, _index, _seq), do: acc

  defp do_reduce([item | rest], func, acc, index, seq) do
    do_reduce(
      rest,
      func,
      func.impl.(reduce_args(func.arity, acc, item, index, seq)),
      index + 1,
      seq
    )
  end

  defp reduce_args(arity, acc, item, index, seq) do
    cond do
      arity >= 4 -> [acc, item, index, seq]
      arity >= 3 -> [acc, item, index]
      true -> [acc, item]
    end
  end

  defp sift([@undefined | _]), do: @undefined

  defp sift([map, func]) when is_map(map) do
    result =
      map
      |> Enum.filter(fn {key, value} -> jboolean(call_hof(func, value, key, map)) end)
      |> Map.new()

    if map_size(result) == 0, do: @undefined, else: result
  end

  defp each([@undefined | _]), do: @undefined

  defp each([map, func]) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> call_hof(func, value, key, map) end)
    |> Sequence.from_value()
  end

  # Applies a function closure with the right number of higher-order arguments.
  defp call_hof(%Function{arity: arity, impl: impl}, item, index, collection),
    do: impl.(hof_args(arity, item, index, collection))

  defp hof_args(arity, item, index, collection) do
    cond do
      arity >= 3 -> [item, index, collection]
      arity >= 2 -> [item, index]
      true -> [item]
    end
  end

  # --- aggregation ----------------------------------------------------------

  defp sum([@undefined]), do: @undefined
  defp sum([list]), do: Enum.sum(list)

  defp count([@undefined]), do: 0
  defp count([list]), do: length(list)

  defp agg([@undefined], _fun), do: @undefined
  defp agg([[]], _fun), do: @undefined
  defp agg([list], fun), do: fun.(list)

  defp average([@undefined]), do: @undefined
  defp average([[]]), do: @undefined
  defp average([list]), do: Enum.sum(list) / length(list)

  # --- numeric --------------------------------------------------------------

  defp num1([@undefined], _fun), do: @undefined
  defp num1([value], fun), do: fun.(value)

  defp floor_num(value) when is_integer(value), do: value
  defp floor_num(value), do: value |> Float.floor() |> trunc()

  defp ceil_num(value) when is_integer(value), do: value
  defp ceil_num(value), do: value |> Float.ceil() |> trunc()

  defp number([@undefined]), do: @undefined
  defp number([value]) when is_number(value), do: value
  defp number([true]), do: 1
  defp number([false]), do: 0

  defp number([value]) when is_binary(value) do
    case parse_radix(value) || parse_number(value) do
      {:ok, number} -> number
      _ -> raise Error.new("D3030", value: value)
    end
  end

  # JavaScript-style 0x / 0b / 0o integer literals
  defp parse_radix(value) do
    case Regex.run(~r/^0([xXbBoO])([0-9a-fA-F]+)$/, value) do
      [_, prefix, digits] -> {:ok, String.to_integer(digits, radix_for(prefix))}
      nil -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp radix_for(p) when p in ["x", "X"], do: 16
  defp radix_for(p) when p in ["b", "B"], do: 2
  defp radix_for(p) when p in ["o", "O"], do: 8

  defp round_fn([@undefined | _]), do: @undefined
  defp round_fn([value]), do: bankers_round(value, 0)
  defp round_fn([value, @undefined]), do: bankers_round(value, 0)
  defp round_fn([value, precision]), do: bankers_round(value, trunc(precision))

  @doc "JSONata `$round` — round half to even, exposed for `$formatBase`/datetime."
  @spec bankers_round(number(), integer()) :: number()
  # an integer is already rounded at non-negative precision (and stays exact —
  # avoids the precision loss of float conversion for big integers)
  def bankers_round(value, precision) when is_integer(value) and precision >= 0, do: value
  def bankers_round(value, 0), do: normalize_number(round_half_even(value * 1.0))

  def bankers_round(value, precision) do
    # shift the decimal place in the string form to dodge the float-precision
    # errors that scaling by a power of ten introduces (mirrors jsonata-js)
    shifted = decimal_shift(value * 1.0, precision)
    normalize_number(decimal_shift(round_half_even(shifted), -precision))
  end

  defp decimal_shift(value, places) do
    [mantissa | exponent] = String.split(number_to_string(value), "e")
    shifted = if exponent == [], do: places, else: String.to_integer(hd(exponent)) + places
    {number, ""} = Float.parse(mantissa <> "e" <> Integer.to_string(shifted))
    number
  end

  defp round_half_even(value) do
    result = Float.floor(value + 0.5)

    if abs(result - value) == 0.5 and abs(rem(trunc(result), 2)) == 1,
      do: result - 1.0,
      else: result
  end

  defp power([@undefined | _]), do: @undefined
  defp power([_base, @undefined]), do: @undefined

  defp power([base, exp]) do
    normalize_number(:math.pow(base, exp))
  rescue
    ArithmeticError -> reraise Error.new("D3061", value: base, exp: exp), __STACKTRACE__
  end

  defp sqrt([@undefined]), do: @undefined
  defp sqrt([value]) when value < 0, do: raise(Error.new("D3060", value: value))
  defp sqrt([value]), do: normalize_number(:math.sqrt(value))

  defp format_base([@undefined | _]), do: @undefined
  defp format_base([value]), do: format_base([value, 10])
  defp format_base([value, :undefined]), do: format_base([value, 10])

  defp format_base([value, radix]) do
    radix = bankers_round(radix, 0)

    if radix < 2 or radix > 36 do
      raise Error.new("D3100", value: radix)
    end

    value |> bankers_round(0) |> Integer.to_string(radix) |> String.downcase()
  end

  defp format_number([@undefined | _]), do: @undefined

  defp format_number([value, picture]),
    do: Jsonata.FormatNumber.format_number(value, picture, @undefined)

  defp format_number([value, picture, options]),
    do: Jsonata.FormatNumber.format_number(value, picture, options)

  # --- string ---------------------------------------------------------------

  defp str1([@undefined | _], _fun), do: @undefined
  defp str1([value | _], fun), do: fun.(value)

  defp string([@undefined | _]), do: @undefined
  defp string([value]), do: jstring(value, false)
  defp string([value, prettify]), do: jstring(value, prettify == true)

  defp trim(string) do
    string |> String.split(~r/\s+/, trim: true) |> Enum.join(" ")
  end

  defp substring([@undefined | _]), do: @undefined
  defp substring([string, start]), do: substring([string, start, @undefined])

  defp substring([string, start, length]) do
    chars = String.graphemes(string)
    size = length(chars)
    start = if start < 0, do: max(size + trunc(start), 0), else: min(trunc(start), size)
    take = if length == @undefined, do: size - start, else: max(trunc(length), 0)
    chars |> Enum.slice(start, take) |> Enum.join()
  end

  defp substring_before([@undefined | _]), do: @undefined

  defp substring_before([string, chars]) do
    case :binary.split(string, chars) do
      [before, _rest] -> before
      [whole] -> whole
    end
  end

  defp substring_after([@undefined | _]), do: @undefined

  defp substring_after([string, chars]) do
    case :binary.split(string, chars) do
      [_before, rest] -> rest
      [whole] -> whole
    end
  end

  defp pad([@undefined | _]), do: @undefined
  defp pad([string, width]), do: pad([string, width, " "])
  defp pad([string, width, @undefined]), do: pad([string, width, " "])
  defp pad([string, width, ""]), do: pad([string, width, " "])

  defp pad([string, width, char]) do
    pad_to = abs(trunc(width))

    cond do
      String.length(string) >= pad_to -> string
      width < 0 -> String.pad_leading(string, pad_to, char)
      true -> String.pad_trailing(string, pad_to, char)
    end
  end

  defp contains([@undefined | _]), do: @undefined
  defp contains([string, %Function{regex: regex}]), do: Regex.match?(regex, string)

  defp contains([string, substring]) when is_binary(substring),
    do: String.contains?(string, substring)

  defp split([@undefined | _]), do: @undefined
  defp split([string, separator]), do: split([string, separator, @undefined])

  defp split([string, "", limit]), do: string |> String.graphemes() |> take_limit(limit)

  defp split([string, %Function{regex: regex}, limit]),
    do: regex |> Regex.split(string) |> take_limit(limit)

  defp split([string, separator, limit]) when is_binary(separator),
    do: string |> String.split(separator) |> take_limit(limit)

  defp take_limit(list, @undefined), do: list
  defp take_limit(list, limit), do: Enum.take(list, trunc(limit))

  defp join([@undefined | _]), do: @undefined
  defp join([list]), do: Enum.join(list)
  defp join([list, @undefined]), do: Enum.join(list)
  defp join([list, separator]), do: Enum.join(list, separator)

  defp replace([@undefined | _]), do: @undefined

  defp replace([string, pattern, replacement]),
    do: replace([string, pattern, replacement, @undefined])

  defp replace([string, %Function{regex: regex}, replacement, limit])
       when is_binary(replacement) do
    replacement = String.replace(replacement, ~r/\$(\d)/, "\\\\\\1")

    case limit do
      @undefined -> Regex.replace(regex, string, replacement)
      n -> Regex.replace(regex, string, replacement, global: trunc(n) > 1)
    end
  end

  defp replace([string, pattern, replacement, limit])
       when is_binary(pattern) and is_binary(replacement) do
    case limit do
      @undefined -> String.replace(string, pattern, replacement)
      n -> replace_n(string, pattern, replacement, trunc(n))
    end
  end

  defp replace_n(string, _pattern, _replacement, 0), do: string

  defp replace_n(string, pattern, replacement, n) do
    case :binary.split(string, pattern) do
      [before, rest] -> before <> replacement <> replace_n(rest, pattern, replacement, n - 1)
      [whole] -> whole
    end
  end

  # --- regular expressions --------------------------------------------------

  @doc "Builds a callable matcher function from a tokenized regex literal."
  @spec regex_function(%{pattern: String.t(), flags: String.t()}) :: Function.t()
  def regex_function(%{pattern: pattern, flags: flags}) do
    regex = Regex.compile!(pattern, regex_opts(flags))

    %Function{
      name: "regex",
      regex: regex,
      arity: 1,
      impl: fn args -> regex_apply(regex, args) end
    }
  end

  defp regex_opts(flags),
    do: flags |> String.graphemes() |> Enum.filter(&(&1 in ["i", "m"])) |> Enum.join()

  # Applying a regex to a string returns the first match object (or undefined).
  defp regex_apply(regex, [string | _]) when is_binary(string) do
    case regex_matches(regex, string) do
      [first | _] -> first
      [] -> @undefined
    end
  end

  defp regex_apply(_regex, _args), do: @undefined

  defp match([@undefined | _]), do: @undefined
  defp match([string, regex]), do: match([string, regex, @undefined])

  defp match([string, %Function{regex: regex}, limit]) do
    regex |> regex_matches(string) |> take_limit(limit) |> Sequence.from_value()
  end

  defp regex_matches(regex, string) do
    regex
    |> Regex.scan(string, return: :index)
    |> Enum.map(fn [{start, len} | groups] ->
      %{
        "match" => binary_part(string, start, len),
        "index" => string |> binary_part(0, start) |> String.length(),
        "groups" => Enum.map(groups, &group_value(string, &1))
      }
    end)
  end

  defp group_value(_string, {-1, _len}), do: @undefined
  defp group_value(string, {start, len}), do: binary_part(string, start, len)

  defp encode_component(string), do: URI.encode(string, &URI.char_unreserved?/1)
  defp encode_url(string), do: URI.encode(string)

  # --- array / object -------------------------------------------------------

  defp append([@undefined, arg2]), do: arg2
  defp append([arg1, @undefined]), do: arg1
  defp append([arg1, arg2]), do: as_list(arg1) ++ as_list(arg2)

  defp reverse([@undefined]), do: @undefined
  defp reverse([list]), do: Enum.reverse(list)

  defp shuffle([@undefined]), do: @undefined
  defp shuffle([[single]]), do: [single]
  defp shuffle([list]), do: Enum.shuffle(list)

  defp distinct([@undefined]), do: @undefined
  defp distinct([list]) when is_list(list), do: dedup(list, [])
  defp distinct([value]), do: value

  defp dedup([], acc), do: Enum.reverse(acc)

  defp dedup([head | tail], acc) do
    if Enum.any?(acc, &Value.deep_equal(&1, head)),
      do: dedup(tail, acc),
      else: dedup(tail, [head | acc])
  end

  defp sort([@undefined | _]), do: @undefined
  defp sort([list, :undefined]), do: sort([list])

  defp sort([list, %Function{} = comparator]) do
    Enum.sort(list, fn a, b -> not jboolean(comparator.impl.([a, b])) end)
  end

  defp sort([list]) do
    cond do
      Enum.all?(list, &is_number/1) -> Enum.sort(list)
      Enum.all?(list, &is_binary/1) -> Enum.sort(list)
      true -> raise Error.new("D3070")
    end
  end

  # an undefined argument makes the whole zip empty (matches jsonata-js)
  defp zip(arrays) do
    if Enum.any?(arrays, &(&1 == @undefined)) do
      []
    else
      arrays
      |> Enum.map(&as_list/1)
      |> Enum.zip()
      |> Enum.map(&Tuple.to_list/1)
    end
  end

  defp keys([@undefined]), do: @undefined
  defp keys([map]) when is_map(map), do: Map.keys(map)
  defp keys([list]) when is_list(list), do: list |> Enum.flat_map(&object_keys/1) |> Enum.uniq()
  defp keys([_value]), do: @undefined

  defp object_keys(map) when is_map(map), do: Map.keys(map)
  defp object_keys(_value), do: []

  defp lookup([@undefined, _key]), do: @undefined
  defp lookup([map, key]) when is_map(map), do: Map.get(map, key, @undefined)

  defp lookup([list, key]) when is_list(list) do
    list
    |> Enum.flat_map(fn item ->
      case lookup([item, key]) do
        @undefined -> []
        value when is_list(value) -> value
        value -> [value]
      end
    end)
    |> case do
      [] -> @undefined
      results -> collapse_list(results)
    end
  end

  defp lookup([_value, _key]), do: @undefined

  defp spread([@undefined]), do: @undefined
  defp spread([map]) when is_map(map), do: Enum.map(map, fn {k, v} -> %{k => v} end)
  defp spread([list]) when is_list(list), do: Enum.flat_map(list, &spread([&1]))
  defp spread([value]), do: value

  defp merge([@undefined]), do: @undefined
  defp merge([list]), do: Enum.reduce(list, %{}, &Map.merge(&2, &1))

  defp exists([@undefined]), do: false
  defp exists([_value]), do: true

  defp type([@undefined]), do: @undefined
  defp type([nil]), do: "null"
  defp type([value]) when is_boolean(value), do: "boolean"
  defp type([value]) when is_number(value), do: "number"
  defp type([value]) when is_binary(value), do: "string"
  defp type([value]) when is_list(value), do: "array"
  defp type([%Function{}]), do: "function"
  defp type([value]) when is_map(value), do: "object"

  # --- boolean --------------------------------------------------------------

  defp bool1([@undefined | _], _fun), do: @undefined
  defp bool1([value | _], fun), do: fun.(jboolean(value))

  defp not_fn([@undefined]), do: @undefined
  defp not_fn([value]), do: not jboolean(value)

  @doc "JSONata truthiness (`$boolean`), exposed for the evaluator."
  @spec jboolean(term()) :: boolean()
  def jboolean(value) when is_boolean(value), do: value
  def jboolean(value) when is_binary(value), do: value != ""
  def jboolean(value) when is_number(value), do: value != 0
  def jboolean(nil), do: false
  def jboolean(%Function{}), do: false
  def jboolean([single]), do: jboolean(single)
  def jboolean(value) when is_list(value), do: Enum.any?(value, &jboolean/1)
  def jboolean(value) when is_map(value), do: map_size(value) > 0
  def jboolean(_value), do: false

  # --- control --------------------------------------------------------------

  defp error([@undefined]), do: raise(Error.new("D3137", message: "$error() function evaluated"))
  defp error([message]), do: raise(Error.new("D3137", message: message))

  defp assert([true | _]), do: @undefined
  defp assert([false]), do: raise(Error.new("D3141", message: "$assert() statement failed"))
  defp assert([false, message]), do: raise(Error.new("D3141", message: message))

  # --- shared helpers -------------------------------------------------------

  @doc "JSONata `$string` serialization, exposed for the evaluator's `&` operator."
  @spec jstring(term()) :: String.t()
  def jstring(value), do: jstring(value, false)

  @doc "JSONata `$string` serialization; `pretty?` enables 2-space indented JSON."
  @spec jstring(term(), boolean()) :: String.t()
  def jstring(value, _pretty?) when is_binary(value), do: value
  def jstring(value, _pretty?) when is_boolean(value), do: to_string(value)
  def jstring(nil, _pretty?), do: "null"
  def jstring(%Function{}, _pretty?), do: ""
  def jstring(value, _pretty?) when is_number(value), do: string_number(value)
  def jstring(value, pretty?), do: encode_json(value, pretty?, 0)

  # $string applies `Number(toPrecision(15))` to non-integer numbers (collapsing
  # floating-point noise) before rendering with JS Number-to-string semantics.
  defp string_number(value) when is_integer(value), do: Integer.to_string(value)

  defp string_number(value) when is_float(value) do
    rounded =
      if value == Float.round(value) do
        value
      else
        {f, _} = Float.parse(:erlang.iolist_to_binary(:io_lib.format(~c"~.15g", [value])))
        f
      end

    number_to_string(rounded)
  end

  @doc "JSONata number-to-string, matching ECMAScript `Number.prototype.toString`."
  @spec number_to_string(number()) :: String.t()
  def number_to_string(value) when is_integer(value), do: Integer.to_string(value)
  def number_to_string(value) when is_float(value) and value == 0.0, do: "0"

  def number_to_string(value) when is_float(value) do
    sign = if value < 0, do: "-", else: ""
    {digits, n} = significant_digits(abs(value))
    sign <> ecma_number(digits, n)
  end

  # Returns {digits, n}: `digits` are the shortest significant decimal digits and
  # the value equals `digits × 10^(n - length(digits))` (ECMA-262 6.1.6.1.20).
  defp significant_digits(value) do
    {mantissa, exp} =
      case String.split(:erlang.float_to_binary(value, [:short]), ["e", "E"]) do
        [m] -> {m, 0}
        [m, e] -> {m, String.to_integer(e)}
      end

    {int_part, frac_part} =
      case String.split(mantissa, ".") do
        [i] -> {i, ""}
        [i, f] -> {i, f}
      end

    s0 = String.to_integer(int_part <> frac_part)
    {s, power} = strip_trailing_zeros(s0, exp - String.length(frac_part))
    digits = Integer.to_string(s)
    {digits, power + String.length(digits)}
  end

  defp strip_trailing_zeros(s, power) when s != 0 and rem(s, 10) == 0,
    do: strip_trailing_zeros(div(s, 10), power + 1)

  defp strip_trailing_zeros(s, power), do: {s, power}

  defp ecma_number(digits, n) do
    k = String.length(digits)

    cond do
      k <= n and n <= 21 -> digits <> String.duplicate("0", n - k)
      0 < n and n <= 21 -> String.slice(digits, 0, n) <> "." <> String.slice(digits, n, k - n)
      -6 < n and n <= 0 -> "0." <> String.duplicate("0", -n) <> digits
      true -> ecma_exponential(digits, k, n)
    end
  end

  defp ecma_exponential(digits, k, n) do
    mantissa =
      if k == 1,
        do: digits,
        else: String.slice(digits, 0, 1) <> "." <> String.slice(digits, 1, k - 1)

    exponent = n - 1
    sign = if exponent >= 0, do: "+", else: "-"
    mantissa <> "e" <> sign <> Integer.to_string(abs(exponent))
  end

  # JSON serialization for $string of composite values (the JSON.stringify path):
  # numbers are rounded as above, functions render as the empty string.
  defp encode_json(nil, _pretty?, _depth), do: "null"
  defp encode_json(value, _pretty?, _depth) when is_boolean(value), do: to_string(value)
  defp encode_json(value, _pretty?, _depth) when is_number(value), do: string_number(value)
  defp encode_json(value, _pretty?, _depth) when is_binary(value), do: JSON.encode!(value)
  defp encode_json(%Function{}, _pretty?, _depth), do: "\"\""

  defp encode_json(value, pretty?, depth) when is_list(value),
    do: encode_container(value, "[", "]", pretty?, depth, &encode_json(&1, pretty?, depth + 1))

  defp encode_json(value, pretty?, depth) when is_map(value) do
    encode_container(value, "{", "}", pretty?, depth, fn {key, val} ->
      JSON.encode!(to_string(key)) <>
        if(pretty?, do: ": ", else: ":") <> encode_json(val, pretty?, depth + 1)
    end)
  end

  defp encode_container(enum, open, close, pretty?, depth, encode_item) do
    case Enum.map(enum, encode_item) do
      [] ->
        open <> close

      items when pretty? ->
        pad = String.duplicate("  ", depth + 1)
        body = Enum.map_join(items, ",\n", &(pad <> &1))
        open <> "\n" <> body <> "\n" <> String.duplicate("  ", depth) <> close

      items ->
        open <> Enum.join(items, ",") <> close
    end
  end

  # Always called with a float result (sqrt/pow/division); collapses whole values
  # to integers to match JSONata's single number type.
  defp normalize_number(value) when is_float(value) do
    if value == Float.round(value) and abs(value) < 1.0e15, do: trunc(value), else: value
  end

  defp as_list(value) when is_list(value), do: value
  defp as_list(value), do: [value]

  defp collapse_list([single]), do: single
  defp collapse_list(list), do: list

  defp parse_number(text) do
    if String.contains?(text, [".", "e", "E"]) do
      parse_with(text, &Float.parse/1)
    else
      parse_with(text, &Integer.parse/1)
    end
  end

  defp parse_with(text, parser) do
    case parser.(text) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end
end
