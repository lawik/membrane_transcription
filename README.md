# Membrane Transcription

## FFMPEG for the right format

```
ffmpeg -t 30 -i ~/Movies/Underjord-Short-005-v1.mp4 -f f32le -acodec pcm_f32le -ac 1 -ar 16000 -vn output.pcm
```