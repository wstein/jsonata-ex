defmodule Jsonata.Parser do
  @moduledoc """
  Top-down operator-precedence (Pratt) parser for JSONata, ported from
  `parser.js` (ADR-1). It drives `Jsonata.Tokenizer` pull-based and produces the
  tagged-map AST described in `Jsonata.AST`, then runs a post-processing pass
  (`process_ast`) that flattens `.`/`[` chains into `:path` nodes with steps and
  predicate stages.

  Parser state is threaded functionally; lexical/syntactic problems raise
  `Jsonata.Error` and are caught at the `parse/1` boundary.

  Scope: this build parses the expression grammar exercised by the Phase 1/2
  conformance groups (paths, predicates, operators, conditionals, blocks,
  binds, array/object constructors, ranges, functions, lambdas). Constructs
  belonging to later phases — order-by `^`, grouping `{` (infix), focus `@`,
  index `#`, parent `%` (prefix), and transform `|` — are not yet parsed and
  raise `S0204`.
  """

  alias Jsonata.{Error, Token, Tokenizer}

  # Left binding powers — only symbols that have an infix `led`. Separators and
  # terminals (`; : , ) ] } .. | ** *`-as-wildcard) carry lbp 0, mirroring how
  # parser.js registers them via `symbol/terminal` rather than `infix`.
  @lbp %{
    "." => 75,
    "[" => 80,
    "{" => 70,
    "(" => 80,
    "@" => 80,
    "#" => 80,
    "?" => 20,
    "+" => 50,
    "-" => 50,
    "*" => 60,
    "/" => 60,
    "%" => 60,
    "=" => 40,
    "<" => 40,
    ">" => 40,
    "^" => 40,
    ":=" => 10,
    "!=" => 40,
    "<=" => 40,
    ">=" => 40,
    "~>" => 40,
    "?:" => 40,
    "??" => 40,
    "and" => 30,
    "or" => 25,
    "in" => 40,
    "&" => 50
  }

  @infix_ops ~w(. + - * / % = < > & ~> != <= >= and or in)

  @doc """
  Parses JSONata `source` into an AST.

  Returns `{:ok, ast}` or `{:error, %Jsonata.Error{}}`.
  """
  @spec parse(binary()) :: {:ok, Jsonata.AST.t()} | {:error, Error.t()}
  def parse(source) when is_binary(source) do
    state = advance(%{src: source, pos: 0, tok: nil})
    {ast, state} = expression(state, 0)

    if state.tok.id != :end do
      raise Error, code: "S0201", position: state.tok.position, token: state.tok.value
    end

    {:ok, process_ast(ast)}
  rescue
    error in Error -> {:error, error}
  end

  # --- Pratt core -----------------------------------------------------------

  defp expression(state, rbp) do
    token = state.tok
    state = advance(state, nil, true)
    {left, state} = nud(token, state)
    led_loop(left, state, rbp)
  end

  defp led_loop(left, state, rbp) do
    if rbp < lbp(state.tok) do
      token = state.tok
      state = advance(state)
      {left, state} = led(token, left, state)
      led_loop(left, state, rbp)
    else
      {left, state}
    end
  end

  defp lbp(%{id: id}) when is_binary(id), do: Map.get(@lbp, id, 0)
  defp lbp(_token), do: 0

  defp advance(state, expected \\ nil, infix \\ false) do
    check_expected(state.tok, expected)

    case Tokenizer.next(state.src, state.pos, infix) do
      {:ok, :eof, pos} -> %{state | tok: end_node(state.src), pos: pos}
      {:ok, token, pos} -> %{state | tok: normalize(token), pos: pos}
      {:error, error} -> raise error
    end
  end

  defp check_expected(_tok, nil), do: :ok
  defp check_expected(%{id: id}, id), do: :ok

  defp check_expected(%{id: :end} = tok, expected),
    do: raise(Error, code: "S0203", position: tok.position, value: expected)

  defp check_expected(tok, expected),
    do: raise(Error, code: "S0202", position: tok.position, token: tok.value, value: expected)

  defp end_node(src), do: %{id: :end, type: :end, value: nil, position: byte_size(src)}

  defp normalize(%Token{type: type, value: value, position: position}) do
    id =
      case type do
        :operator -> value
        :name -> :name
        :variable -> :name
        :regex -> :regex
        _literal -> :literal
      end

    %{id: id, type: type, value: value, position: position}
  end

  # --- nud (prefix / terminal) ----------------------------------------------

  defp nud(%{id: :literal} = t, state),
    do: {%{type: t.type, value: t.value, position: t.position}, state}

  defp nud(%{id: :regex} = t, state),
    do: {%{type: :regex, value: t.value, position: t.position}, state}

  defp nud(%{id: :name, type: type} = t, state),
    do: {%{type: type, value: t.value, position: t.position}, state}

  # Keyword operators used as field names (terminals).
  defp nud(%{id: id} = t, state) when id in ["and", "or", "in"],
    do: {%{type: :name, value: t.value, position: t.position}, state}

  defp nud(%{id: "-"} = t, state) do
    {expr, state} = expression(state, 70)
    {%{type: :unary, value: "-", expression: expr, position: t.position}, state}
  end

  defp nud(%{id: "*"} = t, state), do: {%{type: :wildcard, position: t.position}, state}
  defp nud(%{id: "**"} = t, state), do: {%{type: :descendant, position: t.position}, state}

  # Block expression: ( e1 ; e2 ; ... )
  defp nud(%{id: "("} = t, state) do
    {exprs, state} = block_expressions(state, [])
    state = advance(state, ")", true)
    {%{type: :block, expressions: exprs, position: t.position}, state}
  end

  # Array constructor: [ a, b, c ]  (items may use the .. range operator)
  defp nud(%{id: "["} = t, state) do
    {items, state} = array_items(state, [])
    state = advance(state, "]", true)
    {%{type: :unary, value: "[", expressions: items, position: t.position}, state}
  end

  # Object constructor: { k: v, ... }
  defp nud(%{id: "{"} = t, state) do
    {pairs, state} = object_pairs(state, [])
    state = advance(state, "}", true)
    {%{type: :unary, value: "{", lhs: pairs, position: t.position}, state}
  end

  defp nud(%{id: id} = t, _state) when is_binary(id),
    do: raise(Error, code: "S0211", position: t.position, token: t.value)

  defp nud(t, _state), do: raise(Error, code: "S0204", position: t.position, token: t.value)

  # --- led (infix) ----------------------------------------------------------

  defp led(%{id: id} = t, left, state) when id in @infix_ops do
    {rhs, state} = expression(state, Map.fetch!(@lbp, id))
    {%{type: :binary, value: id, lhs: left, rhs: rhs, position: t.position}, state}
  end

  # Variable binding a := b (right associative)
  defp led(%{id: ":="} = t, left, state) do
    if left.type != :variable do
      raise Error, code: "S0212", position: left.position, token: left.value
    end

    {rhs, state} = expression(state, @lbp[":="] - 1)
    {%{type: :binary, value: ":=", lhs: left, rhs: rhs, position: t.position}, state}
  end

  # Filter / predicate or array index:  left[ expr ]   (or  left[]  to keep arrays)
  defp led(%{id: "["} = t, left, state) do
    if state.tok.id == "]" do
      state = advance(state, "]")
      {Map.put(left, :keep_array, true), state}
    else
      {rhs, state} = expression(state, 0)
      state = advance(state, "]", true)
      {%{type: :binary, value: "[", lhs: left, rhs: rhs, position: t.position}, state}
    end
  end

  # Conditional  cond ? then : else
  defp led(%{id: "?"} = t, left, state) do
    {then_branch, state} = expression(state, 0)

    if state.tok.id == ":" do
      state = advance(state, ":")
      {else_branch, state} = expression(state, 0)

      {%{
         type: :condition,
         condition: left,
         then: then_branch,
         else: else_branch,
         position: t.position
       }, state}
    else
      {%{type: :condition, condition: left, then: then_branch, position: t.position}, state}
    end
  end

  # Default / elvis  left ?: else
  defp led(%{id: "?:"} = t, left, state) do
    {else_branch, state} = expression(state, 0)

    {%{type: :condition, condition: left, then: left, else: else_branch, position: t.position},
     state}
  end

  # Coalescing  left ?? else  (kept as a dedicated node; upstream desugars to exists())
  defp led(%{id: "??"} = t, left, state) do
    {rhs, state} = expression(state, 0)
    {%{type: :coalesce, lhs: left, rhs: rhs, position: t.position}, state}
  end

  # Function invocation / lambda definition:  left( args )
  defp led(%{id: "("} = t, left, state) do
    {args, state} = call_args(state, [])
    state = advance(state, ")", true)
    build_call(left, args, state, t.position)
  end

  defp led(t, _left, _state),
    do: raise(Error, code: "S0204", position: t.position, token: t.value)

  # --- collection parsing helpers -------------------------------------------

  defp block_expressions(%{tok: %{id: ")"}} = state, acc), do: {Enum.reverse(acc), state}

  defp block_expressions(state, acc) do
    {expr, state} = expression(state, 0)
    acc = [expr | acc]

    if state.tok.id == ";" do
      block_expressions(advance(state, ";"), acc)
    else
      {Enum.reverse(acc), state}
    end
  end

  defp array_items(%{tok: %{id: "]"}} = state, acc), do: {Enum.reverse(acc), state}

  defp array_items(state, acc) do
    {item, state} = expression(state, 0)
    {item, state} = maybe_range(item, state)
    acc = [item | acc]

    if state.tok.id == "," do
      array_items(advance(state, ","), acc)
    else
      {Enum.reverse(acc), state}
    end
  end

  # The range operator `..` is only valid inside an array constructor.
  defp maybe_range(item, %{tok: %{id: ".."} = tok} = state) do
    state = advance(state, "..")
    {rhs, state} = expression(state, 0)
    {%{type: :binary, value: "..", lhs: item, rhs: rhs, position: tok.position}, state}
  end

  defp maybe_range(item, state), do: {item, state}

  defp object_pairs(%{tok: %{id: "}"}} = state, acc), do: {Enum.reverse(acc), state}

  defp object_pairs(state, acc) do
    {key, state} = expression(state, 0)
    state = advance(state, ":")
    {value, state} = expression(state, 0)
    acc = [[key, value] | acc]

    if state.tok.id == "," do
      object_pairs(advance(state, ","), acc)
    else
      {Enum.reverse(acc), state}
    end
  end

  defp call_args(%{tok: %{id: ")"}} = state, acc), do: {Enum.reverse(acc), state}

  defp call_args(state, acc) do
    {arg, state} = call_arg(state)
    acc = [arg | acc]

    if state.tok.id == "," do
      call_args(advance(state, ","), acc)
    else
      {Enum.reverse(acc), state}
    end
  end

  # A bare `?` is a partial-application placeholder.
  defp call_arg(%{tok: %{id: "?"} = tok} = state),
    do: {%{type: :placeholder, position: tok.position}, advance(state, "?")}

  defp call_arg(state), do: expression(state, 0)

  defp build_call(left, args, state, position) do
    cond do
      left.type == :name and left.value in ["function", "λ"] ->
        build_lambda(args, state, position)

      Enum.any?(args, &match?(%{type: :placeholder}, &1)) ->
        {%{type: :partial, procedure: left, arguments: args, position: position}, state}

      true ->
        {%{type: :function, procedure: left, arguments: args, position: position}, state}
    end
  end

  defp build_lambda(args, state, position) do
    Enum.each(args, fn arg ->
      if arg.type != :variable do
        raise Error, code: "S0208", position: arg.position, token: arg.value
      end
    end)

    {state, signature} = maybe_signature(state)
    state = advance(state, "{")
    {body, state} = expression(state, 0)
    state = advance(state, "}")

    {%{type: :lambda, arguments: args, signature: signature, body: body, position: position},
     state}
  end

  # Lambda signature `<...>` is captured raw; parsing it is deferred to Phase 3.
  defp maybe_signature(%{tok: %{id: "<"}} = state), do: consume_signature(advance(state), "<", 1)
  defp maybe_signature(state), do: {state, nil}

  defp consume_signature(%{tok: %{id: :end}} = state, acc, _depth), do: {state, acc}
  defp consume_signature(%{tok: %{id: "{"}} = state, acc, _depth), do: {state, acc}

  defp consume_signature(%{tok: tok} = state, acc, depth) do
    depth = depth + signature_depth(tok.id)
    acc = acc <> to_string(tok.value)

    if depth == 0 do
      {advance(state), acc}
    else
      consume_signature(advance(state), acc, depth)
    end
  end

  defp signature_depth(">"), do: -1
  defp signature_depth("<"), do: 1
  defp signature_depth(_other), do: 0

  # --- process_ast: flatten paths and attach predicate stages ---------------

  defp process_ast(%{type: :binary, value: "."} = expr) do
    lstep = process_ast(expr.lhs)
    result = if lstep.type == :path, do: lstep, else: %{type: :path, steps: [lstep]}
    rest = process_ast(expr.rhs)

    steps =
      case rest do
        %{type: :path, steps: rest_steps} ->
          result.steps ++ rest_steps

        %{predicate: predicate} = step ->
          result.steps ++ [step |> Map.put(:stages, predicate) |> Map.delete(:predicate)]

        step ->
          result.steps ++ [step]
      end

    steps = Enum.map(steps, &literal_step_to_name/1)
    result = %{result | steps: steps}
    result = flag_keep_singleton(result)
    flag_cons_arrays(result)
  end

  defp process_ast(%{type: :binary, value: "["} = expr) do
    result = process_ast(expr.lhs)
    {step, key} = predicate_target(result)
    predicate = process_ast(expr.rhs)
    filter = %{type: :filter, expr: predicate, position: expr.position}
    stages = Map.get(step, key, []) ++ [filter]
    step = step |> Map.put(key, stages) |> transfer_keep_array(expr)
    replace_last_step(result, step, key)
  end

  defp process_ast(%{type: :binary, value: ":="} = expr) do
    %{
      type: :bind,
      lhs: process_ast(expr.lhs),
      rhs: process_ast(expr.rhs),
      position: expr.position
    }
  end

  defp process_ast(%{type: :binary} = expr) do
    %{expr | lhs: process_ast(expr.lhs), rhs: process_ast(expr.rhs)}
  end

  defp process_ast(%{type: :unary, value: "["} = expr) do
    %{expr | expressions: Enum.map(expr.expressions, &process_ast/1)}
  end

  defp process_ast(%{type: :unary, value: "{"} = expr) do
    %{expr | lhs: Enum.map(expr.lhs, fn [k, v] -> [process_ast(k), process_ast(v)] end)}
  end

  defp process_ast(%{type: :unary, value: "-"} = expr) do
    inner = process_ast(expr.expression)

    if inner.type == :number do
      %{inner | value: -inner.value}
    else
      %{expr | expression: inner}
    end
  end

  defp process_ast(%{type: :block} = expr) do
    %{expr | expressions: Enum.map(expr.expressions, &process_ast/1)}
  end

  defp process_ast(%{type: :condition} = expr) do
    expr
    |> Map.put(:condition, process_ast(expr.condition))
    |> Map.put(:then, process_ast(expr.then))
    |> maybe_process(:else)
  end

  defp process_ast(%{type: :coalesce} = expr) do
    %{expr | lhs: process_ast(expr.lhs), rhs: process_ast(expr.rhs)}
  end

  defp process_ast(%{type: type} = expr) when type in [:function, :partial] do
    %{
      expr
      | procedure: process_ast(expr.procedure),
        arguments: Enum.map(expr.arguments, &process_ast/1)
    }
  end

  defp process_ast(%{type: :lambda} = expr), do: %{expr | body: process_ast(expr.body)}

  defp process_ast(expr), do: expr

  defp maybe_process(expr, key) do
    case Map.fetch(expr, key) do
      {:ok, value} -> Map.put(expr, key, process_ast(value))
      :error -> expr
    end
  end

  defp predicate_target(%{type: :path, steps: steps}), do: {List.last(steps), :stages}
  defp predicate_target(step), do: {step, :predicate}

  defp transfer_keep_array(step, %{keep_array: true}), do: Map.put(step, :keep_array, true)
  defp transfer_keep_array(step, _expr), do: step

  defp replace_last_step(%{type: :path, steps: steps} = path, step, _key) do
    %{path | steps: List.replace_at(steps, -1, step)}
  end

  defp replace_last_step(_result, step, _key), do: step

  defp literal_step_to_name(%{type: :string} = step), do: %{step | type: :name}

  defp literal_step_to_name(%{type: type} = step) when type in [:number, :value] do
    raise Error, code: "S0213", position: step.position, value: step.value
  end

  defp literal_step_to_name(step), do: step

  defp flag_keep_singleton(%{steps: steps} = result) do
    if Enum.any?(steps, &Map.get(&1, :keep_array, false)) do
      Map.put(result, :keep_singleton_array, true)
    else
      result
    end
  end

  defp flag_cons_arrays(%{steps: steps} = result) do
    steps =
      steps
      |> flag_cons_at(0)
      |> flag_cons_at(length(steps) - 1)

    %{result | steps: steps}
  end

  defp flag_cons_at(steps, index) do
    case Enum.at(steps, index) do
      %{type: :unary, value: "["} = step ->
        List.replace_at(steps, index, Map.put(step, :cons_array, true))

      _other ->
        steps
    end
  end
end
