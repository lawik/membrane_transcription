defmodule MembraneTranscription.Realtime do
  # TODO: Remove this or break it out to a separate library
  # TODO: It was intended to turn a pre-recorded file into a realtime stream
  # TODO: Not needed for this library, it might fit in my experimental membrane_other repo
  # TODO: Easy enough to recreate so could just remove, keep scope in check
  use Membrane.Filter

  require Logger

  def_options(
    bytes_per_second: [
      spec: :any,
      default: nil,
      description: "Bytes per second"
    ],
    resolution_ms: [
      spec: :any,
      default: 10,
      description: "Millisecond default resolution"
    ],
    delay_ms: [
      spec: :any,
      default: 0,
      description: "Delay stream by buffering this much time."
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

  # defp time, do: :erlang.system_time(:millisecond)

  @impl true
  def handle_init(%__MODULE{
        bytes_per_second: bytes_per_second,
        resolution_ms: resolution_ms,
        delay_ms: delay_ms
      }) do
    # Reminder, the timestamps are a utility for later processing
    # and it helps us indicate uneven beginnings and ends

    # We determine time by bytesize
    millisecond_bytes = bytes_per_second / 1000
    timeblock_ms = max(delay_ms, resolution_ms)
    await_bytes = floor(millisecond_bytes * timeblock_ms)

    state = %{
      bytes_per_second: bytes_per_second,
      await_bytes: await_bytes,
      total_time: 0,
      buffered: [],
      resolution_ms: resolution_ms,
      delay_ms: delay_ms,
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
  def handle_demand(:output, size, :buffers, _context, state) do
    {{:ok, demand: {:input, size}}, %{state | count_out: state.count_out + 1}}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, context, state) do
    state = %{state | count_in: state.count_in + 1}

    buffered = [state.buffered | buffer.payload]
    byte_count = IO.iodata_length(buffered)
    duration = floor(byte_count / state.bytes_per_second * 1000)
    state = %{state | buffered: buffered, total_time: floor(state.total_time + duration)}

    if byte_count >= state.await_bytes do
      IO.puts(
        "[#{context.name}] delay elapsed (#{byte_count} reached #{state.await_bytes}), sending"
      )

      send_buffer(duration, context, state)
    else
      capture_buffer(state)
    end
  end

  @impl true
  def handle_end_of_stream(_pad, context, state) do
    IO.puts("[#{context.name}] end of stream")
    byte_count = IO.iodata_length(state.buffered)
    duration = floor(byte_count / state.bytes_per_second * 1000)
    state = %{state | total_time: floor(state.total_time + duration)}

    send_buffer(duration, context, state, end_of_stream: :output)
  end

  def capture_buffer(state) do
    {{:ok, demand: :input}, %{state | buffered: state.buffered}}
  end

  defp send_buffer(duration, context, state, actions \\ []) do
    data = IO.iodata_to_binary(state.buffered)

    IO.puts(
      "[#{context.name}] sending on #{byte_size(data)} bytes with delay #{state.delay_ms}ms after #{duration}ms (total #{state.total_time + duration}ms)..."
    )

    out_buffer =
      {:output,
       %Membrane.Buffer{
         payload: data,
         metadata: %{
           sts: state.total_time,
           ts: state.total_time + duration,
           elapsed_ms: duration
         }
       }}

    actions = [demand: :input, buffer: out_buffer] ++ actions

    {{:ok, actions}, %{state | buffered: []}}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_stopped(_ctx, state) do
    IO.puts("prepared to stopped")
    {:ok, state}
  end
end
