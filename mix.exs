defmodule Glider.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/example/glider_ex"

  def project do
    [
      app: :glider_ex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "Elixir bindings for glider, an embeddable property-graph database with built-in graph algorithms.",
      package: package(),
      docs: docs(),
      name: "Glider",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:rustler, "~> 0.37"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      compile: ["compile", &prune_stray_artifacts/1],
      test: ["compile", &prune_stray_artifacts/1, "test"]
    ]
  end

  # Rustler copies every `:lib` artifact cargo reports into priv/native. glider
  # is a path dependency whose crate-type includes rlib/cdylib/staticlib for its
  # own mobile and FFI story, so its rlib lands here too — renamed to
  # `glider.so`, loaded by nothing, and about 6 MB of dead weight in any
  # release. Only the NIF itself belongs here.
  defp prune_stray_artifacts(_args) do
    dir = "priv/native"

    if File.dir?(dir) do
      for file <- File.ls!(dir), not String.starts_with?(file, "glider_nif") do
        File.rm(Path.join(dir, file))
      end
    end

    :ok
  end

  defp package do
    [
      licenses: ["MIT", "Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib native/glider_nif/src native/glider_nif/Cargo.toml
                native/glider_nif/Cargo.lock mix.exs README.md)
    ]
  end

  defp docs do
    [main: "Glider", extras: ["README.md"]]
  end
end
