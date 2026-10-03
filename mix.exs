defmodule Archive.MixProject do
  use Mix.Project

  def project do
    [
      app: :archive,
      name: "Archive",
      version: "0.5.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      description: "Universal archive library",
      deps: deps(),
      docs: docs(),
      package: package(),
      test_coverage: [
        summary: [threshold: 91],
        ignore_modules: [Archive.Nif, Archive.Nif.Manifest, Archive.Schemas]
      ],
      aliases: [check: ["format --check-formatted", "test --cover"]]
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
      {:rustler, "~> 0.38.0", runtime: false, optional: true},
      {:rustler_precompiled, "~> 0.10.0"},
      {:ex_doc, "~> 0.39.1", runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Andres Alejos"],
      licenses: ["MIT"],
      files: [
        "lib/**/*.ex",
        "assets/logo/archive.png",
        "native/archive/Cargo.*",
        "native/archive/build.rs",
        "native/archive/src",
        "native/archive/.cargo/config.toml",
        "native/dependencies.json",
        "native/targets.json",
        "rust-toolchain.toml",
        "checksum-Elixir.Archive.Nif.exs",
        "priv/api_inventory.json",
        "priv/bindings.exs",
        "priv/operations.json",
        "priv/tables.json",
        "vendor",
        "scripts/*.py",
        "guides",
        "mix.exs",
        "mix.lock",
        "README.md",
        "CONTRIBUTING.md",
        "CHANGELOG.md",
        "LICENSE",
        ".formatter.exs"
      ],
      links: %{"GitHub" => "https://github.com/acalejos/archive"}
    ]
  end

  defp docs do
    [
      main: "Archive",
      logo: "assets/logo/archive.png",
      assets: %{"assets/logo" => "assets/logo"},
      extras: [
        "README.md",
        "guides/high_level.md",
        "guides/streaming.md",
        "guides/bindings.md",
        "guides/precompiled.md",
        "CONTRIBUTING.md"
      ],
      groups_for_modules: [
        "Streaming API": [Archive.Stream, Archive.Entry],
        "Native API": [Archive.Nif]
      ]
    ]
  end
end
