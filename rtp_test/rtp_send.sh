#/usr/bin/env bash

# lavfi is like "make me a filter graph" i think? where the filter is a sin wave at 48k, forever
# c:a specifies audio codec
# https://en.wikipedia.org/wiki/Mu-law_algorithm
ffmpeg \
  -f lavfi -i "sine=frequency=1:sample_rate=8000:duration=0" \
  -c:a pcm_mulaw \
  -f rtp -sdp_file out.sdp rtp://127.0.0.1:5004
