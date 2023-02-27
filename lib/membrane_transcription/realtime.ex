defmodule MembraneTranscription.Realtime do
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

  defp time, do: :erlang.system_time(:millisecond)

  @impl true
  def handle_init(%__MODULE{
        bytes_per_second: bytes_per_second,
        resolution_ms: resolution_ms,
        delay_ms: delay_ms
      }) do
    state = %{
      bytes_per_second: bytes_per_second,
      base_time: nil,
      buffered: [],
      resolution_ms: resolution_ms,
      delay_ms: delay_ms,
      count_in: 0,
      count_out: 1
    }

    IO.inspect(state)

    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: :input}, state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, context, state) do
    Logger.info("Demand, #{context.name}: #{state.count_in} #{state.count_out}")
    {{:ok, demand: {:input, size}}, %{state | count_out: state.count_out + 1}}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _context, state) do
    state =
      if is_nil(state.base_time) do
        %{state | base_time: time()}
      else
        state
      end

    state = %{state | count_in: state.count_in + 1}
    t = time()
    elapsed = t - state.base_time
    buffered = [state.buffered | buffer.payload]

    {buffered, send} =
      if elapsed >= state.delay_ms do
        IO.inspect(IO.iodata_length(buffered), label: "#{state.resolution_ms}ms captured")
        data = IO.iodata_to_binary(buffered)
        {[], data}
      else
        {buffered, nil}
      end

    if send do
      IO.puts("Sending on with delay #{state.delay_ms}ms after #{elapsed}ms...")

      {{:ok,
        demand: :input,
        buffer:
          {:output,
           %Membrane.Buffer{
             payload: send,
             metadata: %{
               sts: state.base_time,
               ts: t,
               elapsed_ms: t - state.base_time
             }
           }}}, %{state | buffered: buffered}}
    else
      {{:ok, demand: :input}, %{state | buffered: buffered}}
    end
  end

  @impl true
  def handle_end_of_stream(_pad, _context, state) do
    t = time()

    buffer = %Membrane.Buffer{
      payload: state.buffered,
      metadata: %{
        sts: state.base_time,
        ts: t,
        elapsed_ms: t - state.base_time
      }
    }

    {:ok, buffer: {:output, buffer}}
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
