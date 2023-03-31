defmodule MembraneTranscription.Element do
  alias MembraneTranscription.Whisper
  alias MembraneTranscription.FancyWhisper
  use Membrane.Filter

  def_options(
    buffer_duration: [
      spec: :any,
      default: 5,
      description: "Duration of each chunk transcribed in seconds"
    ],
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

  def_input_pad(:input,
    demand_unit: :buffers,
    caps: :any
  )

  def_output_pad(:output,
    availability: :always,
    mode: :pull,
    caps: :any
  )

  @silence <<0, 0, 0, 0>>
  @tolerate_silence_ms 600
  @assumed_sample_rate 16000
  # seconds
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
    buffered = [state.buffered | buffer.payload]
    sample_size = @format_byte_size[:f32le]
    data = IO.iodata_to_binary(buffered)

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
        # This process flattens or binary
        # remaining_bytes =
        #   case detect_silence(data) do
        #     {<<>>, bytes_to_save} ->
        #       bytes_to_save

        #     {bytes_to_transcribe, bytes_to_save} ->
        #       # TODO: Fix lying end_ts
        #       IO.puts("silenced detected #{byte_size(bytes_to_transcribe)}")
        #       trigger_transcript(bytes_to_transcribe, state, buffer.metadata.end_ts)
        #       bytes_to_save
        #   end

        # %{state | buffered: [remaining_bytes], end_ts: max(buffer.metadata.end_ts, state.end_ts)}
        %{state | buffered: [data], end_ts: max(buffer.metadata.end_ts, state.end_ts)}
      end

    {{:ok, buffer: {:output, buffer}}, state}
  end

  @silence_ceiling 0.2
  @silence_floor -0.2
  defp detect_silence(data) do
    data = trim_leading_silence(data)

    case find_silence(data) do
      -1 ->
        {<<>>, data}

      offset ->
        <<transcribe::binary-size(offset), keep::binary>> = data
        {transcribe, keep}
    end
  end

  defp trim_leading_silence(data) do
    case data do
      <<val::size(32)-float-little, rest::binary>> ->
        if val < @silence_ceiling and val > @silence_floor do
          trim_leading_silence(rest)
        else
          rest
        end

      <<>> ->
        <<>>
    end
  end

  @tolerate_silent_samples 16000 * (@tolerate_silence_ms / 1000)
  @tolerate_bits floor(@tolerate_silent_samples * 4)
  defp grab_samples(data, samples \\ []) do
    case data do
      <<sample::size(32)-float-little, rest::binary>> ->
        positive = abs(sample)
        grab_samples(rest, [samples, positive])

      <<>> ->
        List.flatten(samples)
    end
  end

  defp find_silence(data, offset \\ 0) do
    case data do
      <<val::binary-size(@tolerate_bits), rest::binary>> ->
        samples = grab_samples(val)
        c = Enum.count(samples)

        {mn, mx, sm} =
          Enum.reduce(samples, {nil, nil, 0}, fn v, {mn, mx, sm} ->
            mn = mn || v
            mx = mx || v
            {min(mn, v), max(mx, v), sm + v}
          end)

        avg = sm / c
        rng = mx - mn
        IO.inspect(%{min: mn, max: mx, avg: avg, range: rng})

        -1

      _ ->
        -1

      <<>> ->
        # IO.inspect(contiguous, label: "contiguous silence")
        -1
    end
  end

  defp find_silence_2(data, offset \\ 0, contiguous \\ 0) do
    case data do
      <<val::size(32)-float-little, rest::binary>> ->
        IO.inspect(:erlang.float_to_binary(val, decimals: 5))

        {break?, contiguous} =
          if val < @silence_ceiling and val > @silence_floor do
            {false, contiguous + 1}
          else
            if contiguous > @tolerate_silent_samples do
              IO.puts(
                "Not tolerating #{contiguous} (more than #{round(@tolerate_silent_samples)}) samples of silence... break"
              )

              {true, contiguous}
            else
              if contiguous > 0 do
                IO.puts("Tolerated #{contiguous} samples of silence... reset on #{val}")
              end

              {false, 0}
            end
          end

        if break? do
          offset * 4
        else
          find_silence_2(rest, offset + 1, contiguous)
        end

      <<>> ->
        # IO.inspect(contiguous, label: "contiguous silence")
        -1
    end
  end

  # @bytes_of_silence ((@assumed_sample_rate * 4) * (@tolerate_silence_ms / 1000))
  # defp find_silence(<<0::binary-size(@bytes_of_silence), rest::binary>>, silence) do
  #  IO.puts("found silence")
  #  {}
  # end

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
