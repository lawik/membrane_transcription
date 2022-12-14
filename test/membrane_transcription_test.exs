defmodule MembraneTranscriptionTest do
  use ExUnit.Case

  @episode_url "https://aphid.fireside.fm/d/1437767933/a11633b3-cf22-42b6-875e-ecdfee41c919/3f7a247d-9937-4cf1-8d5f-5a12e0bb1c09.mp3"
  @filepath "test/samples/intro.mp3"

  defmodule Pipeline do
    use Membrane.Pipeline

    @target_sample_rate 16000

    @impl true
    def handle_init(opts) do
      filepath = Keyword.fetch!(opts, :filepath)
      to_pid = Keyword.fetch!(opts, :to_pid)
      model = Keyword.fetch!(opts, :model)

      children = %{
        file: %Membrane.File.Source{location: filepath},
        decoder: Membrane.MP3.MAD.Decoder,
        converter: %Membrane.FFmpeg.SWResample.Converter{
          output_caps: %Membrane.RawAudio{
            sample_format: :f32le,
            sample_rate: @target_sample_rate,
            channels: 1
          }
        },
        transcription: %MembraneTranscription.Element{to_pid: to_pid, model: model},
        fake_out: Membrane.Fake.Sink.Buffers
      }

      links = [
        link(:file) |> to(:decoder) |> to(:converter) |> to(:transcription) |> to(:fake_out)
      ]

      {{:ok, spec: %ParentSpec{children: children, links: links}, playback: :playing}, %{}}
    end

    @impl true
    def handle_shutdown(reason, state) do
      IO.inspect(state)
      IO.inspect("Shutdown: #{inspect(reason)}")
      :ok
    end

    @impl true
    def handle_notification(notification, element, _context, state) do
      IO.inspect(notification, label: "notification")
      IO.inspect(element, label: "element")
      {:ok, state}
    end

    @impl true
    def handle_element_end_of_stream({:fake_out, :input}, _context, state) do
      IO.puts("fake sink complete")
      {{:ok, playback: :stopped}, state}
    end

    @impl true
    def handle_element_end_of_stream({:transcription, :input}, _context, state) do
      IO.puts("transcription complete")
      {{:ok, playback: :stopped}, state}
    end

    @impl true
    def handle_element_end_of_stream(_, _context, state) do
      {:ok, state}
    end

    def handle_prepared_to_stopped(_context, state) do
      IO.puts("terminating pipeline")
      terminate(self())
      {:ok, state}
    end
  end

  setup_all do
    File.mkdir_p!("test/samples")

    case File.stat(@filepath) do
      {:error, :enoent} ->
        {:ok, result} = Req.get(@episode_url)
        File.write!(@filepath, result.body)

      {:ok, _} ->
        nil
    end

    :ok
  end

  def receive_transcript do
    receive do
      {:transcript, transcript} ->
        IO.puts("Received transcript")
        IO.inspect(transcript)
        assert %{items: _, language: _lang} = transcript

        receive_transcript()
      # :transcription_done ->
      #   IO.puts("Transcript done")
      #   nil
      after
        10_000 ->
          receive do
            :transcription_done ->
              IO.puts("Got transcription done")
          end
    end
  end

  @tag timeout: :infinity
  test "sample pipeline" do
    {:ok, pid} = Pipeline.start_link(filepath: @filepath, to_pid: self(), model: "tiny")
    Pipeline.play(pid)

    receive_transcript()
  end
end
