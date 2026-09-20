defmodule Terra.MixProject do
  use Mix.Project

  def project do
    [
      app: :terra,
      version: "1.0.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Zero-dependency TUI library for Elixir",
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md", "guides/getting_started.md", "guides/tutorial.md"]
      ],
      source_url: "https://github.com/uminocelo/terra"
    ]
  end

  def application do
    []
  end

  defp deps do
    [{:ex_doc, "~> 0.34", only: :dev, runtime: false}]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/uminocelo/terra"},
      files: ["lib", "guides", "mix.exs", ".formatter.exs", "README.md", "LICENSE"]
    ]
  end
end
