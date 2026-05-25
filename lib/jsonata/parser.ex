defmodule Jsonata.Parser do
  @moduledoc """
  Top-down operator-precedence (Pratt) parser for JSONata, ported from
  `parser.js` (ADR-1). It drives `Jsonata.Tokenizer` pull-based and produces the
  tagged-map AST described in `Jsonata.AST`, then runs a post-processing pass
  (`process_ast`) that flattens `.`/`[` chains into `:path` nodes with steps and
  predicate stages.

  Parser state is threaded functionally; lexical/syntactic problems raise
  `Jsonata.Error` and are caught at the `parse/1` boundary.

  Scope: the full expression grammar — paths, predicates, operators,
  conditionals, blocks, binds, array/object constructors, ranges, functions,
  lambdas, order-by `^`, grouping `{`, focus `@`, index `#`, the parent operator
  `%` (with its slot/ancestry resolution), and the transform `|…|` operator.
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

    {:ok, process_and_resolve(ast)}
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
  defp nud(%{id: "%"} = t, state), do: {%{type: :parent, position: t.position}, state}

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

  # Object transformer: | pattern | update [, delete] |
  defp nud(%{id: "|"} = t, state) do
    {pattern, state} = expression(state, 0)
    state = advance(state, "|", true)
    {update, state} = expression(state, 0)

    {node, state} =
      if state.tok.id == "," do
        {delete, state} = expression(advance(state, ","), 0)

        {%{
           type: :transform,
           pattern: pattern,
           update: update,
           delete: delete,
           position: t.position
         }, state}
      else
        {%{type: :transform, pattern: pattern, update: update, position: t.position}, state}
      end

    {node, advance(state, "|", true)}
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

  # Order-by:  left^( term, term, ... )   each term optionally prefixed by < or >
  defp led(%{id: "^"} = t, left, state) do
    state = advance(state, "(")
    {terms, state} = sort_terms(state, [])
    state = advance(state, ")")
    {%{type: :binary, value: "^", lhs: left, rhs: terms, position: t.position}, state}
  end

  # Group-by:  left{ k: v, ... }
  defp led(%{id: "{"} = t, left, state) do
    {pairs, state} = object_pairs(state, [])
    state = advance(state, "}", true)
    {%{type: :binary, value: "{", lhs: left, rhs: pairs, position: t.position}, state}
  end

  # Focus (@) and index (#) variable binding; the RHS must be a variable.
  defp led(%{id: id} = t, left, state) when id in ["@", "#"] do
    {rhs, state} = expression(state, @lbp[id])

    if rhs.type != :variable do
      raise Error, code: "S0214", position: rhs.position, token: id
    end

    {%{type: :binary, value: id, lhs: left, rhs: rhs, position: t.position}, state}
  end

  defp led(t, _left, _state),
    do: raise(Error, code: "S0204", position: t.position, token: t.value)

  defp sort_terms(state, acc) do
    {descending, state} =
      case state.tok.id do
        "<" -> {false, advance(state, "<")}
        ">" -> {true, advance(state, ">")}
        _other -> {false, state}
      end

    {expr, state} = expression(state, 0)
    acc = [%{descending: descending, expression: expr} | acc]

    if state.tok.id == "," do
      sort_terms(advance(state, ","), acc)
    else
      {Enum.reverse(acc), state}
    end
  end

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

  # --- parent operator (%) ancestry resolution ------------------------------
  #
  # `%` references the context of an ancestor step. The parser assigns each `%`
  # a "slot" (label + level), then walks the enclosing path back `level` steps to
  # find the step whose input context the `%` refers to; that step is tagged with
  # an `:ancestor_label` and `:tuple`, so the evaluator's tuple stream binds the
  # parent context under that label, which the `:parent` node then looks up.
  # Slots are mutable, so they live in the process dictionary for one parse.

  defp process_and_resolve(ast) do
    Process.put(:jsonata_slots, %{})
    Process.put(:jsonata_slot_count, 0)

    try do
      result = process_ast(ast)

      if result.type == :parent or Map.has_key?(result, :seeking_parent) do
        raise Error, code: "S0217", position: result.position, token: result.type
      end

      bake_slots(result)
    after
      Process.delete(:jsonata_slots)
      Process.delete(:jsonata_slot_count)
    end
  end

  # Bake the resolved slot labels into the AST before the slot store is cleared.
  defp bake_slots(node) when is_map(node) and not is_struct(node) do
    node |> Map.new(fn {k, v} -> {k, bake_slots(v)} end) |> bake_node()
  end

  defp bake_slots(list) when is_list(list), do: Enum.map(list, &bake_slots/1)
  defp bake_slots(other), do: other

  defp bake_node(node) do
    node
    |> rebind(:slot, :label)
    |> rebind(:ancestor, :ancestor_label)
    |> Map.delete(:seeking_parent)
  end

  defp rebind(node, from, to) do
    case Map.fetch(node, from) do
      {:ok, slot} -> node |> Map.put(to, get_slot(slot).label) |> Map.delete(from)
      :error -> node
    end
  end

  defp new_slot do
    n = Process.get(:jsonata_slot_count)
    Process.put(:jsonata_slot_count, n + 1)
    put_slot(n, %{label: "!#{n}", level: 1, index: n})
    n
  end

  defp get_slot(index), do: Map.fetch!(Process.get(:jsonata_slots), index)

  defp put_slot(index, slot) do
    Process.put(:jsonata_slots, Map.put(Process.get(:jsonata_slots), index, slot))
    index
  end

  # Propagate a child's unresolved parent slots up to the enclosing result node.
  defp push_ancestry(result, value) do
    case seeking_slots(value) do
      [] -> result
      slots -> Map.update(result, :seeking_parent, slots, &(&1 ++ slots))
    end
  end

  defp seeking_slots(%{type: :parent, slot: slot} = value),
    do: Map.get(value, :seeking_parent, []) ++ [slot]

  defp seeking_slots(value), do: Map.get(value, :seeking_parent, [])

  # Walk a path's steps back to bind each pending slot to an ancestor step.
  defp resolve_ancestry(%{steps: steps} = path) do
    laststep = List.last(steps)
    slots = Map.get(laststep, :seeking_parent, [])
    slots = if laststep.type == :parent, do: slots ++ [laststep.slot], else: slots

    {steps, bubbled} =
      Enum.reduce(slots, {steps, []}, fn slot, {steps, bubbled} ->
        walk_back(steps, length(steps) - 2, slot, bubbled)
      end)

    path = %{path | steps: steps}
    if bubbled == [], do: path, else: Map.update(path, :seeking_parent, bubbled, &(&1 ++ bubbled))
  end

  defp walk_back(steps, index, slot, bubbled) do
    cond do
      get_slot(slot).level <= 0 ->
        {steps, bubbled}

      index < 0 ->
        {steps, bubbled ++ [slot]}

      true ->
        {pos, next} = skip_focus(steps, index)
        steps = List.replace_at(steps, pos, seek_parent(Enum.at(steps, pos), slot))
        walk_back(steps, next, slot, bubbled)
    end
  end

  # Contiguous focus-bound steps (from @) are skipped during the walk-back.
  defp skip_focus(steps, index) do
    if index > 0 and has_focus?(Enum.at(steps, index)) and has_focus?(Enum.at(steps, index - 1)),
      do: skip_focus(steps, index - 1),
      else: {index, index - 1}
  end

  defp has_focus?(step), do: Map.get(step, :focus) != nil

  defp seek_parent(%{type: type} = node, slot) when type in [:name, :wildcard] do
    %{level: level} = decrement = %{get_slot(slot) | level: get_slot(slot).level - 1}
    put_slot(slot, decrement)
    if level == 0, do: tag_ancestor(node, slot), else: node
  end

  defp seek_parent(%{type: :parent} = node, slot) do
    put_slot(slot, %{get_slot(slot) | level: get_slot(slot).level + 1})
    node
  end

  defp seek_parent(%{type: :block, expressions: []} = node, _slot), do: node

  defp seek_parent(%{type: :block, expressions: exprs} = node, slot) do
    # a bare name/wildcard must become a single-step path so the tuple machinery
    # (which lives in path evaluation) can bind the ancestor when this runs
    last = exprs |> List.last() |> ensure_path() |> seek_parent(slot)
    %{node | expressions: List.replace_at(exprs, -1, last)} |> Map.put(:tuple, true)
  end

  defp seek_parent(%{type: :path, steps: steps} = node, slot) do
    steps = seek_path_steps(steps, length(steps) - 1, slot, true)
    %{node | steps: steps} |> Map.put(:tuple, true)
  end

  defp seek_parent(node, _slot),
    do: raise(Error, code: "S0217", position: node.position, token: node.type)

  defp ensure_path(%{type: type} = node) when type in [:name, :wildcard],
    do: %{type: :path, steps: [node]}

  defp ensure_path(node), do: node

  # the last step is always sought; earlier steps only while the slot has levels
  defp seek_path_steps(steps, index, _slot, _first?) when index < 0, do: steps

  defp seek_path_steps(steps, index, slot, first?) do
    if first? or get_slot(slot).level > 0 do
      steps = List.replace_at(steps, index, seek_parent(Enum.at(steps, index), slot))
      seek_path_steps(steps, index - 1, slot, false)
    else
      steps
    end
  end

  # A predicate consumes one ancestry level (its implicit focus); level-1 slots
  # resolve against the predicated step, the rest bubble up one level lighter.
  defp resolve_predicate_slots(step, predicate) do
    Enum.reduce(Map.get(predicate, :seeking_parent, []), step, fn slot, step ->
      if get_slot(slot).level == 1 do
        seek_parent(step, slot)
      else
        put_slot(slot, %{get_slot(slot) | level: get_slot(slot).level - 1})
        step
      end
    end)
  end

  defp tag_ancestor(node, slot) do
    case Map.get(node, :ancestor) do
      nil -> :ok
      existing -> put_slot(slot, %{get_slot(slot) | label: get_slot(existing).label})
    end

    node |> Map.put(:ancestor, slot) |> Map.put(:tuple, true)
  end

  # --- process_ast: flatten paths and attach predicate stages ---------------

  defp process_ast(%{type: :binary, value: "."} = expr) do
    lstep = process_ast(expr.lhs)
    result = if lstep.type == :path, do: lstep, else: %{type: :path, steps: [lstep]}

    result =
      if lstep.type == :parent, do: Map.put(result, :seeking_parent, [lstep.slot]), else: result

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
    result |> flag_cons_arrays() |> resolve_ancestry()
  end

  defp process_ast(%{type: :binary, value: "["} = expr) do
    result = process_ast(expr.lhs)
    {step, key} = predicate_target(result)
    predicate = process_ast(expr.rhs)
    step = resolve_predicate_slots(step, predicate)
    # a predicate on a step that carries ancestry runs as a tuple stage, so it
    # filters the tuple stream (with `%` bound) rather than the plain value
    key = if Map.get(step, :tuple), do: :stages, else: key
    filter = %{type: :filter, expr: predicate, position: expr.position}
    stages = Map.get(step, key, []) ++ [filter]
    step = step |> Map.put(key, stages) |> transfer_keep_array(expr) |> push_ancestry(predicate)
    replace_last_step(result, step, key)
  end

  defp process_ast(%{type: :binary, value: ":="} = expr) do
    rhs = process_ast(expr.rhs)

    push_ancestry(
      %{type: :bind, lhs: process_ast(expr.lhs), rhs: rhs, position: expr.position},
      rhs
    )
  end

  # Order-by: append a sort step to the path.
  defp process_ast(%{type: :binary, value: "^"} = expr) do
    result = as_path(process_ast(expr.lhs))

    {terms, sort_step} =
      Enum.map_reduce(expr.rhs, %{type: :sort, position: expr.position}, fn term, sort_step ->
        expression = process_ast(term.expression)

        {%{descending: term.descending, expression: expression},
         push_ancestry(sort_step, expression)}
      end)

    sort_step = Map.put(sort_step, :terms, terms)
    resolve_ancestry(%{result | steps: result.steps ++ [sort_step]})
  end

  # Group-by: attach a grouping object to the step/path.
  defp process_ast(%{type: :binary, value: "{"} = expr) do
    result = process_ast(expr.lhs)

    if Map.has_key?(result, :group) do
      raise Error, code: "S0210", position: expr.position
    end

    pairs = Enum.map(expr.rhs, fn [k, v] -> [process_ast(k), process_ast(v)] end)
    Map.put(result, :group, %{lhs: pairs, position: expr.position})
  end

  # Focus (@) / index (#) binding: flag the last step as a tuple step.
  defp process_ast(%{type: :binary, value: bind_op} = expr) when bind_op in ["@", "#"] do
    result = process_ast(expr.lhs)
    {step, _key} = predicate_target(result)

    if bind_op == "@" and (Map.has_key?(step, :stages) or Map.has_key?(step, :predicate)) do
      raise Error, code: "S0215", position: expr.position
    end

    key = if bind_op == "@", do: :focus, else: :index
    step = step |> Map.put(key, expr.rhs.value) |> Map.put(:tuple, true)
    replace_last_step(result, step, :stages)
  end

  defp process_ast(%{type: :binary} = expr) do
    lhs = process_ast(expr.lhs)
    rhs = process_ast(expr.rhs)
    %{expr | lhs: lhs, rhs: rhs} |> push_ancestry(lhs) |> push_ancestry(rhs)
  end

  defp process_ast(%{type: :unary, value: "["} = expr) do
    items = Enum.map(expr.expressions, &process_ast/1)
    Enum.reduce(items, %{expr | expressions: items}, &push_ancestry(&2, &1))
  end

  defp process_ast(%{type: :unary, value: "{"} = expr) do
    pairs = Enum.map(expr.lhs, fn [k, v] -> [process_ast(k), process_ast(v)] end)

    Enum.reduce(pairs, %{expr | lhs: pairs}, fn [k, v], acc ->
      acc |> push_ancestry(k) |> push_ancestry(v)
    end)
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
    parts = Enum.map(expr.expressions, &process_ast/1)
    Enum.reduce(parts, %{expr | expressions: parts}, &push_ancestry(&2, &1))
  end

  defp process_ast(%{type: :condition} = expr) do
    condition = process_ast(expr.condition)
    then_branch = process_ast(expr.then)

    expr
    |> Map.put(:condition, condition)
    |> Map.put(:then, then_branch)
    |> maybe_process(:else)
    |> push_ancestry(condition)
    |> push_ancestry(then_branch)
    |> push_ancestry_else()
  end

  defp process_ast(%{type: :coalesce} = expr) do
    lhs = process_ast(expr.lhs)
    rhs = process_ast(expr.rhs)
    %{expr | lhs: lhs, rhs: rhs} |> push_ancestry(lhs) |> push_ancestry(rhs)
  end

  defp process_ast(%{type: :parent} = expr),
    do: Map.put(expr, :slot, new_slot())

  defp process_ast(%{type: type} = expr) when type in [:function, :partial] do
    args = Enum.map(expr.arguments, &process_ast/1)
    result = %{expr | procedure: process_ast(expr.procedure), arguments: args}
    Enum.reduce(args, result, &push_ancestry(&2, &1))
  end

  defp process_ast(%{type: :transform} = expr) do
    expr = %{expr | pattern: process_ast(expr.pattern), update: process_ast(expr.update)}
    maybe_process(expr, :delete)
  end

  defp process_ast(%{type: :lambda} = expr), do: %{expr | body: process_ast(expr.body)}

  defp process_ast(expr), do: expr

  defp maybe_process(expr, key) do
    case Map.fetch(expr, key) do
      {:ok, value} -> Map.put(expr, key, process_ast(value))
      :error -> expr
    end
  end

  defp push_ancestry_else(%{else: else_branch} = expr), do: push_ancestry(expr, else_branch)
  defp push_ancestry_else(expr), do: expr

  defp predicate_target(%{type: :path, steps: steps}), do: {List.last(steps), :stages}
  defp predicate_target(step), do: {step, :predicate}

  defp as_path(%{type: :path} = path), do: path
  defp as_path(step), do: %{type: :path, steps: [step]}

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
