defmodule MembraneTranscription.MixProject do
  use Mix.Project

  def project do
    [
      # TODO: Set up all the necessary bits for a hex package,
      # TODO: see pappersverk/inky for an example or some other repo you like
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
      # TODO: is it used? if so, should be only: :test I bet
      {:membrane_audiometer_plugin, ">= 0.0.0"},
      {:membrane_fake_plugin, "~> 0.8.0", only: :test},
      # TODO: Update to recent versioned dependencies instead of github versions
      # TODO: This was running from master because Whisper had not landed in a release yet
      {:bumblebee, github: "elixir-nx/bumblebee"},
      {:nx, github: "elixir-nx/nx", sparse: "nx", override: true},
      {:exla, github: "elixir-nx/nx", sparse: "exla", override: true}
    ]
  end
end
