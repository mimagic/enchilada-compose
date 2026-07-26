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
