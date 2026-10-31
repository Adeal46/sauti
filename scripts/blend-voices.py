#!/usr/bin/env python3
"""Adds Wolf Companion's own blended voices to Kokoro's voices.bin.

voices.bin holds one 510x256 float32 style table per speaker. A blend is a
weighted mix of existing speakers' tables written into a slot the app doesn't
otherwise use (Japanese speakers), so the model treats it as a normal voice.
Idempotent: blends are always computed from the original source slots.
"""
import sys
from array import array

ROW = 510 * 256
SPEAKERS = 54

# slot -> {source speaker id: weight}
BLENDS = {
    # "Ridge": deep, unhurried storyteller (Lewis, deepened with Onyx).
    41: {27: 0.8, 17: 0.2},
}


def main(path):
    data = array("f")
    with open(path, "rb") as f:
        data.frombytes(f.read())
    if len(data) != ROW * SPEAKERS:
        sys.exit(f"unexpected voices.bin size: {len(data)} floats")

    for slot, mix in BLENDS.items():
        out = [0.0] * ROW
        for speaker, weight in mix.items():
            base = speaker * ROW
            for i in range(ROW):
                out[i] += data[base + i] * weight
        data[slot * ROW:(slot + 1) * ROW] = array("f", out)

    with open(path, "wb") as f:
        data.tofile(f)
    print(f"Blended {len(BLENDS)} voice(s) into {path}")


if __name__ == "__main__":
    main(sys.argv[1])
