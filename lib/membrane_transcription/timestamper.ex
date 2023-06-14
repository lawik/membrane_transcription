defmodule MembraneTranscription.Timestamper do
  # TODO: Document what this module does and is for
  # TODO: It adds timestamps to a stream that we can use for transcripts to ensure we know
  # TODO: where in time the transcripts happen
  use Membrane.Filter

  require Logger

  def_options(
    bytes_per_second: [
      spec: :any,
      default: nil,
      description: "Bytes per second"
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
  def handle_init(%__MODULE{
        bytes_per_second: bytes_per_second
      }) do
    # We determine time by bytesize
    millisecond_bytes = bytes_per_second / 1000

    state = %{
      millisecond_bytes: millisecond_bytes,
      processed_bytes: 0,
      count_in: 0,
      count_out: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: :input}, state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _context, state) do
    state = %{state | count_in: state.count_in + 1}

    byte_count = IO.iodata_length(buffer.payload)
    duration = floor(byte_count / state.millisecond_bytes)
    start_ts = floor(state.processed_bytes / state.millisecond_bytes)
    state = %{state | processed_bytes: state.processed_bytes + byte_count}
    end_ts = floor(state.processed_bytes / state.millisecond_bytes)
    metadata = buffer.metadata || %{}

    out_buffer =
      {:output,
       %{
         buffer
         | metadata:
             Map.merge(metadata, %{
               start_ts: start_ts,
               end_ts: end_ts,
               duration: duration
             })
       }}

    actions = [demand: :input, buffer: out_buffer]

    {{:ok, actions}, %{state | count_out: state.count_out + 1}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _context, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_end_of_stream(_pad, _context, state) do
    {{:ok, end_of_stream: :output}, state}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_stopped(_ctx, state) do
    {:ok, state}
  end
end
