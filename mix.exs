defmodule Archive.MixProject do
  use Mix.Project

  def project do
    [
      app: :archive,
      name: "Archive",
      version: "0.3.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      description: "Universal archive library",
      deps: deps(),
      compilers: [:elixir_make] ++ Mix.compilers(),
      docs: docs(),
      package: package(),
      preferred_cli_env: [
        docs: :docs,
        "hex.publish": :docs
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:nimble_options, "~> 1.1"},
      {:zigler, "~>0.13", runtime: false},
      {:elixir_make, "~> 0.8", runtime: false},
      {:ex_doc, "~> 0.34", only: :docs}
    ]
  end

  defp package do
    [
      maintainers: ["Andres Alejos"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/acalejos/archive"}
    ]
  end

  defp docs do
    [
      main: "Archive"
    ]
  end
end
