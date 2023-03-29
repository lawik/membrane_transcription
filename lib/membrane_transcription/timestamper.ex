defmodule MembraneTranscription.Timestamper do
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

  # defp time, do: :erlang.system_time(:millisecond)

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
  def handle_demand(:output, size, :buffers, _context, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  defp to_samples(bytes, size, values \\ []) do
    case bytes do
      <<sample::binary-size(size), rest::binary>> ->
        to_samples(rest, size, [values, sample])

      <<>> ->
        List.flatten(values)
    end
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, context, state) do
    state = %{state | count_in: state.count_in + 1}

    %Membrane.RawAudio{} = format = context.pads.input.caps
    sample_size = Membrane.RawAudio.sample_size(format)

    values =
      buffer.payload
      |> to_samples(sample_size)
      |> Enum.map(&Membrane.RawAudio.sample_to_value(&1, format))

    byte_count = IO.iodata_length(buffer.payload)
    duration = floor(byte_count / state.millisecond_bytes)
    start_ts = floor(state.processed_bytes / state.millisecond_bytes)
    state = %{state | processed_bytes: state.processed_bytes + byte_count}
    end_ts = floor(state.processed_bytes / state.millisecond_bytes)
    metadata = buffer.metadata || %{}

    if start_ts > 2000 do
      # IO.inspect(buffer.payload)
      IO.inspect(Enum.count(values))
      IO.inspect(values)
    end

    if start_ts > 2500 do
      IO.inspect(buffer.metadata)
      IO.inspect(context)
      IO.inspect(Membrane.RawAudio.sample_min(format), label: "min")
      IO.inspect(Membrane.RawAudio.sample_max(format), label: "max")

      IO.inspect(
        Membrane.RawAudio.silence(%Membrane.RawAudio{
          sample_format: :f32le,
          sample_rate: 16000,
          channels: 1
        })
        |> Membrane.RawAudio.sample_to_value(format),
        label: "silence"
      )

      raise "foo"
    end

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
