defmodule Jsonata.Evaluator do
  @moduledoc """
  Tree-walking evaluator over the `Jsonata.AST`, ported from the core of
  `jsonata.js`. It uses `Jsonata.Sequence` for path results and `Jsonata.Value`
  for the *nothing* value and equality.

  The environment is threaded through evaluation as an immutable value: `eval/3`
  returns `{value, environment}` so that `:=` bindings in a block are visible to
  later expressions in the same scope. Errors raise `Jsonata.Error`.

  Scope: paths/steps, predicates, all binary/unary operators, ranges,
  conditionals, blocks, binds, array/object constructors, wildcards, descendants,
  variables (Phase 2); function invocation, lambdas with closures and
  self-recursion, the `~>` apply/compose operator, higher-order functions, regex
  matchers, `$eval`, order-by `^`, grouping `{`, partial application `?`, and the
  positional tuple-stream operators focus `@` / index `#` (Phases 3-4, 6). Not
  yet evaluated: the transform `|` operator.
  """

  alias Jsonata.{Environment, Error, Function, Functions, Sequence, Signature, Value}

  @undefined :undefined

  @doc "Evaluates `ast` against `input` in `env`, returning the JSONata value."
  @spec evaluate(Jsonata.AST.t(), term(), Environment.t()) :: term()
  def evaluate(ast, input, env) do
    {value, _env} = eval(ast, input, env)
    value
  end

  # Returns {value, environment}. Most nodes leave the environment unchanged;
  # :bind and :block update/scope it.
  defp eval(expr, input, env) do
    {raw, env} = eval_node(expr, input, env)
    raw = apply_predicates(expr, raw, env)
    raw = maybe_group(expr, raw, env)
    {finalize(expr, raw), env}
  end

  # Group-by on a non-path node is applied here; a path applies its own group.
  defp maybe_group(%{type: :path}, raw, _env), do: raw
  defp maybe_group(%{group: group}, raw, env), do: group_by(group, raw, false, env)
  defp maybe_group(_expr, raw, _env), do: raw

  defp eval_val(expr, input, env) do
    {value, _env} = eval(expr, input, env)
    value
  end

  # --- node dispatch (technique T4) -----------------------------------------

  defp eval_node(%{type: :path} = expr, input, env), do: {evaluate_path(expr, input, env), env}

  defp eval_node(%{type: :binary, value: "~>"} = expr, input, env),
    do: {evaluate_apply(expr, input, env), env}

  defp eval_node(%{type: :binary} = expr, input, env),
    do: {evaluate_binary(expr, input, env), env}

  defp eval_node(%{type: :unary} = expr, input, env), do: {evaluate_unary(expr, input, env), env}
  defp eval_node(%{type: :name} = expr, input, env), do: {lookup(input, expr.value), env}
  defp eval_node(%{type: :wildcard}, input, env), do: {evaluate_wildcard(input), env}
  defp eval_node(%{type: :descendant}, input, env), do: {evaluate_descendants(input), env}

  defp eval_node(%{type: :condition} = expr, input, env),
    do: {evaluate_condition(expr, input, env), env}

  defp eval_node(%{type: :coalesce} = expr, input, env),
    do: {evaluate_coalesce(expr, input, env), env}

  defp eval_node(%{type: :variable} = expr, input, env),
    do: {evaluate_variable(expr, input, env), env}

  defp eval_node(%{type: :regex} = expr, _input, env),
    do: {Functions.regex_function(expr.value), env}

  defp eval_node(%{type: literal} = expr, _input, env) when literal in [:number, :string, :value],
    do: {expr.value, env}

  defp eval_node(%{type: :bind} = expr, input, env) do
    value = name_lambda(eval_val(expr.rhs, input, env), expr.lhs.value)
    {value, Environment.bind(env, expr.lhs.value, value)}
  end

  defp eval_node(%{type: :block} = expr, input, env) do
    frame = Environment.child(env)

    {result, _frame} =
      Enum.reduce(expr.expressions, {@undefined, frame}, fn child, {_acc, frame_env} ->
        eval(child, input, frame_env)
      end)

    {result, env}
  end

  defp eval_node(%{type: :function} = expr, input, env),
    do: {evaluate_function(expr, input, env, :none), env}

  defp eval_node(%{type: :lambda} = expr, input, env), do: {make_lambda(expr, input, env), env}

  defp eval_node(%{type: :partial} = expr, input, env),
    do: {partial_apply(expr, input, env), env}

  # `$f(?, x)` builds a function awaiting the placeholder positions.
  defp partial_apply(expr, input, env) do
    proc = eval_val(expr.procedure, input, env)

    args =
      Enum.map(expr.arguments, fn
        %{type: :placeholder} = hole -> hole
        arg -> wrap_argument(eval_val(arg, input, env), input)
      end)

    holes = Enum.count(args, &match?(%{type: :placeholder}, &1))

    %Function{
      name: "partial",
      arity: holes,
      impl: fn supplied ->
        apply_function(proc, fill_holes(args, supplied), nil, expr.position)
      end
    }
  end

  defp fill_holes(args, supplied) do
    {filled, _rest} =
      Enum.map_reduce(args, supplied, fn
        %{type: :placeholder}, [value | rest] -> {value, rest}
        %{type: :placeholder}, [] -> {@undefined, []}
        arg, rest -> {arg, rest}
      end)

    filled
  end

  defp make_lambda(expr, input, env) do
    %Function{
      name: "lambda",
      params: Enum.map(expr.arguments, & &1.value),
      body: expr.body,
      env: env,
      input: input,
      arity: length(expr.arguments),
      signature: lambda_signature(expr.signature)
    }
  end

  defp lambda_signature(nil), do: nil
  defp lambda_signature(sig) when is_binary(sig), do: Signature.parse(sig)

  # Records the bound name on a lambda so it can re-bind itself at application
  # time, enabling self-recursion (`$f := function(...){ ... $f(...) }`).
  defp name_lambda(%Function{body: body} = func, name) when not is_nil(body),
    do: %{func | self_name: name}

  defp name_lambda(value, _name), do: value

  # `$eval(str, context?)` parses and evaluates a JSONata string in the current
  # scope; it is a special form because it needs the parser and environment.
  defp evaluate_function(
         %{procedure: %{type: :variable, value: "eval"}} = expr,
         input,
         env,
         applyto
       ) do
    args = Enum.map(expr.arguments, &eval_val(&1, input, env))
    args = if applyto == :none, do: args, else: [applyto | args]
    eval_string(args, input, env)
  end

  # `applyto` (the LHS of `~>`) is prepended to the argument list when present.
  defp evaluate_function(expr, input, env, applyto) do
    proc = eval_val(expr.procedure, input, env)
    args = Enum.map(expr.arguments, fn arg -> wrap_argument(eval_val(arg, input, env), input) end)
    args = if applyto == :none, do: args, else: [applyto | args]
    apply_function(proc, args, input, expr.position)
  end

  # A function passed as an argument is wrapped as a closure so higher-order
  # functions (in Jsonata.Functions) can apply it without depending on the evaluator.
  defp wrap_argument(%Function{} = func, input) do
    %Function{
      name: func.name,
      arity: func.arity,
      regex: func.regex,
      impl: &apply_function(func, &1, input, nil)
    }
  end

  defp wrap_argument(value, _input), do: value

  defp evaluate_apply(expr, input, env) do
    lhs = eval_val(expr.lhs, input, env)

    case expr.rhs do
      %{type: :function} = call ->
        evaluate_function(call, input, env, lhs)

      rhs ->
        func = eval_val(rhs, input, env)

        # `f ~> g` with f a function is composition: λ($x){ g(f($x)) }.
        if match?(%Function{}, lhs),
          do: compose(lhs, func),
          else: apply_function(func, [lhs], input, expr.position)
    end
  end

  defp compose(%Function{} = f, %Function{} = g) do
    %Function{
      name: "composed",
      arity: 1,
      impl: fn args -> apply_function(g, [apply_function(f, args, nil, nil)], nil, nil) end
    }
  end

  defp apply_function(%Function{impl: impl, signature: sig, name: name}, args, input, _position)
       when not is_nil(impl) do
    impl.(validate_args(sig, args, input, name))
  end

  defp apply_function(%Function{body: body, env: env} = func, args, _input, _position)
       when not is_nil(body) do
    validated = validate_args(func.signature, args, func.input, func.name)

    base =
      if func.self_name,
        do: Environment.bind(Environment.child(env), func.self_name, func),
        else: Environment.child(env)

    frame =
      func.params
      |> Enum.with_index()
      |> Enum.reduce(base, fn {param, index}, acc ->
        Environment.bind(acc, param, Enum.at(validated, index, @undefined))
      end)

    evaluate(body, func.input, frame)
  end

  defp apply_function(_proc, _args, _input, position),
    do: raise(Error.new("T1006", position: position))

  defp validate_args(nil, args, _input, _name), do: args

  defp validate_args(signature, args, input, name),
    do: Signature.validate(signature, args, input, name)

  defp eval_string([@undefined | _], _input, _env), do: @undefined

  defp eval_string([source | rest], input, env) when is_binary(source) do
    context = if match?([ctx | _] when ctx != @undefined, rest), do: hd(rest), else: input

    case Jsonata.Parser.parse(source) do
      {:ok, ast} -> evaluate(ast, context, env)
      {:error, error} -> raise error
    end
  end

  # --- paths ----------------------------------------------------------------

  defp evaluate_path(%{steps: steps} = expr, input, env) do
    # The path input is a single context value (the data root or a single element
    # produced by a prior step/filter). A top-level array is therefore treated as
    # one context — the first step's lookup maps over it — matching JSONata's
    # `outerWrapper` semantics. `tuples` is `:none` outside tuple-stream mode (the
    # `@`/`#` operators), otherwise the list of tuple-binding maps.
    {result, tuples} = run_steps(steps, 0, Sequence.singleton(input), :none, env, length(steps))

    {final, group_source} =
      if tuples == :none do
        {result, result}
      else
        {if(Map.get(expr, :tuple, false), do: tuples, else: detuple(tuples)), tuples}
      end

    final = maybe_keep_singleton(expr, final)

    case Map.get(expr, :group) do
      nil -> final
      group -> group_by(group, group_source, tuples != :none, env)
    end
  end

  defp run_steps([], _index, result, tuples, _env, _count), do: {result, tuples}

  defp run_steps([step | rest], index, input_seq, tuples, env, count) do
    cond do
      index == 0 and Map.get(step, :cons_array, false) ->
        continue_steps(rest, index, eval_val(step, input_seq, env), tuples, env, count)

      Map.get(step, :tuple, false) or tuples != :none ->
        new_tuples = evaluate_tuple_step(step, input_seq, tuples, env)
        run_steps(rest, index + 1, input_seq, new_tuples, env, count)

      true ->
        result = evaluate_step(step, input_seq, env, index == count - 1)
        continue_steps(rest, index, result, tuples, env, count)
    end
  end

  defp continue_steps(rest, index, result, tuples, env, count) do
    if rest == [] or empty_result?(result) do
      {result, tuples}
    else
      run_steps(rest, index + 1, result, tuples, env, count)
    end
  end

  defp empty_result?(@undefined), do: true
  defp empty_result?(%Sequence{} = seq), do: Enum.empty?(seq)
  defp empty_result?(_other), do: false

  defp evaluate_step(%{type: :sort} = step, input, env, _last_step?) do
    sorted =
      input
      |> Enum.to_list()
      |> sort_by_terms(step.terms, fn expr, item -> eval_val(expr, item, env) end)
      |> Sequence.from_value()

    apply_stages(sorted, Map.get(step, :stages, []), env)
  end

  defp evaluate_step(step, input, env, last_step?) do
    results =
      input
      |> Enum.map(&stage_eval(step, &1, env))
      |> Enum.reject(&(&1 == @undefined))

    cons? = match?(%{type: :unary, value: "["}, step)

    if last_step? and not cons? and match?([single] when is_list(single), results) do
      # a single array result at the last step is preserved as-is (not flattened
      # or collapsed) — it is a plain value, not a sequence
      hd(results)
    else
      results
      |> Enum.flat_map(&flatten_step_result(&1, cons?))
      |> Sequence.from_value()
    end
  end

  # A sequence or plain array flattens into the parent; cons arrays and scalars stay atomic.
  defp flatten_step_result(res, true), do: [res]
  defp flatten_step_result(%Sequence{} = res, _cons?), do: Enum.to_list(res)
  defp flatten_step_result(res, _cons?) when is_list(res), do: res
  defp flatten_step_result(res, _cons?), do: [res]

  defp stage_eval(step, item, env) do
    step
    |> eval_val(item, env)
    |> apply_stages(Map.get(step, :stages, []), env)
  end

  defp maybe_keep_singleton(%{keep_singleton_array: true}, %Sequence{} = seq),
    do: %{seq | keep_singleton: true}

  defp maybe_keep_singleton(_expr, result), do: result

  # --- order-by (^) ---------------------------------------------------------

  # Stable sort by the order-by terms; `value_fn` evaluates a term against an
  # item (plain value or tuple). Ties fall through to the next term.
  defp sort_by_terms(list, terms, value_fn),
    do: Enum.sort(list, fn a, b -> sort_compare(a, b, terms, value_fn) <= 0 end)

  defp sort_compare(_a, _b, [], _value_fn), do: 0

  defp sort_compare(a, b, [term | rest], value_fn) do
    raw = compare_terms(value_fn.(term.expression, a), value_fn.(term.expression, b))
    comp = if term.descending, do: -raw, else: raw
    if comp == 0, do: sort_compare(a, b, rest, value_fn), else: comp
  end

  defp compare_terms(@undefined, @undefined), do: 0
  defp compare_terms(@undefined, _bb), do: 1
  defp compare_terms(_aa, @undefined), do: -1

  defp compare_terms(aa, bb) do
    cond do
      not sortable?(aa) -> raise Error.new("T2008", value: aa)
      not sortable?(bb) -> raise Error.new("T2008", value: bb)
      not same_sort_type?(aa, bb) -> raise Error.new("T2007", value: aa, value2: bb)
      aa == bb -> 0
      aa < bb -> -1
      true -> 1
    end
  end

  defp sortable?(value), do: is_number(value) or is_binary(value)

  defp same_sort_type?(aa, bb),
    do: (is_number(aa) and is_number(bb)) or (is_binary(aa) and is_binary(bb))

  # --- group-by ({) ---------------------------------------------------------

  defp group_by(%{lhs: pairs}, source, false, env), do: group_plain(pairs, source, env)
  defp group_by(%{lhs: pairs}, tuples, true, env), do: group_tuples(pairs, tuples, env)

  defp group_plain(pairs, result, env) do
    items =
      case result do
        @undefined -> [@undefined]
        %Sequence{} = seq -> Enum.to_list(seq)
        list when is_list(list) -> list
        value -> [value]
      end

    items = if items == [], do: [@undefined], else: items

    {groups, order} = build_groups(items, pairs, env)

    Enum.reduce(order, %{}, fn key, acc ->
      {data, index} = Map.fetch!(groups, key)
      [_key_ast, value_ast] = Enum.at(pairs, index)

      case eval_val(value_ast, data, env) do
        @undefined -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  # Group a tuple stream: key/value expressions evaluate in each tuple's frame,
  # and grouped tuples are reduced (each binding appended) before the value runs.
  defp group_tuples(pairs, tuples, env) do
    indexed = Enum.with_index(pairs)

    {groups, order} =
      Enum.reduce(tuples, {%{}, []}, fn tuple, acc ->
        frame = frame_from_tuple(env, tuple)

        Enum.reduce(indexed, acc, fn {[key_ast, _value], index}, {groups, order} ->
          key = eval_val(key_ast, tuple["@"], frame)
          add_tuple_group(key, tuple, index, groups, order)
        end)
      end)

    Enum.reduce(order, %{}, fn key, acc ->
      {data_tuples, index} = Map.fetch!(groups, key)
      [_key_ast, value_ast] = Enum.at(pairs, index)
      reduced = reduce_tuples(data_tuples)
      frame = frame_from_tuple(env, reduced)

      case eval_val(value_ast, reduced["@"], frame) do
        @undefined -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp add_tuple_group(@undefined, _tuple, _index, groups, order), do: {groups, order}

  defp add_tuple_group(key, tuple, index, groups, order) when is_binary(key) do
    case Map.get(groups, key) do
      nil -> {Map.put(groups, key, {[tuple], index}), order ++ [key]}
      {tuples, ^index} -> {Map.put(groups, key, {tuples ++ [tuple], index}), order}
      {_tuples, _other} -> raise Error.new("D1009", value: key)
    end
  end

  defp add_tuple_group(key, _tuple, _index, _groups, _order),
    do: raise(Error.new("T1003", value: key))

  defp build_groups(items, pairs, env) do
    indexed_pairs = Enum.with_index(pairs)

    Enum.reduce(items, {%{}, []}, fn item, acc ->
      Enum.reduce(indexed_pairs, acc, fn {[key_ast, _value_ast], index}, {groups, order} ->
        add_group_entry(eval_val(key_ast, item, env), item, index, groups, order)
      end)
    end)
  end

  defp add_group_entry(@undefined, _item, _index, groups, order), do: {groups, order}

  defp add_group_entry(key, item, index, groups, order) when is_binary(key) do
    case Map.get(groups, key) do
      nil -> {Map.put(groups, key, {item, index}), order ++ [key]}
      {data, ^index} -> {Map.put(groups, key, {append_data(data, item), index}), order}
      {_data, _other} -> raise Error.new("D1009", value: key)
    end
  end

  defp add_group_entry(key, _item, _index, _groups, _order),
    do: raise(Error.new("T1003", value: key))

  defp append_data(data, item) when is_list(data), do: data ++ [item]
  defp append_data(data, item), do: [data, item]

  # --- tuple streams (@ focus, # index) -------------------------------------

  # A tuple is a map `%{"@" => context, var => binding, ...}`. `@` binds a
  # variable while keeping the context (a cross-join); `#` advances the context
  # and binds a position. The first tuple step seeds tuples from the input.
  # (A sort step only reaches here once already in tuple mode — i.e. `tuples`
  # is a list — because outside tuple mode it is handled by evaluate_step/4.)
  defp evaluate_tuple_step(%{type: :sort} = step, _input_seq, tuples, env) do
    value_fn = fn expr, tuple -> eval_val(expr, tuple["@"], frame_from_tuple(env, tuple)) end
    apply_tuple_stages(step, sort_by_terms(tuples, step.terms, value_fn), env)
  end

  defp evaluate_tuple_step(step, input_seq, tuples, env) do
    bindings =
      case tuples do
        :none -> input_seq |> Enum.to_list() |> Enum.map(&%{"@" => &1})
        list -> list
      end

    result = Enum.flat_map(bindings, &expand_tuple(step, &1, env))
    apply_tuple_stages(step, result, env)
  end

  defp expand_tuple(step, tuple, env) do
    case eval_val(step, tuple["@"], frame_from_tuple(env, tuple)) do
      @undefined ->
        []

      res ->
        res |> as_value_list() |> Enum.with_index() |> Enum.map(&output_tuple(tuple, step, &1))
    end
  end

  defp output_tuple(tuple, step, {value, index}),
    do: tuple |> bind_step_value(step, value) |> with_index(step, index)

  defp bind_step_value(tuple, %{focus: focus}, value), do: Map.put(tuple, focus, value)
  defp bind_step_value(tuple, _step, value), do: Map.put(tuple, "@", value)

  defp with_index(tuple, %{index: index}, position), do: Map.put(tuple, index, position)
  defp with_index(tuple, _step, _position), do: tuple

  defp as_value_list(%Sequence{} = seq), do: Enum.to_list(seq)
  defp as_value_list(value) when is_list(value), do: value
  defp as_value_list(value), do: [value]

  defp frame_from_tuple(env, tuple),
    do: Enum.reduce(tuple, Environment.child(env), fn {k, v}, e -> Environment.bind(e, k, v) end)

  defp detuple(tuples), do: tuples |> Enum.map(&Map.get(&1, "@")) |> Sequence.from_value()

  defp reduce_tuples([first | rest]) do
    Enum.reduce(rest, first, fn tuple, acc ->
      Enum.reduce(tuple, acc, fn {key, value}, a ->
        Map.update(a, key, value, &append_data(&1, value))
      end)
    end)
  end

  defp apply_tuple_stages(step, tuples, env),
    do: Enum.reduce(Map.get(step, :stages, []), tuples, &apply_tuple_stage(&1, &2, env))

  defp apply_tuple_stage(%{type: :filter, expr: predicate}, tuples, env) do
    count = length(tuples)

    for {tuple, index} <- Enum.with_index(tuples),
        keep_item?(eval_val(predicate, tuple["@"], frame_from_tuple(env, tuple)), index, count),
        do: tuple
  end

  # --- predicates / stages --------------------------------------------------

  defp apply_predicates(%{predicate: predicate}, result, env) when is_list(predicate) do
    Enum.reduce(predicate, result, fn %{expr: pred}, acc -> evaluate_filter(pred, acc, env) end)
  end

  defp apply_predicates(_expr, result, _env), do: result

  defp apply_stages(result, stages, env) do
    Enum.reduce(stages, result, fn %{expr: pred}, acc -> evaluate_filter(pred, acc, env) end)
  end

  defp evaluate_filter(_predicate, @undefined, _env), do: Sequence.empty()

  defp evaluate_filter(%{type: :number, value: value}, input, _env) do
    items = filter_items(input)
    index = number_index(value, length(items))

    case fetch(items, index) do
      @undefined -> Sequence.empty()
      item when is_list(item) -> Sequence.from_value(item)
      item -> Sequence.singleton(item)
    end
  end

  defp evaluate_filter(predicate, input, env) do
    items = filter_items(input)
    count = length(items)

    kept =
      for {item, index} <- Enum.with_index(items),
          keep_item?(eval_val(predicate, item, env), index, count),
          do: item

    Sequence.from_value(kept)
  end

  defp keep_item?(result, index, count) do
    cond do
      is_number(result) -> number_index(result, count) == index
      array_of_numbers?(result) -> Enum.any?(result, &(number_index(&1, count) == index))
      true -> truthy?(result)
    end
  end

  defp filter_items(input) when is_list(input), do: input
  defp filter_items(%Sequence{} = seq), do: Enum.to_list(seq)
  defp filter_items(value), do: [value]

  defp number_index(value, count) do
    index = floor_int(value)
    if index < 0, do: count + index, else: index
  end

  defp floor_int(value) when is_integer(value), do: value
  defp floor_int(value), do: value |> Float.floor() |> trunc()

  defp fetch(items, index) when index >= 0 and index < length(items), do: Enum.at(items, index)
  defp fetch(_items, _index), do: @undefined

  defp array_of_numbers?(value),
    do: is_list(value) and value != [] and Enum.all?(value, &is_number/1)

  # --- finalize (singleton collapse) ----------------------------------------

  defp finalize(expr, %Sequence{tuple_stream: false} = seq) do
    seq = if Map.get(expr, :keep_array, false), do: %{seq | keep_singleton: true}, else: seq
    Sequence.collapse(seq, false)
  end

  defp finalize(_expr, value), do: value

  # --- names, wildcards, descendants ----------------------------------------

  defp lookup(%Sequence{} = seq, key), do: lookup(Enum.to_list(seq), key)

  defp lookup(input, key) when is_list(input) do
    Enum.reduce(input, Sequence.empty(), fn item, acc ->
      case lookup(item, key) do
        @undefined -> acc
        res -> Sequence.append_step(acc, res)
      end
    end)
  end

  defp lookup(input, key) when is_map(input) and not is_struct(input),
    do: Map.get(input, key, @undefined)

  defp lookup(_input, _key), do: @undefined

  defp evaluate_wildcard(input) when is_map(input) and not is_struct(input) do
    Enum.reduce(input, Sequence.empty(), fn {_key, value}, acc ->
      if is_list(value) do
        Sequence.append_step(acc, flatten(value))
      else
        Sequence.append_step(acc, value)
      end
    end)
  end

  defp evaluate_wildcard(_input), do: Sequence.empty()

  defp evaluate_descendants(@undefined), do: @undefined

  defp evaluate_descendants(input) do
    case recurse_descendants(input, []) do
      [single] -> single
      many -> Sequence.from_value(many)
    end
  end

  defp recurse_descendants(input, acc) when is_list(input) do
    Enum.reduce(input, acc, fn member, a -> recurse_descendants(member, a) end)
  end

  defp recurse_descendants(input, acc) when is_map(input) and not is_struct(input) do
    acc = acc ++ [input]
    Enum.reduce(input, acc, fn {_key, value}, a -> recurse_descendants(value, a) end)
  end

  defp recurse_descendants(input, acc), do: acc ++ [input]

  defp flatten(value) when is_list(value), do: Enum.flat_map(value, &flatten/1)
  defp flatten(value), do: [value]

  # --- variables, conditions, coalescing ------------------------------------

  defp evaluate_variable(%{value: ""}, input, _env), do: input
  defp evaluate_variable(%{value: name}, _input, env), do: Environment.lookup(env, name)

  defp evaluate_condition(expr, input, env) do
    if truthy?(eval_val(expr.condition, input, env)) do
      eval_val(expr.then, input, env)
    else
      case Map.fetch(expr, :else) do
        {:ok, else_expr} -> eval_val(else_expr, input, env)
        :error -> @undefined
      end
    end
  end

  defp evaluate_coalesce(expr, input, env) do
    case eval_val(expr.lhs, input, env) do
      @undefined -> eval_val(expr.rhs, input, env)
      value -> value
    end
  end

  # --- binary ---------------------------------------------------------------

  defp evaluate_binary(%{value: op} = expr, input, env) when op in ["and", "or"] do
    lhs = eval_val(expr.lhs, input, env)
    rhs = eval_val(expr.rhs, input, env)
    boolean_op(op, lhs, rhs)
  end

  defp evaluate_binary(%{value: op} = expr, input, env) do
    lhs = eval_val(expr.lhs, input, env)
    rhs = eval_val(expr.rhs, input, env)

    case op do
      arith when arith in ["+", "-", "*", "/", "%"] -> numeric_op(arith, lhs, rhs, expr.position)
      eq when eq in ["=", "!="] -> equality_op(eq, lhs, rhs)
      cmp when cmp in ["<", "<=", ">", ">="] -> comparison_op(cmp, lhs, rhs, expr.position)
      "&" -> string_concat(lhs, rhs)
      ".." -> range_op(lhs, rhs)
      "in" -> includes_op(lhs, rhs)
    end
  end

  defp boolean_op("and", lhs, rhs), do: boolize(lhs) and boolize(rhs)
  defp boolean_op("or", lhs, rhs), do: boolize(lhs) or boolize(rhs)

  defp numeric_op(_op, @undefined, _rhs, _pos), do: @undefined
  defp numeric_op(_op, _lhs, @undefined, _pos), do: @undefined

  defp numeric_op(op, lhs, rhs, position) do
    unless is_number(lhs),
      do: raise(Error, code: "T2001", token: op, value: lhs, position: position)

    unless is_number(rhs),
      do: raise(Error, code: "T2002", token: op, value: rhs, position: position)

    case op do
      "+" -> lhs + rhs
      "-" -> lhs - rhs
      "*" -> lhs * rhs
      "/" -> lhs / rhs
      "%" -> safe_rem(lhs, rhs)
    end
  end

  # JS `%` keeps the sign of the dividend; rem/2 and :math.fmod/2 both match that.
  defp safe_rem(lhs, rhs) when is_integer(lhs) and is_integer(rhs), do: rem(lhs, rhs)
  defp safe_rem(lhs, rhs), do: :math.fmod(lhs, rhs)

  defp equality_op(_op, @undefined, _rhs), do: false
  defp equality_op(_op, _lhs, @undefined), do: false
  defp equality_op("=", lhs, rhs), do: Value.deep_equal(lhs, rhs)
  defp equality_op("!=", lhs, rhs), do: not Value.deep_equal(lhs, rhs)

  defp comparison_op(_op, @undefined, _rhs, _pos), do: @undefined
  defp comparison_op(_op, _lhs, @undefined, _pos), do: @undefined

  defp comparison_op(op, lhs, rhs, position) do
    validate_comparable(lhs, position)
    validate_comparable(rhs, position)

    unless same_comparison_type?(lhs, rhs) do
      raise Error, code: "T2009", token: op, value: lhs, value2: rhs, position: position
    end

    case op do
      "<" -> lhs < rhs
      "<=" -> lhs <= rhs
      ">" -> lhs > rhs
      ">=" -> lhs >= rhs
    end
  end

  defp validate_comparable(value, _pos) when is_number(value) or is_binary(value), do: :ok

  defp validate_comparable(value, position),
    do: raise(Error, code: "T2010", value: value, position: position)

  defp same_comparison_type?(lhs, rhs),
    do: (is_number(lhs) and is_number(rhs)) or (is_binary(lhs) and is_binary(rhs))

  defp includes_op(@undefined, _rhs), do: false
  defp includes_op(_lhs, @undefined), do: false
  defp includes_op(lhs, rhs) when is_list(rhs), do: Enum.any?(rhs, &Value.deep_equal(&1, lhs))
  defp includes_op(lhs, rhs), do: Value.deep_equal(lhs, rhs)

  defp range_op(@undefined, _rhs), do: @undefined
  defp range_op(_lhs, @undefined), do: @undefined

  defp range_op(lhs, rhs) when is_integer(lhs) and is_integer(rhs) do
    cond do
      lhs > rhs -> @undefined
      rhs - lhs + 1 > 10_000_000 -> raise(Error, code: "D2014", value: rhs - lhs + 1)
      true -> Sequence.from_value(Enum.to_list(lhs..rhs))
    end
  end

  defp range_op(lhs, _rhs) when not is_integer(lhs), do: raise(Error, code: "T2003", value: lhs)
  defp range_op(_lhs, rhs), do: raise(Error, code: "T2004", value: rhs)

  # --- unary ----------------------------------------------------------------

  defp evaluate_unary(%{value: "-"} = expr, input, env) do
    case eval_val(expr.expression, input, env) do
      @undefined -> @undefined
      value when is_number(value) -> -value
      value -> raise(Error, code: "D1002", token: "-", value: value, position: expr.position)
    end
  end

  defp evaluate_unary(%{value: "["} = expr, input, env) do
    Enum.reduce(expr.expressions, [], fn item, acc ->
      case eval_val(item, input, env) do
        @undefined -> acc
        value -> append_array_item(acc, item, value)
      end
    end)
  end

  defp evaluate_unary(%{value: "{"} = expr, input, env), do: construct_object(expr, input, env)

  defp append_array_item(acc, %{type: :unary, value: "["}, value), do: acc ++ [value]
  defp append_array_item(acc, _item, value) when is_list(value), do: acc ++ value
  defp append_array_item(acc, _item, value), do: acc ++ [value]

  defp construct_object(%{lhs: pairs, position: position}, input, env) do
    items = if is_list(input), do: input, else: [input]
    items = if items == [], do: [@undefined], else: items

    Enum.reduce(pairs, %{}, fn [key_expr, value_expr], acc ->
      Enum.reduce(items, acc, fn item, inner ->
        add_object_entry(inner, key_expr, value_expr, item, env, position)
      end)
    end)
  end

  defp add_object_entry(acc, key_expr, value_expr, item, env, position) do
    case eval_val(key_expr, item, env) do
      @undefined ->
        acc

      key when is_binary(key) ->
        case eval_val(value_expr, item, env) do
          @undefined -> acc
          value -> Map.put(acc, key, value)
        end

      key ->
        raise Error, code: "T1003", value: key, position: position
    end
  end

  # --- coercions ------------------------------------------------------------

  defp truthy?(value), do: boolize(value)

  defp boolize(@undefined), do: false
  defp boolize(%Sequence{} = seq), do: Functions.jboolean(Enum.to_list(seq))
  defp boolize(value), do: Functions.jboolean(value)

  defp string_concat(lhs, rhs), do: to_jsonata_string(lhs) <> to_jsonata_string(rhs)

  defp to_jsonata_string(@undefined), do: ""
  defp to_jsonata_string(%Sequence{} = seq), do: to_jsonata_string(Sequence.to_value(seq))
  defp to_jsonata_string(value), do: Functions.jstring(value)
end
