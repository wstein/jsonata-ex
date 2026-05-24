defmodule Jsonata.Error do
  @moduledoc """
  A JSONata error, carrying the upstream error `code` (e.g. `"S0101"`), the
  source `position` where it occurred, and a rendered `message`.

  Error codes and their message templates mirror `jsonata-js` so the conformance
  suite can match on `code`. Only the codes needed by the implemented phases are
  registered; more are added as later phases land.
  """

  @messages %{
    # Lexical (tokenizer) errors
    "S0101" => "String literal must be terminated by a matching quote",
    "S0102" => "Number out of range: {{token}}",
    "S0103" => "Unsupported escape sequence: \\{{token}}",
    "S0104" => "The escape sequence \\u must be followed by 4 hex digits",
    "S0105" => "Quoted property name must be terminated with a backquote (`)",
    "S0106" => "Comment has no closing tag",
    "S0301" => "Empty regular expressions are not allowed",
    "S0302" => "No terminating / in regular expression",
    # Syntax (parser) errors
    "S0201" => "Syntax error: {{token}}",
    "S0202" => "Expected {{value}}, got {{token}}",
    "S0203" => "Expected {{value}} before end of expression",
    "S0204" => "Unknown operator: {{token}}",
    "S0205" => "Unexpected token: {{token}}",
    "S0208" =>
      "Parameter {{value}} of function definition must be a variable name (start with $)",
    "S0209" => "A predicate cannot follow a grouping expression in a step",
    "S0210" => "Each step can only have one grouping expression",
    "S0211" => "The symbol {{token}} cannot be used as a unary operator",
    "S0212" => "The left side of := must be a variable name (start with $)",
    "S0213" => "The literal value {{value}} cannot be used as a step within a path expression",
    # Dynamic / type (evaluation) errors
    "D1002" => "Cannot negate a non-numeric value: {{value}}",
    "T1003" => "Key in object structure must evaluate to a string; got: {{value}}",
    "T2001" => "The left side of the {{token}} operator must evaluate to a number",
    "T2002" => "The right side of the {{token}} operator must evaluate to a number",
    "T2003" => "The left side of the range operator (..) must evaluate to an integer",
    "T2004" => "The right side of the range operator (..) must evaluate to an integer",
    "T2009" =>
      "The values {{value}} and {{value2}} either side of operator {{token}} must be of the same data type",
    "T2010" =>
      "The expressions either side of operator {{token}} must evaluate to numeric or string values",
    "D2014" =>
      "The size of the sequence allocated by the range operator (..) must not exceed 1e7.  Attempted to allocate {{value}}.",
    "D2015" => "The maximum sequence length of {{value}} was exceeded."
  }

  @type t :: %__MODULE__{
          code: String.t(),
          position: non_neg_integer() | nil,
          token: String.t() | nil,
          value: term(),
          message: String.t()
        }

  defexception [:code, :position, :token, :value, message: "JSONata error"]

  @impl true
  @spec exception(keyword()) :: t()
  def exception(opts) when is_list(opts) do
    code = Keyword.fetch!(opts, :code)

    %__MODULE__{
      code: code,
      position: Keyword.get(opts, :position),
      token: Keyword.get(opts, :token),
      value: Keyword.get(opts, :value),
      message: render(code, Keyword.drop(opts, [:code, :position]))
    }
  end

  @doc "Builds an error struct for `code` with optional `:position`, `:token`, and `:value`."
  @spec new(String.t(), keyword()) :: t()
  def new(code, opts \\ []), do: exception([{:code, code} | opts])

  @doc "Returns the message template for a known `code`, or `nil`."
  @spec template(String.t()) :: String.t() | nil
  def template(code), do: Map.get(@messages, code)

  defp render(code, bindings) do
    template = Map.get(@messages, code, code)

    Enum.reduce(bindings, template, fn
      {_key, nil}, acc -> acc
      {key, val}, acc -> String.replace(acc, "{{#{key}}}", to_string(val))
    end)
  end
end
