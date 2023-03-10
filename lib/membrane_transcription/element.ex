defmodule MembraneTranscription.Element do
  alias MembraneTranscription.Whisper
  use Membrane.Filter

  def_options(
    buffer_duration: [
      spec: :any,
      default: 5,
      description: "Duration of each chunk transcribed in seconds"
    ]
  )

  def_input_pad(:input,
    demand_unit: :buffers,
    caps: :any
  )

  def_output_pad(:output,
    availability: :always,
    mode: :pull,
    caps: :any
  )

  @assumed_sample_rate 16000
  # seconds
  @format_byte_size %{
    f32le: 4
  }
  @channels 1

  defp time, do: :erlang.system_time(:millisecond)

  @impl true
  def handle_init(%__MODULE{buffer_duration: buffer_duration}) do
    state = %{
      buffer_duration: buffer_duration,
      previous: nil,
      buffered: [],
      start_ts: 0,
      end_ts: 0,
      started_at: time()
    }

    # Pre-heat the oven
    blank = for _ <- 1..(@channels * @assumed_sample_rate), into: <<>>, do: <<0, 0, 0, 0>>

    {timing, _transcript} =
      :timer.tc(fn ->
        Whisper.transcribe!(Whisper.new_audio(blank, @channels, @assumed_sample_rate))
      end)

    IO.puts("Whisper warmup timing: #{timing}")

    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: :input}, state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _context, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _context, state) do
    buffered = [state.buffered | buffer.payload]
    sample_size = @format_byte_size[:f32le]

    if IO.iodata_length(buffered) / sample_size / @assumed_sample_rate >
         state.buffer_duration do
      IO.inspect(IO.iodata_length(buffered), label: "buffer ready")

      data = IO.iodata_to_binary(buffered)

      {timing, transcript} =
        :timer.tc(fn ->
          Whisper.transcribe!(Whisper.new_audio(data, @channels, @assumed_sample_rate))
        end)

      IO.puts(
        "Transcribed #{state.start_ts}ms to #{buffer.metadata.end_ts}ms in #{floor(timing / 1000)}ms."
      )

      IO.inspect(transcript, label: "transcript")

      type =
        case state.start_ts do
          0 -> :start
          _ -> :mid
        end

      notification = {:transcribed, transcript, type, state.start_ts, buffer.metadata.end_ts}

      state = %{
        state
        | buffered: [],
          start_ts: buffer.metadata.end_ts,
          end_ts: buffer.metadata.end_ts
      }

      {{:ok, buffer: {:output, buffer}, notify: notification}, state}
    else
      state = %{state | buffered: buffered, end_ts: max(buffer.metadata.end_ts, state.end_ts)}
      {{:ok, buffer: {:output, buffer}}, state}
    end
  end

  @impl true
  def handle_end_of_stream(_pad, _context, state) do
    IO.puts("End of stream for transcriber...")
    IO.inspect(IO.iodata_length(state.buffered), label: "final buffer")
    data = IO.iodata_to_binary(state.buffered)

    {timing, transcript} =
      :timer.tc(fn ->
        Whisper.transcribe!(Whisper.new_audio(data, @channels, @assumed_sample_rate))
      end)

    IO.puts("Transcribed #{state.start_ts}ms to #{state.end_ts}ms in #{floor(timing / 1000)}ms.")

    IO.inspect(transcript, label: "final transcript")
    t = time()
    IO.inspect("transcription element runtime #{t - state.started_at}ms")
    notification = {:transcribed, transcript, :end, state.start_ts, state.end_ts}

    {{:ok, end_of_stream: :output, notify: notification}, state}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    IO.puts("Handle playing to prepared")
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_stopped(_ctx, state) do
    IO.puts("Ending transcription element")
    {:ok, state}
  end
end
