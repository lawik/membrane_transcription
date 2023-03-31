defmodule MembraneTranscription.Amplitude do
  @moduledoc false

  alias Membrane.RawAudio

  @doc """
  Finds frame within given payload that has the highest amplitude for any of its channels.

  On success, it returns `{:ok, {values, rest}}`, where:

  * `values` is a list of amplitudes per channel expressed in decibels, or one of `:infinity`
    or `:clip`,
  * `rest` is a binary containing payload remaining after processing if given payload contained
    incomplete frames.

  On error it returns, `{:error, reason}`, where `reason` is one of the following:

  * `:empty` - the payload was empty.
  """
  @spec find_amplitudes(binary, RawAudio.t()) ::
          {:ok, {[number | :infinity | :clip], binary}}
          | {:error, any}
  def find_amplitudes(<<>>, _caps) do
    {:error, :empty}
  end

  def find_amplitudes(payload, caps) do
    # Get silence as a point of reference
    silence_payload = RawAudio.silence(caps)
    silence_value = RawAudio.sample_to_value(silence_payload, caps)

    # Find max sample values within given payload
    {:ok, {frame_values, rest}} =
      do_find_frame_with_max_values(
        payload,
        caps,
        RawAudio.frame_size(caps),
        RawAudio.sample_size(caps),
        silence_value,
        nil
      )

    # Convert values into decibels
    max_amplitude_value =
      if RawAudio.sample_type_float?(caps) do
        1.0
      else
        # +1 is needed so max int value for frame does not cause clipping
        RawAudio.sample_max(caps) - silence_value + 1
      end

    {:ok, frame_values_in_dbs} = do_convert_values_to_dbs(frame_values, max_amplitude_value, [])

    # Return amplitudes in dBs and remaining payload
    {:ok, {frame_values_in_dbs, rest}}
  end

  # If we have at least one frame in the payload, get values of its samples.
  defp do_find_frame_with_max_values(payload, caps, frame_size, sample_size, silence_value, acc)
       when byte_size(payload) >= frame_size do
    <<frame::binary-size(frame_size), rest::binary>> = payload

    # Get list of sample values per channel, normalized to 0..n scale
    {:ok, sample_values} =
      do_sample_to_channel_values(frame, caps, sample_size, silence_value, [])

    # Check if the new frame is louder than the last known loudest
    {:ok, max_sample_values} = do_find_max_sample_values(acc, sample_values)

    do_find_frame_with_max_values(
      rest,
      caps,
      frame_size,
      sample_size,
      silence_value,
      max_sample_values
    )
  end

  # If we have not less than one frame in the payload, return the amplitudes
  # and the remaning payload.
  defp do_find_frame_with_max_values(
         payload,
         _caps,
         _frame_size,
         _sample_size,
         _silence_value,
         acc
       ),
       do: {:ok, {acc, payload}}

  # If there's any payload, convert sample data to actual values normalized on 0..n scale
  defp do_sample_to_channel_values(payload, caps, sample_size, silence_value, acc)
       when byte_size(payload) >= sample_size do
    <<sample::binary-size(sample_size), rest::binary>> = payload

    value = (RawAudio.sample_to_value(sample, caps) - silence_value) |> abs

    do_sample_to_channel_values(rest, caps, sample_size, silence_value, [value | acc])
  end

  # If there's no more payload in the frame, return a list with sample values per channel.
  defp do_sample_to_channel_values(<<>>, _caps, _sample_size, _silence_value, acc),
    do: {:ok, Enum.reverse(acc)}

  # If there's no previous sample known, current one has to be louder.
  defp do_find_max_sample_values(nil, current), do: {:ok, current}

  # Use pattern matching for the most common cases for a performance reasons:
  # Mono, previous frame is louder
  defp do_find_max_sample_values([previous_value] = previous, [current_value])
       when previous_value >= current_value,
       do: {:ok, previous}

  # Mono, current frame is louder
  defp do_find_max_sample_values([previous_value], [current_value] = current)
       when previous_value < current_value,
       do: {:ok, current}

  # Stereo, any of the channels in the previous frame is louder than any of the channels in the current frame
  defp do_find_max_sample_values([previous_value1, previous_value2] = previous, [
         current_value1,
         current_value2
       ])
       when (previous_value1 >= current_value1 and previous_value1 >= current_value2) or
              (previous_value2 >= current_value1 and previous_value2 >= current_value2),
       do: {:ok, previous}

  # Stereo, any of the channels in the current frame is louder than any of the channels in the previous frame
  defp do_find_max_sample_values(
         [previous_value1, previous_value2],
         [current_value1, current_value2] = current
       )
       when (current_value1 >= previous_value1 and current_value1 >= previous_value2) or
              (current_value2 >= previous_value1 and current_value2 >= previous_value2),
       do: {:ok, current}

  # Generic handler for multi-channel audio
  defp do_find_max_sample_values(previous, current) do
    if Enum.max(previous) >= Enum.max(current) do
      {:ok, previous}
    else
      {:ok, current}
    end
  end

  defp do_convert_values_to_dbs([head | tail], max_amplitude_value, acc) do
    value =
      cond do
        head > max_amplitude_value ->
          :clip

        head > 0 ->
          20 * :math.log10(head / max_amplitude_value)

        true ->
          :infinity
      end

    do_convert_values_to_dbs(tail, max_amplitude_value, [value | acc])
  end

  defp do_convert_values_to_dbs([], _max_amplitude_value, acc), do: {:ok, Enum.reverse(acc)}
end
