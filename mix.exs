defmodule Jsonata.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/wstein/jsonata-ex"

  def project do
    [
      app: :jsonata,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [threshold: 90],
      dialyzer: [
        plt_add_apps: [:ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        flags: [:error_handling, :extra_return]
      ],
      name: "JSONata",
      source_url: @source_url,
      description: "A native Elixir port of the JSONata query and transformation language.",
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # the conformance-suite loader is a test helper, kept out of the published lib
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end

  defp package do
    [
      maintainers: ["Werner Stein"],
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "JSONata" => "https://jsonata.org/"
      }
    ]
  end
end
