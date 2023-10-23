defmodule MembraneTranscription.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_transcription,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:membrane_core, "~> 0.10.2"},
      {:membrane_file_plugin, "~> 0.12", only: :test},
      {:req, "~> 0.3.3", only: :test},
      {:membrane_mp3_mad_plugin, "~> 0.13.0", only: :test},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.15", only: :test},
      {:membrane_audiometer_plugin, ">= 0.0.0"},
      {:membrane_fake_plugin, "~> 0.8.0", only: :test},
      {:bumblebee, "~> 0.4.2"},
      {:nx, "~> 0.6.2"},
      {:exla, "~> 0.6.1"}
    ]
  end
end
