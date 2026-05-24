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
    "S0302" => "No terminating / in regular expression"
  }

  @type t :: %__MODULE__{
          code: String.t(),
          position: non_neg_integer() | nil,
          token: String.t() | nil,
          message: String.t()
        }

  defexception [:code, :position, :token, message: "JSONata error"]

  @impl true
  @spec exception(keyword()) :: t()
  def exception(opts) when is_list(opts) do
    code = Keyword.fetch!(opts, :code)
    token = opts |> Keyword.get(:token) |> normalize_token()

    %__MODULE__{
      code: code,
      position: Keyword.get(opts, :position),
      token: token,
      message: render(code, token)
    }
  end

  @doc "Builds an error struct for `code` with optional `:position` and `:token`."
  @spec new(String.t(), keyword()) :: t()
  def new(code, opts \\ []), do: exception([{:code, code} | opts])

  @doc "Returns the message template for a known `code`, or `nil`."
  @spec template(String.t()) :: String.t() | nil
  def template(code), do: Map.get(@messages, code)

  defp normalize_token(nil), do: nil
  defp normalize_token(token) when is_binary(token), do: token
  defp normalize_token(token), do: to_string(token)

  defp render(code, token) do
    template = Map.get(@messages, code, code)

    if token do
      String.replace(template, "{{token}}", token)
    else
      template
    end
  end
end
