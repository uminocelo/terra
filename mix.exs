defmodule Terra.MixProject do
  use Mix.Project

  def project do
    [
      app: :terra,
      version: "1.1.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Terra",
      source_url: "https://github.com/uminocelo/terra",
      homepage_url: "https://uminocelo.github.io/terra/",
      docs: docs()
    ]
  end

  def application, do: []

  defp deps do
    [{:ex_doc, "~> 0.34", only: :dev, runtime: false}]
  end

  defp description do
    """
    Zero-dependency TUI for Elixir. Elm-style init/update/view, \
    cell-grid diffs, and a restore contract that always gives the terminal back. OTP 28+.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/uminocelo/terra",
        "Docs" => "https://hexdocs.pm/terra",
        "Guides" => "https://uminocelo.github.io/terra/"
      },
      files: [
        "lib",
        "guides",
        "mix.exs",
        ".formatter.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE"
      ]
    ]
  end

  defp docs do
    [
      main: "getting_started",
      extras: [
        "guides/getting_started.md": [title: "Getting Started"],
        "guides/tutorial.md": [title: "Tutorial"],
        "guides/effects.md": [title: "Effects as data"],
        "README.md": [title: "README"],
        "CHANGELOG.md": [title: "Changelog"]
      ],
      groups_for_extras: [
        Guides: [
          "guides/getting_started.md",
          "guides/tutorial.md",
          "guides/effects.md"
        ]
      ],
      groups_for_modules: [
        Runtime: [Terra, Terra.App, Terra.Runtime],
        Terminal: [Terra.Terminal, Terra.Input],
        View: [Terra.View, Terra.Renderer, Terra.Widget, Terra.Focus, Terra.Theme],
        Test: [Terra.Test]
      ],
      source_url_pattern: "https://github.com/uminocelo/terra/blob/main/%{path}#L%{line}",
      formatters: ["html"]
    ]
  end
end
