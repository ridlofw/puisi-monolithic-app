FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIPER_MODEL=/opt/voices/id_ID-news_tts-medium.onnx

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY workers/text-to-speech/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Pin the upstream model repository revision and verify both downloaded files.
ARG VOICE_REVISION=9f967d15e9ccdf43078586d1476ee70f314401bd
RUN mkdir -p /opt/voices \
    && curl --fail --location --retry 4 --retry-all-errors \
      "https://huggingface.co/rhasspy/piper-voices/resolve/${VOICE_REVISION}/id/id_ID/news_tts/medium/id_ID-news_tts-medium.onnx" \
      -o /opt/voices/id_ID-news_tts-medium.onnx \
    && curl --fail --location --retry 4 --retry-all-errors \
      "https://huggingface.co/rhasspy/piper-voices/resolve/${VOICE_REVISION}/id/id_ID/news_tts/medium/id_ID-news_tts-medium.onnx.json" \
      -o /opt/voices/id_ID-news_tts-medium.onnx.json \
    && echo '17de01db7ac654655436b6e509893c72  /opt/voices/id_ID-news_tts-medium.onnx' | md5sum --check - \
    && echo 'c023cfa031cc9ed4cf5dd8d2ef1e48ed  /opt/voices/id_ID-news_tts-medium.onnx.json' | md5sum --check -

COPY workers/text-to-speech/suara.py ./suara.py
COPY workers/text-to-speech/tests ./tests
COPY workers/_templat/amplop.py workers/_templat/metrik.py workers/text-to-speech/store.py workers/text-to-speech/worker.py workers/text-to-speech/init_storage.py workers/text-to-speech/benchmark.py ./
RUN useradd --system --uid 10001 --create-home tts \
    && mkdir -p /work \
    && chown -R tts:tts /work
USER tts

CMD ["python", "-m", "unittest", "discover", "-s", "tests", "-v"]
