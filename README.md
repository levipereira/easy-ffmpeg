# easy-ffmpeg

A smart CLI wrapper around ffmpeg for video conversion, remuxing, and image sequence encoding. It analyzes your input, picks the best strategy (copy when possible, transcode only when needed), and shows clear progress.

> **New in v0.3.0:** opt-in NVIDIA GPU acceleration (`--gpu`) for **Linux / WSL2 with an NVIDIA GPU**. The CPU and macOS code paths are unchanged — if you don't pass `--gpu`, the CLI behaves the same as previous versions. GPU acceleration requires CUDA + a custom FFmpeg build, packaged via Docker (see [docs/nvidia-acceleration.md](docs/nvidia-acceleration.md)).

## Contents

- [What's new in v0.3.0](#whats-new-in-v030)
- [Headline benchmark (RTX 5080)](#headline-benchmark-rtx-5080)
- [Installation](#installation)
- [Usage](#usage)
- [Documentation](#documentation)
- [Development](#development)
- [Contributing](#contributing)

## What's new in v0.3.0

- **`--gpu`** — opt-in NVIDIA hardware pipeline (NVDEC decode → CUDA filters → NVENC encode)
- **`--gpu-quality fast|balanced|smaller`** — speed/size trade-off for the GPU encode
- **End-to-end GPU pipeline** when possible (frames never leave VRAM); graceful CPU/GPU fallback when a filter requires system memory
- **HDR preservation** — 10-bit + BT.2020 / PQ / HLG metadata propagated through `hevc_nvenc`
- **Auto-deinterlace** via `yadif_cuda` / `yadif` when ffprobe reports an interlaced field order
- **Dockerfile + helper scripts** that compile FFmpeg with full CUDA support so you don't have to

Full writeup: **[docs/nvidia-acceleration.md](docs/nvidia-acceleration.md)**.

## Headline benchmark (RTX 5080)

Source: H.264 1080p movie (1h38m, 5.8 GB) → MP4/HEVC with `--compress`.

| Encode | Time | Output | SSIM |
|---|---:|---:|---:|
| CPU (libx265 `-crf 28 -preset medium`) | 29m48s | 1.0 GB | 0.9426 |
| GPU balanced (default `--gpu`) | **4m50s** | 1.8 GB | **0.9462** |
| GPU smaller (`--gpu-quality smaller`) | 11m19s | **993 MB** | 0.9405 |

In short: **`balanced` is 6.2× faster with slightly higher quality** (at ~1.8× the file size); **`smaller` matches CPU file size with a quality difference below human perception, still 2.6× faster.**

Full benchmark methodology, additional source formats (SDR + HDR clips), and per-generation NVENC/NVDEC capabilities: **[docs/benchmarks.md](docs/benchmarks.md)**.

## Installation

### macOS / Linux without GPU

The simple paths — same as previous versions, no Docker required:

```sh
# macOS
brew install akitaonrails/tap/easy-ffmpeg

# Linux / macOS (binary download)
curl -fsSL https://raw.githubusercontent.com/akitaonrails/easy-ffmpeg/master/install.sh | sh
```

### Linux / WSL2 with NVIDIA GPU — via Docker

```sh
git clone https://github.com/akitaonrails/easy-ffmpeg.git
cd easy-ffmpeg
./install.sh --gpu
```

`install.sh --gpu` checks the prerequisites (Docker, NVIDIA driver, `nvidia-container-toolkit`), builds the CUDA image (10-20 min the first time), and installs the wrapper script as `easy-ffmpeg` so you can use it from anywhere. Run `./install.sh` with no flag to get an interactive prompt that asks CPU vs GPU.

Prerequisites and details (driver version, build options, troubleshooting): **[docs/nvidia-acceleration.md](docs/nvidia-acceleration.md#quick-start)**.

### Build the CPU-only Crystal binary from source

```sh
git clone https://github.com/akitaonrails/easy-ffmpeg.git
cd easy-ffmpeg
crystal build src/easy_ffmpeg_cli.cr -o bin/easy-ffmpeg --release
```

Copy `bin/easy-ffmpeg` somewhere in your `$PATH`.

### Uninstall

```sh
./uninstall.sh           # auto-detects CPU binary vs GPU wrapper, asks before removing
./uninstall.sh --yes     # skip confirmations
```

For the GPU install, the script also offers to delete the `easy-ffmpeg:cuda` Docker image (~4 GB) — declining keeps the image so you can reinstall later without rebuilding.

## Usage

```
easy-ffmpeg <input> <format> [options]
```

- `input` — a video file or a directory of images
- `format` — output format: `mp4`, `mkv`, `mov`, `webm`, `avi`, `ts`, or `gif` (GIF for image sequences only)

### Video conversion

```sh
easy-ffmpeg movie.mkv mp4              # remux only (no re-encoding, very fast)
easy-ffmpeg movie.mkv mp4 --web        # H.264 + AAC, faststart
easy-ffmpeg movie.mkv mp4 --compress   # H.265, CRF 28
easy-ffmpeg movie.mkv mp4 --mobile     # H.264 720p, AAC stereo
easy-ffmpeg movie.mkv mp4 --streaming  # H.265, Netflix/YouTube-like
```

### Trimming

```sh
easy-ffmpeg movie.mkv mp4 --start 1:30 --duration 90        # 90s clip starting at 1:30
easy-ffmpeg movie.mkv mp4 --start 10:00 --end 15:00         # absolute trim
easy-ffmpeg movie.mkv mp4 --mobile --start 0:30 --end 2:00 -o clip.mp4
```

Time formats: `90`, `1:31`, `1:31.500`, `1:02:30`, `1:02:30.5`.

### Scaling & aspect ratio

```sh
easy-ffmpeg movie.mkv mp4 --scale hd                  # 720p
easy-ffmpeg movie.mkv mp4 --scale 1080p               # same as fullhd
easy-ffmpeg movie.mkv mp4 --aspect wide               # pad to 16:9 (black bars)
easy-ffmpeg movie.mkv mp4 --aspect square --crop      # crop to square
easy-ffmpeg movie.mkv mp4 --scale fullhd --aspect wide
```

Scale presets: `4k` / `2160p`, `2k` / `1440p`, `fullhd` / `1080p`, `hd` / `720p`, `retro` / `480p`, `icon` (downscale only).
Aspect presets: `wide` (16:9), `4:3`, `8:7`, `square` (1:1), `tiktok` (9:16). `--crop` to crop instead of pad.

### GPU acceleration

Add `--gpu` to any transcode that maps to H.264, H.265, or AV1:

```sh
easy-ffmpeg movie.mkv mp4 --compress --gpu                          # default (balanced)
easy-ffmpeg movie.mkv mp4 --compress --gpu --gpu-quality fast       # ~2-3× faster, larger
easy-ffmpeg movie.mkv mp4 --compress --gpu --gpu-quality smaller    # similar size to CPU
```

Through the Docker wrapper (no `docker run` boilerplate):

```sh
easy-ffmpeg -i movie.mkv -f mp4 --compress --gpu
```

The wrapper requires `-i <input>` and `-f <format>` (positional `<format>` also works for backwards compatibility).

Pipeline tiers, quality auto-tuning, HDR preservation, auto-deinterlace: **[docs/nvidia-acceleration.md](docs/nvidia-acceleration.md)**.

### 360 / spherical video (`--vr360`)

Convert dual-fisheye footage (Samsung Gear 360, Insta360, Ricoh Theta, etc.) to standard equirectangular MP4, or re-encode already-stitched 360 video. Requires `--gpu`.

```sh
# Dual-fisheye → equirectangular MP4 in one pass (most common)
easy-ffmpeg raw360.mp4 mp4 --vr360 full --gpu

# Stitch only, save high-bitrate intermediate for later editing
easy-ffmpeg raw360.mp4 mp4 --vr360 stitch --gpu

# Input is already equirectangular — just re-encode (e.g. Samsung "Stitch" files)
easy-ffmpeg stitched360.mp4 mp4 --vr360 encode --gpu

# Single-lens (single fisheye) source with custom FOV
easy-ffmpeg single_lens.mp4 mp4 --vr360 full --gpu --vr360-input fisheye --vr360-fov 210

# Downscale 4K equirect to 1080p equirect while re-encoding
easy-ffmpeg stitched4k.mp4 mp4 --vr360 encode --gpu --scale 1080p
```

Output resolution defaults to the input resolution; pass `--scale` to downsample. The encoder is `h264_nvenc` at VBR with a bitrate target that scales with input width (50 Mbps for ≥4K, 25 Mbps for ≥2K, 12 Mbps otherwise). `stitch` mode doubles the bitrate since the file is intended as an intermediate.

Full writeup: **[docs/vr360.md](docs/vr360.md)**.

### Image sequences

```sh
easy-ffmpeg /path/to/frames/ mp4                # video from PNG/JPG/BMP/TIFF/WebP
easy-ffmpeg /path/to/frames/ gif --fps 15       # animated GIF at 15 fps
easy-ffmpeg /path/to/frames/ mp4 --compress    # with preset
```

Default frame rate is 24 fps for video, 10 fps for GIF. Auto-detects sequential numbering.

### Flags

| Flag | Description |
|---|---|
| `--scale NAME` | Scale resolution: `4k`/`2160p`, `2k`/`1440p`, `fullhd`/`1080p`, `hd`/`720p`, `retro`/`480p`, `icon` |
| `--aspect RATIO` | Aspect ratio: `wide`, `4:3`, `8:7`, `square`, `tiktok` |
| `--crop` | Crop to aspect ratio instead of padding |
| `--gpu` | Use NVIDIA NVENC for H.264/H.265/AV1 transcodes |
| `--gpu-quality MODE` | NVENC mode: `fast` \| `balanced` (default) \| `smaller` |
| `--vr360 MODE` | 360 video pipeline: `full` \| `stitch` \| `encode` (requires `--gpu`) |
| `--vr360-input TYPE` | Input projection: `dfisheye`/`dual` (default) \| `fisheye`/`single` |
| `--vr360-profile NAME` | Camera profile: `generic` (default) \| `gear360` (FOV 193) |
| `--vr360-fov DEG` | Fisheye FOV in degrees (overrides profile default) |
| `--vr360-yaw DEG` | Per-camera output yaw correction (default: 0) |
| `--vr360-pitch DEG` | Per-camera output pitch correction (default: 0) |
| `--vr360-roll DEG` | Per-camera output roll correction (default: 0) |
| `--fps N` | Frame rate for image sequences (1-120) |
| `-o PATH` | Custom output file path |
| `--dry-run` | Print the ffmpeg command without executing |
| `--force` | Overwrite output file if it exists |
| `--no-subs` | Drop all subtitle tracks |
| `-h, --help` | Show help |
| `-v, --version` | Show version |

## Documentation

- **[docs/nvidia-acceleration.md](docs/nvidia-acceleration.md)** — full GPU writeup: rationale, Docker setup, pipeline internals, quality modes, HDR, troubleshooting
- **[docs/benchmarks.md](docs/benchmarks.md)** — full benchmark detail, methodology, per-generation NVENC/NVDEC capabilities

## How It Works

1. **Analyze** — probes the input with ffprobe to identify all streams
2. **Plan** — decides per-stream: copy (compatible), transcode (incompatible), or drop
3. **Execute** — runs ffmpeg with progress tracking
4. **Report** — shows output file size, compression ratio, and elapsed time

## Development

```sh
crystal build src/easy_ffmpeg_cli.cr -o bin/easy-ffmpeg
crystal spec
```

To work on the GPU code path without a local CUDA install, see the [Development section](docs/nvidia-acceleration.md#development) of the GPU docs.

## Contributing

1. Fork it (<https://github.com/akitaonrails/easy-ffmpeg/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [AkitaOnRails](https://github.com/akitaonrails) — creator and maintainer
