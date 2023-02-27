defmodule MembraneTranscription.Whisper do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    {:ok, whisper} = Bumblebee.load_model({:hf, "openai/whisper-base.en"})
    {:ok, featurizer} = Bumblebee.load_featurizer({:hf, "openai/whisper-base.en"})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "openai/whisper-base.en"})

    serving =
      Bumblebee.Audio.speech_to_text(whisper, featurizer, tokenizer,
        max_new_tokens: 100,
        defn_options: [compiler: EXLA]
      )

    {:ok, %{serving: serving}}
  end

  def new_audio(raw_pcm_32_or_wav, channels, sampling_rate) do
    %{
      data: raw_pcm_32_or_wav,
      num_channels: channels,
      sampling_rate: sampling_rate
    }
  end

  @timeout 30_000
  def transcribe!(audio) do
    Logger.info("Transcribing #{byte_size(audio.data)} byte...")
    GenServer.call(__MODULE__, {:transcribe, audio}, @timeout)
  end

  def handle_call({:transcribe, audio}, _from, state) do
    audio =
      audio.data
      |> Nx.from_binary(:f32)
      |> Nx.reshape({:auto, audio.num_channels})
      |> Nx.mean(axes: [1])

    output = Nx.Serving.run(state.serving, audio)
    {:reply, output, state}
  end
end
