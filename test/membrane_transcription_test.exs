defmodule MembraneTranscriptionTest do
  use ExUnit.Case

  # import ExUnit.CaptureLog

  @episode_url "https://aphid.fireside.fm/d/1437767933/a11633b3-cf22-42b6-875e-ecdfee41c919/3f7a247d-9937-4cf1-8d5f-5a12e0bb1c09.mp3"
  @filepath "test/samples/intro.mp3"

  defmodule Pipeline do
    use Membrane.Pipeline

    @target_sample_rate 16000
    @bitdepth 32
    @byte_per_sample @bitdepth / 8
    @byte_per_second @target_sample_rate * @byte_per_sample

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
        # realtime: %MembraneTranscription.Realtime{
        #   bytes_per_second: @byte_per_second,
        #   resolution_ms: 10,
        #   delay_ms: 0
        # },
        timestamper: %MembraneTranscription.Timestamper{
          bytes_per_second: @byte_per_second
        },
        transcription: %MembraneTranscription.Element{to_pid: to_pid, model: model},
        # delay: %MembraneTranscription.Realtime{
        #   bytes_per_second: @byte_per_second,
        #   resolution_ms: 10,
        #   delay_ms: 5000
        # },
        fake_out: Membrane.Fake.Sink.Buffers
      }

      links = [
        link(:file)
        |> to(:decoder)
        |> to(:converter)
        # |> to(:realtime)
        |> to(:timestamper)
        |> to(:transcription)
        # |> to(:delay)
        |> to(:fake_out)
      ]

      {{:ok, spec: %ParentSpec{children: children, links: links}, playback: :playing},
       %{to_pid: to_pid}}
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
      send(state.to_pid, :done)
      terminate(self())
      {{:ok, playback: :stopped}, state}
    end

    @impl true
    def handle_element_end_of_stream({:transcription, :input}, _context, state) do
      IO.puts("transcription complete")
      IO.inspect(state.to_pid)
      send(state.to_pid, :transcription_done)
      {{:ok, playback: :stopped}, state}
    end

    @impl true
    def handle_element_end_of_stream(_, _context, state) do
      {:ok, state}
    end

    def handle_prepared_to_stopped(_context, state) do
      IO.puts("terminating pipeline")
      send(state.to_pid, :shutdown)
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

  def receive_transcript(acc \\ []) do
    receive do
      {:transcript, transcript} ->
        IO.puts("Received transcript")
        IO.inspect(transcript)
        receive_transcript([acc, transcript])

      :transcription_done ->
        IO.puts("Transcript done")
        acc
    after
      1000 ->
        :ok
    end
  end

  @tag timeout: :infinity
  test "sample pipeline" do
    # with_log(fn ->
    {:ok, _} = MembraneTranscription.Whisper.start_link(nil)
    {:ok, pid} = Pipeline.start_link(filepath: @filepath, to_pid: self(), model: "tiny")
    Pipeline.play(pid)

    receive_transcript()
    |> IO.inspect()

    receive do
      :done ->
        assert true
    end

    receive do
      :shutdown ->
        assert true
    end

    # end)
  end
end
