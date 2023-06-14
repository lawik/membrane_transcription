defmodule MembraneTranscription.FancyWhisper do
  # TODO: Rename to something reasonable. It is potentially a more performant and powerful variant but has
  # TODO: trade-offs in terms of latency and complexity
  # TODO: Should probably not have Whisper in the name as we might switch the model in the future
  #
  # TODO: This should really have some test-coverage to confirm it does what it is intended to do
  # TODO: It run a batch-based Nx.Serving meaning that multiple transcripts can be fed in at once within
  # TODO: the same batch_timeout and both be shoved through the GPU/CPU together for better utilization
  # TODO: XLA can only run one operation on the GPU at one time, so batching is the best way to achieve
  # TODO: concurrency
  # TODO: A higher batch_timeout increases the chance that work gets batched but also introduces latency
  # TODO: as it waits that long unless the batch size fills up first.
  #
  # TODO: I would add an option acceptable_latency and turn that into batch_size, default it to 100ms
  #
  # TODO: There is also a priority_queue mechanism here which is intended to give work marked :high in
  # TODO: priority right of way to go before the regular queue. This part should have test coverage to see
  # TODO: that is actually achieves the intended outcome.
  #
  # TODO: It might be worth abstracting the Nx stuff behind a module so it can be
  # TODO: switched out in testing
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    model = Keyword.fetch!(opts, :model)
    {:ok, whisper} = Bumblebee.load_model({:hf, "openai/whisper-#{model}"})
    {:ok, featurizer} = Bumblebee.load_featurizer({:hf, "openai/whisper-#{model}"})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "openai/whisper-#{model}"})

    serving =
      Bumblebee.Audio.speech_to_text(whisper, featurizer, tokenizer,
        max_new_tokens: 100,
        defn_options: [compiler: EXLA]
      )

    {:ok, pid} =
      Nx.Serving.start_link(
        serving: serving,
        name: MembraneTranscription.FancyWhisper.Serving,
        batch_timeout: 100
      )

    blank = for _ <- 1..16000, into: <<>>, do: <<0, 0, 0, 0>>

    audio =
      blank
      |> Nx.from_binary(:f32)
      |> Nx.reshape({:auto, 1})
      |> Nx.mean(axes: [1])

    {t, _} =
      :timer.tc(fn ->
        Nx.Serving.batched_run(MembraneTranscription.FancyWhisper.Serving, audio)
      end)

    Logger.info("Warmed up whisper in #{t / 1000}ms")

    {:ok, %{serving: serving, normal_queue: [], priority_queue: [], pid: pid}}
  end

  def new_audio(raw_pcm_32_or_wav, channels, sampling_rate) do
    IO.inspect(raw_pcm_32_or_wav)

    %{
      data: raw_pcm_32_or_wav,
      num_channels: channels,
      sampling_rate: sampling_rate
    }
  end

  @timeout 30_000
  def transcribe!(audio, priority \\ :normal) do
    Logger.info("Transcribing #{byte_size(audio.data)} byte at priority #{priority}...")
    GenServer.call(__MODULE__, {:transcribe, audio, priority}, @timeout)
  end

  @impl true
  def handle_call({:transcribe, audio, priority}, from, state) do
    audio =
      audio.data
      |> Nx.from_binary(:f32)
      |> Nx.reshape({:auto, audio.num_channels})
      |> Nx.mean(axes: [1])

    state =
      case priority do
        :high ->
          %{state | priority_queue: state.priority_queue ++ [{from, audio}]}

        _ ->
          %{state | normal_queue: state.normal_queue ++ [{from, audio}]}
      end

    # output = Nx.Serving.run(state.serving, audio)
    send(self(), :process)
    {:noreply, state}
  end

  @impl true
  def handle_info(:process, state) do
    state.priority_queue
    |> Enum.map(fn {from, input} ->
      Task.start(fn ->
        output = Nx.Serving.batched_run(MembraneTranscription.FancyWhisper.Serving, input)
        GenServer.reply(from, output)
      end)
    end)

    state.normal_queue
    |> Enum.map(fn {from, input} ->
      Task.start(fn ->
        output = Nx.Serving.batched_run(MembraneTranscription.FancyWhisper.Serving, input)
        GenServer.reply(from, output)
      end)
    end)

    {:noreply, %{state | normal_queue: [], priority_queue: []}}
  end
end
