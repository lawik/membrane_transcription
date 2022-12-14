defmodule MembraneTranscription.Whisper do
  def transcribe!(raw_audio, extension, model) do
    path = Path.join("/tmp", "#{System.unique_integer()}.#{extension}")
    File.write!(path, raw_audio)
    transcribe_path!(path, model)
  end

  def transcribe_path!(path, model) do
    File.cd!(whisper_path())

    {output, 0} =
      System.shell(
        "#{whisper_path()}/env/bin/python -mwhisper --model #{model} --verbose True --task transcribe #{path}"
      )

    process_output(output)
  end

  defp process_output(output) do
    output
    |> String.split("\n")
    |> Enum.reduce(%{language: nil, items: []}, fn line, acc ->
      case line do
        "Detected language: " <> language ->
          %{acc | language: language}

        "[" <> _ ->
          caps =
            Regex.named_captures(
              ~r/\[(?<start>..:..\....) --> (?<stop>..:..\....)\]  (?<text>.+)/,
              line
            )

          %{
            acc
            | items: [
                acc.items,
                %{
                  start: caps["start"],
                  stop: caps["stop"],
                  text: caps["text"]
                }
              ]
          }

        _ ->
          acc
      end
    end)
    |> then(fn result ->
      %{result | items: List.flatten(result.items)}
    end)
  end

  defp whisper_path do
    System.get_env("WHISPER_PATH", Path.join(Path.expand("~"), "projects/whisper"))
  end
end
