# The deterministic knowledge extractor

`RAG_EXTRACT=1` + `--profile deterministic` replaces the LLM as the source of
entities and relations with a fine-tuned model that runs **inside your stack**,
single-threaded on CPU with greedy decode. That is what makes *same document →
same graph* true: no sampling, no temperature, no provider, no network call.

It is also the single most expensive thing in the product to run. This page is
the operational half of that promise: what it costs, how to size it, and what
changes the answer.

---

## What determinism does and does not promise

**It holds** for one deployment: one image, one CPU architecture, one set of the
knobs below. Ingest the same document twice and you get a byte-identical graph.

**It does not mean** two different machines agree. Each of the following defines
a *new* reproducible hash — all of them are legitimate configurations, none of
them is bit-compatible with the others:

| Change | Effect |
|---|---|
| `EXTRACTOR_IMAGE` fp32 → int8 | different numerics → different graph |
| a different CPU ISA (AVX2 vs AVX-512 vs aarch64) | a greedy argmax near a tie can flip |
| `EXTRACT_MAX_NEW_TOKENS` changed | different decode cap → different block |
| `EXTRACT_TORCH_THREADS` > 1 | different FP reduction order inside a matmul |
| `RAG_CHUNK_STRATEGY` / `RAG_CHUNK_TOKEN_SIZE` | different chunk boundaries |

Two of those are fenced in code rather than left to discipline:
`EXTRACT_TORCH_THREADS > 1` is refused unless you also set
`EXTRACT_ALLOW_NONDETERMINISTIC=1`, and chunks are never batched into one forward
pass (padding changes the matmul shapes, and batch composition would depend on
arrival timing — the graph would depend on who your batch-mates were).

**Pick one image and stay on it.** In particular, never run a mixed pool: if you
scale to several replicas, every replica must be the same image on the same kind
of CPU, or the graph starts depending on which one answered.

## Three ways to deploy it

### 1. In-stack (the default)

```bash
RAG_EXTRACT=1 docker compose --profile deterministic up -d
```

The sidecar shares the host with everything else. Simple, sovereign, and slow on
a NAS. ~4.5 GB image, ~7 GB resident.

Before your first ingest, wait for the model to load:

```bash
docker compose ps extractor      # must say (healthy)
```

Nothing in the compose file makes an ingest wait for this. Ingesting during the
model load is a classic way to lose a document's chunks.

### 2. Remote extractor (the answer for a large corpus)

Point the engine at an extractor running on a machine that actually has memory
bandwidth:

```dotenv
RAG_EXTRACT=1
RAG_EXTRACT_URL=http://big-box:9640/extract
```

and start the stack **without** `--profile deterministic` (no local sidecar). On
the strong box, run the same image:

```bash
# bind to the PRIVATE interface, not 0.0.0.0 — see the warning below
docker run -d --name enchilada-extractor \
  -p 10.0.0.5:9640:9640 \
  ghcr.io/mimagic/enchilada-core-extractor:v0.19.0
```

> ⚠️ **`/extract` has no authentication of any kind.** There is no token, no
> mTLS, no allowlist — anyone who can reach that port can use your extractor and
> read the chunks they submit. Treat this mode as **same host or a private
> network you fully control**: a VLAN you own, or a Tailscale/WireGuard address.
> Never expose port 9640 to the internet, and do not put it behind a plain
> reverse proxy and call it done.

Determinism caveat: a remote box is only bit-compatible with your local one if it
is the same image **and** the same CPU architecture. Verify before you rely on
it — ingest the same document in both places and compare the graph.

### 3. int8 — faster, and not recommended for German

The int8 build (`EXTRACTOR_IMAGE=ghcr.io/mimagic/enchilada-core-extractor-int8`)
is ~4x faster on the same CPU. It is also measurably worse on the corpora most
self-hosters have: on German text it produced **25% fewer entities**, truncated
identifiers mid-token (`RAG_CHUNK_TO`, `RIG_ EXTRACT`), mangled names
(`llama.cpp Server` → `sta.cpp Server`) and mutated the predicate vocabulary.

If your corpus is English prose it may be a reasonable trade. If it is German, or
dense in identifiers, filenames, URLs or product names, it is not — use remote
extraction for speed instead. Either way it is a different reproducible hash, so
switching re-writes every graph you rebuild afterwards.

## The knobs that matter

