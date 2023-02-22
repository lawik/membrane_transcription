defmodule MembraneTranscription.Element do
  alias MembraneTranscription.Whisper
  use Membrane.Filter

  def_options(
    to_pid: [
      spec: :any,
      default: nil,
      description: "PID to report to"
    ],
    model: [
      spec: :any,
      default: "base",
      description: "Model to use"
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
  @assumed_target_timeslices 5
  @format_byte_size %{
    f32le: 4
  }
  @channels 1

  @impl true
  def handle_init(%__MODULE{to_pid: pid, model: model}) do
    state = %{to_pid: pid, model: model, previous: nil, buffered: []}

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
  def handle_process(:input, %Membrane.Buffer{} = buffer, context, state) do
    # IO.inspect(buffer, label: "processing buffer")
    # IO.inspect(context, label: "context")

    # transcript = MembraneTranscription.Whisper.transcribe!(buffer.payload, "pcm", state.model)
    # send(state.to_pid, {:transcript, transcript})

    buffered = [state.buffered | buffer.payload]
    sample_size = @format_byte_size[:f32le]

    {buffered, transcript} =
      if IO.iodata_length(buffered) / sample_size / @assumed_sample_rate >
           @assumed_target_timeslices do
        # TODO: Processing
        IO.inspect(IO.iodata_length(buffered), label: "buffer ready")
        data = IO.iodata_to_binary(buffered)
        {[], Whisper.transcribe!(Whisper.new_audio(data, @channels, @assumed_sample_rate))}
      else
        {buffered, nil}
      end

    if transcript do
      IO.inspect(transcript, label: "transcript")
    end

    {{:ok, buffer: {:output, buffer}}, %{state | previous: buffer.payload, buffered: buffered}}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    IO.puts("Handle playing to prepared")
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_stopped(_ctx, state) do
    IO.puts("Ending transcription element")
    send(state.to_pid, :transcription_done)
    {:ok, state}
  end
end
