defmodule MembraneTranscription.FancyWhisper do
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
      Task.async(fn ->
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
