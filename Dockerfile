FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg python3 bc \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8

COPY convert-to-av1.sh /usr/local/bin/convert-to-av1
WORKDIR /media

ENTRYPOINT ["convert-to-av1"]
