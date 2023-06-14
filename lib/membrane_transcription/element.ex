defmodule MembraneTranscription.Element do
  # TODO: Can probably rename this. Maybe Filter instead of Element as it is a pass-through
  alias Membrane.RawAudio
  alias MembraneTranscription.Whisper
  alias MembraneTranscription.FancyWhisper
  use Membrane.Filter

  # TODO: Proper spec types instead of :any
  def_options(
    buffer_duration: [
      spec: :any,
      default: 5,
      description: "Duration of each chunk transcribed in seconds"
    ],
    # TODO: Fancy is a really bad option, see FancyWhisper for what it is
    fancy?: [
      spec: :any,
      default: false,
      description: "Use fancy whisper?"
    ],
    priority: [
      spec: :any,
      default: :normal,
      description: "normal or high"
    ]
  )

  # TODO: Make the input cap require a 16000hz sample rate on a RawAudio format in f32le encoding
  # TODO: Whisper requires 16000hz and f32le so if we require that on the caps that is information for
  # TODO: the user to conform to that with the software resample filter for example, means it will fail
  # TODO: clearly for bad inputs
  def_input_pad(:input,
    demand_unit: :buffers,
    caps: :any
  )

  def_output_pad(:output,
    availability: :always,
    mode: :pull,
    caps: :any
  )

  # TODO: Remove silence stuff, not used, not working
  @silence <<0, 0, 0, 0>>
  @tolerate_silence_ms 600

  # TODO: See notes about input cap, this is probably still a useful number to have for some math
  @assumed_sample_rate 16000
  # seconds
  # TODO: Don't think we will support any other formats, if we don't, no reason this should be a map
  @format_byte_size %{
    f32le: 4
  }
  @channels 1

  defp time, do: :erlang.system_time(:millisecond)

  @impl true
  def handle_init(%__MODULE{buffer_duration: buffer_duration, fancy?: fancy?, priority: priority}) do
    state = %{
      buffer_duration: buffer_duration,
      previous: nil,
      buffered: [],
      start_ts: 0,
      end_ts: 0,
      started_at: time(),
      fancy?: fancy?,
      priority: priority,
      transcribing?: false
    }

    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: :input}, state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _context, state) do
    buffered = [state.buffered, buffer.payload]
    sample_size = @format_byte_size[:f32le]

    data = IO.iodata_to_binary(buffered)

    # TODO: Warn at least once if metadata doesn't have timestamper information
    # TODO: Reference that the timestamper filter can be added to the pipeline
    # TODO: to get that information
    # TODO: It should still work without it, the current implementation will fail

    state =
      if byte_size(data) / sample_size / @assumed_sample_rate >
           state.buffer_duration and not state.transcribing? do
        trigger_transcript(data, state, buffer.metadata.end_ts)

        %{
          state
          | buffered: [],
            start_ts: buffer.metadata.end_ts,
            end_ts: buffer.metadata.end_ts,
            transcribing?: true
        }
      else
        %{state | buffered: [data], end_ts: max(buffer.metadata.end_ts, state.end_ts)}
      end

    {{:ok, buffer: {:output, buffer}}, state}
  end

  defp trigger_transcript(data, state, end_ts) do
    send_to = self()

    Task.start(fn ->
      type =
        case state.start_ts do
          0 -> :start
          _ -> :mid
        end

      {timing, transcript} =
        :timer.tc(fn ->
          if state.fancy? do
            FancyWhisper.transcribe!(
              FancyWhisper.new_audio(data, @channels, @assumed_sample_rate),
              state.priority
            )
          else
            Whisper.transcribe!(Whisper.new_audio(data, @channels, @assumed_sample_rate))
          end
        end)

      # TODO: Replace all uses of IO.puts/inspect with Logger.debug or remove them depending
      # TODO: This one is useful so Logger.debug
      IO.puts(
        "Transcribed async #{state.start_ts}ms to #{end_ts}ms in #{floor(timing / 1000)}ms."
      )

      notification = {:transcribed, transcript, type, state.start_ts, end_ts}

      IO.inspect(transcript, label: "transcript")
      send(send_to, {:transcript, transcript, notification})
    end)
  end

  @impl true
  def handle_demand(:output, size, :buffers, _context, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_end_of_stream(_pad, _context, state) do
    # TODO: Lots of IO to clean up
    IO.puts("End of stream for transcriber...")
    IO.inspect(IO.iodata_length(state.buffered), label: "final buffer")
    data = IO.iodata_to_binary(state.buffered)

    {timing, transcript} =
      :timer.tc(fn ->
        FancyWhisper.transcribe!(Whisper.new_audio(data, @channels, @assumed_sample_rate))
      end)

    IO.puts("Transcribed #{state.start_ts}ms to #{state.end_ts}ms in #{floor(timing / 1000)}ms.")

    IO.inspect(transcript, label: "final transcript")
    t = time()
    IO.inspect("transcription element runtime #{t - state.started_at}ms")
    notification = {:transcribed, transcript, :end, state.start_ts, state.end_ts}

    {{:ok, end_of_stream: :output, notify: notification}, state}
  end

  @impl true
  def handle_other({:transcript, _transcript, notification}, _ctx, state) do
    {{:ok, notify: notification}, %{state | transcribing?: false}}
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
