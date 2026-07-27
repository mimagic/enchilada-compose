# Enchilada — Self-Host

**Your AI Memory, hosted in the EU.** This repo is the deployment recipe for
Enchilada — a docker-compose stack that runs the entire product from the
public [`enchilada-core-*`](https://github.com/orgs/mimagic/packages?repo_name=enchilada)
images on a single host. No login, no build, no source clone needed.

## One command

```bash
git clone https://github.com/mimagic/enchilada-compose.git
cd enchilada-compose
cp .env.example .env       # optional — defaults work for a local trial
docker compose up -d
```

Open <http://localhost:3100> — the API + Console. Sign in creates the local
admin on first use.

## What's in the stack

| Service    | Image                                  | Purpose                                                         |
|------------|----------------------------------------|-----------------------------------------------------------------|
| `api`      | `ghcr.io/mimagic/enchilada-core-api`   | HTTP API + Console SPA + auth (self-host edition, no Clerk)     |
| `worker`   | `ghcr.io/mimagic/enchilada-core-api`   | BullMQ background ingest worker (same image, different command) |
| `rag`      | `ghcr.io/mimagic/enchilada-core-rag`   | Python RAG engine — LightRAG + pgvector-backed graph & vectors  |
| `postgres` | `pgvector/pgvector:pg16`               | One container, two databases (proxy state + LightRAG)           |
| `redis`    | `redis:7-alpine`                       | BullMQ queue backend                                            |
| `minio`    | `minio/minio:latest`                   | S3-compatible blob store for uploaded documents                 |

All Enchilada-owned images are **public**; no `docker login` required.

## Optional profiles

Two features are opt-in so the base stack stays lean:

**Advanced document parser** — Docling with OCR + Office support. ~2 GB image;
needed for scanned PDFs and Word/Excel/PowerPoint. Skip if you only ingest
text / markdown.

```bash
docker compose --profile parser up -d
```

**Bundled local Ollama** — a small local LLM + embedding model so you can try
Enchilada without a paid API key. `qwen2.5:7b` + `nomic-embed-text` are
pulled on first boot; CPU is slow but works for a trial.

```bash
docker compose --profile ollama up -d
```

You can also combine profiles:
`docker compose --profile parser --profile ollama up -d`.


## GPU support for Ollama (vision + heavier chat models)

The bundled Ollama runs on CPU by default. For vision models like
`qwen2.5vl:7b` (recommended for figure captioning during ingest) or heavier
13B+ chat models, CPU is impractical. Enable NVIDIA GPU passthrough with the
included overlay:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.gpu.yml \
  --profile ollama up -d
```

The overlay does two things:

1. Grants the `ollama` service NVIDIA GPU access
   (`deploy.resources.reservations.devices` with `driver: nvidia`).
2. Adds a second one-shot `ollama-pull-vision` that fetches the vision model
   (`qwen2.5vl:7b` by default; override with `OLLAMA_VISION_MODEL=…` in your
   `.env`) once the base chat + embedding models are in — because a VL model
   is only practical when a GPU is present.

Wire the vision role in **Settings → Models → Vision** after first boot:

```
Base URL: http://ollama:11434/v1
Model:    qwen2.5vl:7b
```

### Prerequisites

- **NVIDIA GPU** with a recent CUDA-capable driver — `nvidia-smi` on the host
  should list it.
- **`nvidia-container-toolkit`** installed AND registered as a docker runtime.
  Quick check:

  ```bash
  docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
  ```

  If that lists your GPU, you're set. If it fails with
  `could not select device driver "" with capabilities: [[gpu]]`, install the
  toolkit: <https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html>

### VRAM sizing

| Model                    | ≈ VRAM   | Runs on            |
|--------------------------|----------|--------------------|
| `qwen2.5vl:3b`           | ~4 GB    | 6 GB card and up   |
| `qwen2.5vl:7b` (default) | ~7 GB    | 8 GB card and up   |
| `llama3.2-vision:11b`    | ~10 GB   | 12 GB card and up  |
| `qwen2.5vl:32b`          | ~24 GB   | 24 GB card and up  |

Below 6 GB VRAM: skip GPU-Ollama for vision and BYOK a cloud vision key
(Mistral Pixtral EU, GPT-4o, Gemini) in Settings → Models → Vision instead.

### Verify GPU is really reaching Ollama

After the stack is up, confirm the container sees the GPU:

```bash
docker compose exec ollama nvidia-smi
```

You should see a table with your GPU, driver version, and (once a model is
loaded) a `python` or `ollama` process using VRAM. If the command errors with
`nvidia-smi: command not found`, the container itself doesn't have the
NVIDIA runtime — re-check the toolkit install above.

### Troubleshooting

- **`Error response from daemon: could not select device driver "nvidia" …`**
  → `nvidia-container-toolkit` is missing or not registered as a docker
  runtime. Install it (see Prerequisites) and restart the docker daemon:
  `sudo systemctl restart docker`.
- **`nvidia-smi` inside the container returns nothing** → the runtime is
  registered but the container didn't request GPU access. Confirm you
  passed `-f docker-compose.gpu.yml` on the `up` command, and verify:
  `docker compose -f docker-compose.yml -f docker-compose.gpu.yml config
  | grep -A5 'ollama:$' | grep nvidia`.
- **Model loads but inference is CPU-slow** → the model file may not fit
  VRAM and is running partly on CPU. Check GPU utilisation while a query
  runs: `watch -n1 docker compose exec ollama nvidia-smi`. If GPU usage
  stays near 0%, pick a smaller model (see VRAM sizing).
- **AMD (ROCm) or Apple Silicon** → this overlay is NVIDIA-only. For ROCm
  swap the image to `ollama/ollama:rocm` and pass `/dev/kfd` + `/dev/dri`
  instead of the nvidia driver. Apple Silicon: Docker cannot expose the
  Metal GPU to a Linux container at all — run Ollama natively on macOS and
  point `X-Vision-Base-URL` at your host's `http://host.docker.internal:11434/v1`.
  See [`docs/self-host-vision.md`](docs/self-host-vision.md).

## Configuration

Everything is `.env`. Copy `.env.example` to `.env`; every key has a default
in `docker-compose.yml`. Most people only touch `POSTGRES_PASSWORD`,
`MINIO_ROOT_PASSWORD`, and the `*_PORT` variables (if the defaults clash).

For vision / figure captioning on scanned plans, configure the "Vision" role
in **Settings → Models** after first boot — BYOK OpenAI / Google Gemini /
Mistral Pixtral (EU) all work.

## Upgrading

```bash
git pull                                     # pull the newest compose recipe
docker compose pull                          # pull the newest image tag
docker compose up -d                         # recreate containers on the new image
```

Read the release notes at
<https://github.com/mimagic/enchilada/releases> before every upgrade;
database migrations run automatically on API start.

## License

This deployment recipe is distributed under the same
**Enchilada Proprietary Source-Available License** as the product itself
(see [LICENSE](LICENSE)). In short: **free for personal / evaluation use;
commercial use → talk to sales.** Redistribution and offering Enchilada as a
hosted service to third parties are not permitted without an agreement.

## Support

- Product source, roadmap, releases: <https://github.com/mimagic/enchilada>
- Deployment issues, questions, requests: file them here.
- Commercial licensing / pilots: reach out via your Enchilada contact.