| Variable | Where | Default | What it does |
|---|---|---|---|
| `RAG_EXTRACT_TIMEOUT_S` | rag | `600` | Per-chunk client timeout. |
| `RAG_EXTRACT_MAX_RETRIES` | rag | `1` | Retries after the first attempt, exponential backoff, clamped 0–3. |
| `RAG_EXTRACT_ON_FAILURE` | rag | `fail` | `fail` = a sidecar failure fails the document; `empty` = the old best-effort behaviour. |
| `EXTRACT_MAX_ASYNC_LLM` | rag | `1` | Chunks extracted concurrently. |
| `EXTRACT_CONCURRENCY` | extractor | `auto` | Requests decoded at once; `auto` = clamp(CPU quota, 1, 4). |
| `EXTRACT_QUEUE_MAX` | extractor | `auto` (= 2× concurrency) | Queue depth before the server answers 503 + `Retry-After`. |
| `EXTRACT_DEADLINE_S` | extractor | derived | Absolute per-request deadline; set it to `RAG_EXTRACT_TIMEOUT_S` on a uniformly slow host. |
| `EXTRACT_MAX_NEW_TOKENS` | extractor | `512` | Decode cap. **Do not raise it** — see below. |
| `EXTRACT_TORCH_THREADS` | extractor | `1` | Determinism fence. Refused above 1 without the opt-out. |
| `EXTRACTOR_MEM_LIMIT` | extractor | `10g` | Bounds an over-set concurrency to an OOM-killed sidecar, not an OOM-killed host. |

The timeout is really a **budget**, and it has a hard upper bound:

```
(1 + RAG_EXTRACT_MAX_RETRIES) × RAG_EXTRACT_TIMEOUT_S + backoff  <  LLM_TIMEOUT × 2
```

`LLM_TIMEOUT × 2` is LightRAG's own per-call worker ceiling. If the budget
breaches it, the worker kills the chunk from a layer that cannot report *why* —
which is exactly the silent failure these settings exist to remove. At the
shipped defaults that is `2 × 600 + ~2s = 1202s` against a `1800s` ceiling. If
your host genuinely needs longer per chunk, raise `LLM_TIMEOUT` in the same step.

Two knobs that look tempting and are not:

* **`EXTRACT_MAX_NEW_TOKENS` higher.** Measured on the same chunk, 512 and 1024
  decode to byte-identical output — the model stops on its own. A bigger cap only
  buys decode time on the rare chunk that degenerates into a repetition loop.
* **`EXTRACT_TORCH_THREADS` higher.** It is the one knob that breaks the product
  promise. Scale `EXTRACT_CONCURRENCY`, or add replicas, or go remote.

`EXTRACT_MAX_ASYNC_LLM` and `EXTRACT_CONCURRENCY` are two halves of one decision
and should move together: the first is how many chunks the engine has in flight,
the second is how many the sidecar will actually decode at once. Raising the
first alone just fills the sidecar's queue.

## Scaling out

The sidecar publishes an ephemeral host port by default, so replicas do not
collide:

```bash
RAG_EXTRACT=1 docker compose --profile deterministic up -d --scale extractor=2
```

Docker's embedded DNS then round-robins the `extractor` name. Two caveats:

* Every replica must be the **same image on the same CPU** (see above).
* A replica costs the **full ~7 GiB** of weights again, while an extra in-flight
  request inside one replica costs about **0.35 GiB** — the weights are shared.
  Raise `EXTRACT_CONCURRENCY` first; add replicas only when you have run out of
  cores or want to spread across machines.

## Related settings

* **The console's "Extraction model" setting is ignored while `RAG_EXTRACT=1`.**
  The deterministic tier is the sole source for a chunk — that is the point — so
  the engine short-circuits before any LLM is reachable. The setting still
  applies when `RAG_EXTRACT=0`.
* **`RAG_CHUNK_STRATEGY=R`** produces ~300-token chunks that fit the extractor's
  384-token input window, so the whole chunk is seen instead of truncated. It is
  the recommended pairing for quality — and it multiplies the number of chunks
  per document, so multiply your ingest-time estimate too.
* **Per-role "thinking" control** needs no code: run two local LLM servers (e.g.
  two `llama.cpp` instances, one with thinking disabled) and point the workspace's
  *extract* role at the non-thinking one in **Settings → Models**, leaving chat on
  the other. Only relevant with `RAG_EXTRACT=0`.

## When it fails

A failed extraction is loud from the release after v0.19.0: the document is
marked failed rather than quietly ingested with an empty graph. On v0.19.0 and
earlier it was silent, and the empty result was cached — if you ran that version
on a slow host, read
[the repair runbook](runbooks/repair-empty-extractions.md).

There is deliberately **no LLM fallback** when the extractor fails. Falling back
would mean the graph silently depends on how loaded your host was, which is
exactly the property this tier exists to remove.
