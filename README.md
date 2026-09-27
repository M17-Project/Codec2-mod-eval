# Codec2-mod-eval

ViSQOL-based quality and compatibility tests for [Codec2-mod](https://github.com/M17-Project/Codec2-mod) vs. vanilla Codec2 (3200 mode), including cross-encoding between the two.

## Requirements

- gcc, make, git
- libsndfile and libcodec2 (development packages)
- sox
- [ViSQOL](https://github.com/google/visqol) (`visqol` in `PATH`, speech-mode lattice model)
- A `wav_files/` directory with mono, 8 kHz, 16-bit PCM WAV files

The ViSQOL model path can be changed with `VISQOL_MODEL=/path/to/model.tflite`.

## Usage

```
make                                     # clone/pull Codec2-mod branches and build
make run                                 # default: main branch, 20 files
make run MOD=split-no-doubles N=all      # use a different branch, all files
make run N=50 SEED=3 JOBS=4              # 50 files, selection seed 3, 4 parallel jobs
```

`make` always pulls the latest version of each branch. Files are processed in parallel, one per CPU core by default. It is recommended, as ViSQOL is CPU-heavy.

## Output

Each file is encoded with both codecs and decoded with both, and every combination is scored against the original with ViSQOL (resampled to 16 kHz).

| Column                                     | Meaning                                                                         |
|--------------------------------------------|---------------------------------------------------------------------------------|
| `ref-ref`, `mod-mod`, `ref-mod`, `mod-ref` | MOS for encoder-decoder pairs (`ref-mod` = vanilla encoder, Codec2-mod decoder) |
| `dMOS`                                     | `mod-mod − ref-ref`: total change                                               |
| `dMOS-dec`                                 | `ref-mod − ref-ref`: decoder effect (same vanilla bits)                         |
| `dMOS-enc`                                 | `mod-ref − ref-ref`: encoder effect (same vanilla decoder)                      |
| `Bit-diff`                                 | Mismatched bits between the two bitstreams (`-` = identical)                    |

All deltas are relative to vanilla Codec2: green = better, red = worse. Per-file results are saved to `work/results.csv`, and errors to `work/errors.log`.

## Cleaning up

```
make clean       # clean up binaries only
make distclean   # also clean test results and Codec2-mod checkouts
```
