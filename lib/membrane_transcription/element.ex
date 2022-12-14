defmodule MembraneTranscription.Element do
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

  @impl true
  def handle_init(%__MODULE{to_pid: pid, model: model}) do
    state = %{to_pid: pid, model: model}

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
    # IO.inspect(buffer, label: "processing buffer")

    transcript = MembraneTranscription.Whisper.transcribe!(buffer.payload, "pcm", state.model)
    send(state.to_pid, {:transcript, transcript})

    {{:ok, buffer: {:output, buffer}}, state}
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
