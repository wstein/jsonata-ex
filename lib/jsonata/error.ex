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
    # Dynamic (evaluation) errors
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
    token = Keyword.get(opts, :token)
    value = Keyword.get(opts, :value)

    %__MODULE__{
      code: code,
      position: Keyword.get(opts, :position),
      token: token,
      value: value,
      message: render(code, token: token, value: value)
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
