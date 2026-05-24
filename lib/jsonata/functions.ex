defmodule Jsonata.Functions do
  @moduledoc """
  The JSONata built-in function library (the non-temporal, non-higher-order
  subset — Phase 3). Each entry pairs a name with its signature and an
  implementation taking the validated argument list.

  Higher-order functions (`$map`, `$filter`, `$reduce`, `$sift`, `$each`,
  `$single`, comparator `$sort`), regex-based `$match`/`$contains`/`$replace`/
  `$split`, and date/time functions are implemented in later phases.
  """

  alias Jsonata.{Environment, Error, Function, Signature, Value}

  @undefined :undefined

  @doc "Binds every built-in function into `env`."
  @spec bind_all(Environment.t()) :: Environment.t()
  def bind_all(env) do
    Enum.reduce(registry(), env, fn {name, signature, impl}, acc ->
      function = %Function{name: name, impl: impl, signature: Signature.parse(signature)}
      Environment.bind(acc, name, function)
    end)
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
      {"base64encode", "<s-:s>", fn args -> str1(args, &Base.encode64/1) end},
      {"base64decode", "<s-:s>", fn args -> str1(args, &Base.decode64!/1) end},
      {"encodeUrlComponent", "<s-:s>", fn args -> str1(args, &encode_component/1) end},
      {"encodeUrl", "<s-:s>", fn args -> str1(args, &encode_url/1) end},
      {"decodeUrlComponent", "<s-:s>", fn args -> str1(args, &URI.decode/1) end},
      {"decodeUrl", "<s-:s>", fn args -> str1(args, &URI.decode/1) end},
      # --- array / object ---
      {"append", "<xx:a>", &append/1},
      {"reverse", "<a:a>", &reverse/1},
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
      # --- control ---
      {"error", "<s?:x>", &error/1},
      {"assert", "<bs?:x>", &assert/1}
    ]
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
    case parse_number(value) do
      {:ok, number} -> number
      :error -> raise Error.new("D3030", value: value)
    end
  end

  defp round_fn([@undefined | _]), do: @undefined
  defp round_fn([value]), do: round_half_even(value, 0)
  defp round_fn([value, @undefined]), do: round_half_even(value, 0)
  defp round_fn([value, precision]), do: round_half_even(value, precision)

  # Banker's rounding (round half to even), matching JSONata $round.
  defp round_half_even(value, precision) do
    factor = :math.pow(10, precision)
    scaled = value * factor
    floor_val = Float.floor(scaled)
    diff = scaled - floor_val

    rounded =
      cond do
        diff < 0.5 -> floor_val
        diff > 0.5 -> floor_val + 1
        rem(trunc(floor_val), 2) == 0 -> floor_val
        true -> floor_val + 1
      end

    normalize_number(rounded / factor)
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

  # --- string ---------------------------------------------------------------

  defp str1([@undefined | _], _fun), do: @undefined
  defp str1([value | _], fun), do: fun.(value)

  defp string([@undefined | _]), do: @undefined
  defp string([value]), do: jstring(value)
  defp string([value, _prettify]), do: jstring(value)

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

  defp pad([string, width, char]) do
    pad_to = abs(trunc(width))

    cond do
      String.length(string) >= pad_to -> string
      width < 0 -> String.pad_leading(string, pad_to, char)
      true -> String.pad_trailing(string, pad_to, char)
    end
  end

  defp contains([@undefined | _]), do: @undefined

  defp contains([string, substring]) when is_binary(substring),
    do: String.contains?(string, substring)

  defp split([@undefined | _]), do: @undefined
  defp split([string, separator]), do: split([string, separator, @undefined])

  defp split([string, "", limit]), do: string |> String.graphemes() |> take_limit(limit)

  defp split([string, separator, limit]) when is_binary(separator),
    do: string |> String.split(separator) |> take_limit(limit)

  defp take_limit(list, @undefined), do: list
  defp take_limit(list, limit), do: Enum.take(list, trunc(limit))

  defp join([@undefined | _]), do: @undefined
  defp join([list]), do: Enum.join(list)
  defp join([list, @undefined]), do: Enum.join(list)
  defp join([list, separator]), do: Enum.join(list, separator)

  defp replace([@undefined | _]), do: @undefined

  defp replace([string, pattern, replacement]) when is_binary(pattern) and is_binary(replacement),
    do: replace([string, pattern, replacement, @undefined])

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

  defp encode_component(string), do: URI.encode(string, &URI.char_unreserved?/1)
  defp encode_url(string), do: URI.encode(string)

  # --- array / object -------------------------------------------------------

  defp append([@undefined, arg2]), do: arg2
  defp append([arg1, @undefined]), do: arg1
  defp append([arg1, arg2]), do: as_list(arg1) ++ as_list(arg2)

  defp reverse([@undefined]), do: @undefined
  defp reverse([list]), do: Enum.reverse(list)

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

  defp sort([_list, _comparator]) do
    raise "$sort with a comparator function is implemented in a later phase"
  end

  defp sort([list]) do
    cond do
      Enum.all?(list, &is_number/1) -> Enum.sort(list)
      Enum.all?(list, &is_binary/1) -> Enum.sort(list)
      true -> raise Error.new("D3070")
    end
  end

  defp zip(arrays) do
    arrays
    |> Enum.map(&as_list/1)
    |> Enum.zip()
    |> Enum.map(&Tuple.to_list/1)
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
    |> collapse_list()
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
  def jstring(value) when is_binary(value), do: value
  def jstring(value) when is_boolean(value), do: to_string(value)
  def jstring(nil), do: "null"
  def jstring(value) when is_number(value), do: number_to_string(value)
  def jstring(value), do: JSON.encode!(value)

  @doc "JSONata number-to-string (whole floats lose the decimal point)."
  @spec number_to_string(number()) :: String.t()
  def number_to_string(value) when is_integer(value), do: Integer.to_string(value)

  def number_to_string(value) when is_float(value) do
    if value == Float.round(value) and abs(value) < 1.0e21 do
      value |> trunc() |> Integer.to_string()
    else
      to_string(value)
    end
  end

  defp normalize_number(value) when is_float(value) do
    if value == Float.round(value) and abs(value) < 1.0e15, do: trunc(value), else: value
  end

  defp normalize_number(value), do: value

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
