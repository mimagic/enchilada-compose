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

Three features are opt-in so the base stack stays lean:

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

**Deterministic knowledge extractor** — a self-contained model (baked into the image,
no download, no external call) that makes the knowledge graph **byte-deterministic**:
the same document always produces the same graph, independent of your LLM. Set
`RAG_EXTRACT=1` in `.env` and start with the profile. amd64 image (~4.5 GB, needs
~7 GB RAM; on Apple Silicon it runs under emulation).

```bash
RAG_EXTRACT=1 docker compose --profile deterministic up -d
```

⚠️ This tier is **CPU-bound and slow**: it decodes a model per chunk, measured at
~85 seconds per chunk on a NAS-class CPU. Read
[Hardware sizing](#hardware-sizing--throughput) and
[docs/deterministic-extractor.md](docs/deterministic-extractor.md) before pointing
it at a large corpus, and wait for `docker compose ps extractor` to report
`healthy` before your first ingest — the model load takes minutes. On v0.19.0
nothing blocks an ingest during that window, so a document uploaded into it is
silently extracted as empty. From the release after v0.19.0 the engine waits out
a bounded part of the load window instead, and a document that still fails is
marked failed — retry it once the healthcheck is green.

You can also combine profiles:
`docker compose --profile parser --profile ollama up -d`.

## Hardware sizing & throughput

The base stack is modest: ~4 GB RAM and any 2-core x86-64 host runs it. What
costs real hardware is what you switch on.

| Component | RAM | CPU |
|---|---|---|
| base (api + worker + rag + postgres + redis + minio) | ~4 GB | 2 cores |
| `--profile parser` (Docling) | +6 GB | OCR is CPU-heavy and bursty |
| `--profile ollama` (qwen2.5:7b on CPU) | +6 GB | usable for a trial, slow for a corpus |
| `--profile deterministic` (extractor) | +7 GiB (+~0.35 GiB per concurrent request) | **this is the bottleneck** |

### The physics of the deterministic extractor

Decoding is **memory-bandwidth bound**, not compute bound: the model streams its
entire weight set for every token it emits — about **2.7 GB per token** in fp32
(~1.4 GB in int8). So:

```
tokens/s  ≈  min( memory_bandwidth / bytes_per_token ,  cores × single_core_tokens/s )
```

On a single-channel NAS the first term wins by a wide margin, which is why adding
workers there buys almost nothing. On a dual-channel desktop the second term
starts to matter and concurrency pays off.

| Host class | Memory bandwidth | Per ~300-token chunk | `EXTRACT_CONCURRENCY` | `EXTRACT_MAX_ASYNC_LLM` | Expected gain from concurrency |
|---|---|---|---|---|---|
| NAS-class, single-channel DDR4, 4 cores | ~7 GB/s | **~85 s (measured)** | 1–2 | 1 | ~0% — it is already saturated |
| Desktop, dual-channel DDR4-3200, 6–8 cores | ~35–45 GB/s | ~15–25 s *(estimated)* | 4 | 4 | 3–5× |
| Server, quad/octa-channel, 16+ cores | ~100–200 GB/s | ~5–10 s *(estimated)* | 4 per replica | 4 | scale with replicas |

Only the NAS row is measured (370 ms/token → ~85 s/chunk → ~39 s per KB of source
text, fp32, one worker). Every other cell is derived from the formula above and
should be treated as an estimate until you measure your own box:

```bash
# the sidecar publishes an ephemeral loopback port, so ask compose for it
EXTRACTOR=$(docker compose port extractor 9640)
time curl -s "http://$EXTRACTOR/extract" \
  -H 'content-type: application/json' \
  -d '{"text":"<paste ~300 tokens of your own documents here>"}' > /dev/null
```

### What that means for a real corpus

A 12 MB vault is roughly **11,000 chunks**. At the measured NAS rate that is
about **11 days** of wall clock, and no configuration knob moves that by more
than ~2×. That is not a defect to tune around — it is what a deterministic model
costs on that class of hardware.

If that is your situation, the honest options are, in order:

1. **Run the extractor on a machine with memory bandwidth**
   ([remote extractor mode](docs/deterministic-extractor.md#2-remote-extractor-the-answer-for-a-large-corpus)) —
   the only option that turns days into hours.
2. **Ingest incrementally** — the graph is useful long before the corpus is done.
3. **Leave `RAG_EXTRACT=0`** and use an LLM for extraction. You lose byte-level
   determinism; you keep a working system.

## Network exposure

Only `api` is published on all interfaces. `postgres`, `redis`, `rag`,
`extractor`, `minio` and the bundled `ollama` bind to **127.0.0.1** — none of
them authenticates a caller the way the api does: Redis has no password, the RAG
admin endpoints are protected only by a documented default token, and `/extract`
has no authentication at all.

To reach them from another machine, set `BIND_ADDR` in `.env`:

```dotenv
BIND_ADDR=0.0.0.0
```

Change `POSTGRES_PASSWORD`, `MINIO_ROOT_PASSWORD` and `RAG_ADMIN_TOKEN` first,
and prefer a private network (VLAN, Tailscale, WireGuard) over doing this on an
interface that faces anything untrusted.

## Troubleshooting

**The console loads but every ingest and query fails; `docker compose ps` shows
`rag` restarting.**
`docker compose logs rag | head -30`. If it says
`ENABLE_PIPELINE_TELEMETRY=true requires REDIS_URL`, you are on a compose recipe
older than this one — `git pull` and `docker compose up -d`. (The rest of the
stack comes up regardless, because the worker only waits for the rag container to
*start*, not to become healthy, which is why the failure looks like an app bug
rather than a boot failure.)

**Documents ingest "successfully" but their graph is empty or very thin.**
On v0.19.0 and earlier, an extractor timeout was swallowed and the empty result
was cached, so re-uploading replays it. The fix ships in the release after
v0.19.0 — check `ENCHILADA_TAG` in your `.env`, because a stack still pinned to
v0.19.0 is still on the affected behaviour. See
[docs/runbooks/repair-empty-extractions.md](docs/runbooks/repair-empty-extractions.md)
— it has the diagnostic query, the purge SQL and the re-ingest procedure.

**Queries hang while an ingest is running.**
There is no lock on the query path — what starves a query is queue depth. Lower
`EMBEDDING_FUNC_MAX_ASYNC` (the one queue ingest and query genuinely share) and
`EXTRACT_MAX_ASYNC_LLM`, both in `.env`. The shipped defaults (2 and 1) are
already the conservative ones.

**The "Copy" buttons in the console do nothing.**
Browsers only expose the clipboard API in a *secure context*. Reaching the
console at `http://<nas-ip>:3100` is not one; `http://localhost:3100` is. Either
tunnel (`ssh -L 3100:localhost:3100 user@nas`) or put a TLS-terminating reverse
proxy in front of the api.

**`DELETE /documents/{id}` returns 404.**
That route does not exist. The endpoint is
`DELETE /api/v1/documents?doc_id=<rag_doc_id>` — note the query parameter, and
note that it wants the `rag_doc_id` from `GET /api/v1/documents`, not the
document's UUID (passing the UUID returns HTTP 200 with
`{"status":"not_found"}` and deletes nothing).

**`extractor` never becomes healthy.**
Model load is minutes on a slow CPU — the healthcheck allows 3. If it is killed
instead, it is memory: the fp32 model needs ~7 GB and `EXTRACTOR_MEM_LIMIT`
defaults to `10g`. Check with `docker compose logs extractor` and
`docker inspect --format '{{.State.OOMKilled}}' $(docker compose ps -q extractor)`.


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
  See [self-host-vision.md](https://github.com/mimagic/enchilada/blob/main/docs/self-host-vision.md).

## Configuration

Everything is `.env`. Copy `.env.example` to `.env`; every key has a default
in `docker-compose.yml`. Most people only touch `POSTGRES_PASSWORD`,
`MINIO_ROOT_PASSWORD`, and the `*_PORT` variables (if the defaults clash).

For vision / figure captioning on scanned plans, configure the "Vision" role
in **Settings → Models** after first boot — BYOK OpenAI / Google Gemini /
Mistral Pixtral (EU) all work.

Further reading:

- [docs/deterministic-extractor.md](docs/deterministic-extractor.md) — what the
  determinism promise covers, the three deployment shapes (in-stack, remote,
  int8), and every extractor knob.
- [docs/runbooks/repair-empty-extractions.md](docs/runbooks/repair-empty-extractions.md)
  — repairing workspaces ingested with a too-tight extractor timeout.

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
