# Runbook — repairing workspaces with silently empty extractions

**Who needs this:** anyone who ran the deterministic extractor (`RAG_EXTRACT=1`,
`--profile deterministic`) on a CPU-only host with Enchilada **v0.19.0 or older**
and ended up with documents that report *completed* but whose knowledge graph is
thin or empty.

**Time:** ~10 minutes of typing, plus the re-ingest, which on a NAS-class CPU is
the long part (see [Hardware sizing](../../README.md#hardware-sizing--throughput)).

---

## 1. What went wrong

Up to and including v0.19.0 the RAG engine treated *every* extractor failure —
client timeout, connection refused, the sidecar still loading its model — as
"this chunk contains nothing". It emitted the empty-extraction sentinel
`<|COMPLETE|>` and the ingest carried on and reported success.

Two things then made that permanent rather than transient:

* LightRAG caches extraction results, and its only guard against caching a
  failure is `if not content: return`. `<|COMPLETE|>` is a non-empty string, so
  the failed extraction was written into `lightrag_llm_cache` as a perfectly
  normal success.
* Enchilada deliberately pins `delete_llm_cache=false` on document delete (so a
  re-ingest of identical text replays the same extraction instead of re-rolling
  a stochastic LLM). The side effect: **deleting and re-uploading the document
  does not clear the poisoned cache entry** — the re-ingest replays the same
  empty result. Re-embedding does not touch it either.

So there is no action in the console that repairs this. It has to be done in
SQL. The fix in the product is that these failures now raise instead of
returning empty (nothing is written to the cache when the call raises), but that
does not retroactively clean a cache that already holds the empty results.

## 2. Am I affected?

Symptoms: ingest finishes green, the document is listed, and the graph has few
or no entities for it. In `docker compose logs rag` you would have seen lines
like `extractor tier ON but produced no block for this chunk`.

Open a psql shell on the LightRAG database:

```bash
docker compose exec postgres psql -U enchilada -d enchilada_lightrag
```

Count the empty extraction results per workspace:

```sql
SELECT workspace,
       count(*) FILTER (WHERE btrim(return_value) = '<|COMPLETE|>') AS empty_results,
       count(*)                                                    AS total_extracts,
       round(100.0 * count(*) FILTER (WHERE btrim(return_value) = '<|COMPLETE|>')
             / nullif(count(*), 0), 1)                             AS pct_empty
FROM lightrag_llm_cache
WHERE cache_type = 'extract'
GROUP BY workspace
ORDER BY empty_results DESC;
```

A few percent is normal — a chunk that genuinely contains no entities produces
the same sentinel. Double-digit percentages on prose-heavy documents are the
signature of the failure above.

`workspace` here is the **RAG workspace id**, not the display name you see in
the console. Map them with:

```bash
docker compose exec postgres psql -U enchilada -d enchilada_proxy \
  -c "SELECT name, rag_workspace FROM workspaces ORDER BY name;"
```

## 3. Fix the cause BEFORE you purge

Purging the cache while the host is still timing out just re-poisons it, more
slowly. In order:

1. **Upgrade** to a release newer than v0.19.0 if one is available (`ENCHILADA_TAG`
   in `.env`, then `docker compose pull && docker compose up -d`). From that
   release on, an extractor failure fails the document loudly instead of writing
   an empty graph.
2. **Raise the per-chunk timeout and serialise extraction** in `.env`:

   ```dotenv
   RAG_EXTRACT_TIMEOUT_S=600     # the old default was 120s — far too tight on CPU
   RAG_EXTRACT_MAX_RETRIES=1
   EXTRACT_MAX_ASYNC_LLM=1       # one chunk at a time; 4 in flight all time out together
   ```

   Keep `(1 + retries) × timeout + backoff` under `LLM_TIMEOUT × 2`, or LightRAG's
   own worker ceiling fires first and you are back to a failure it cannot explain.
   If a single chunk on your host really needs more than 600s, raise `LLM_TIMEOUT`
   in the same step.

3. **Wait for the extractor to be healthy** before ingesting anything. The fp32
   model load takes minutes on a NAS:

   ```bash
   docker compose ps extractor     # must say (healthy), not (health: starting)
   ```

   From the release after v0.19.0 the RAG engine waits out a *bounded* part of
   that window itself, so the first ingest you start right after
   `docker compose up -d` can simply sit there for minutes with no visible
   progress — that is the extractor loading its weights, not a hang. The wait is
   bounded on purpose, so a model load slower than the bound still ends in an
   extractor error rather than an indefinite stall. A document that fails that
   way is a *transient* failure, not a poisoned cache entry: once
   `docker compose ps extractor` reports `(healthy)`, re-upload it once and it
   will go through. Only failures that persist with a healthy extractor belong
   in the purge below.

4. Re-create the stack so the new values are in the containers:
   `docker compose up -d`.

## 4. Purge the poisoned cache entries

⚠️ **Read this first.**

* This deletes **cache rows only**. It never touches your documents, your graph
  or your vectors. The worst case is that some chunks get extracted again.
* The predicate cannot distinguish "extraction failed" from "this chunk really
  had no entities" — both look identical. Deleting both is safe; the cost is
  re-decoding those chunks on the next ingest, which on a slow host is real time.
* Take a backup first if this is a machine you care about:

  ```bash
  docker compose exec postgres pg_dump -U enchilada -t lightrag_llm_cache \
      enchilada_lightrag > llm_cache_backup.sql
  ```

One workspace at a time (recommended — substitute the `rag_workspace` value from
step 2):

```sql
BEGIN;

-- See exactly what you are about to remove.
SELECT count(*) FROM lightrag_llm_cache
WHERE workspace = 'YOUR_RAG_WORKSPACE'
  AND cache_type = 'extract'
  AND btrim(return_value) = '<|COMPLETE|>';

DELETE FROM lightrag_llm_cache
WHERE workspace = 'YOUR_RAG_WORKSPACE'
  AND cache_type = 'extract'
  AND btrim(return_value) = '<|COMPLETE|>';

COMMIT;
```

Every workspace at once, if you would rather not repeat it:

```sql
DELETE FROM lightrag_llm_cache
WHERE cache_type = 'extract'
  AND btrim(return_value) = '<|COMPLETE|>';
```

## 5. Re-ingest the affected documents

Purging the cache does not by itself rebuild the graph — the documents have to
go through extraction again. With the cache clean, that now really re-extracts.

**Use re-ingest, not delete + re-upload.** Re-ingest replays the stored file with
`replace=true`, which purges the document's RAG state first — so it works whether
the document ended up `completed` or `failed`, and it needs no local copy of the
file. (Re-*uploading* the same document without deleting it is filtered out at
enqueue and may do nothing at all, which is why it is not the instruction here.)

In the console: **Library → the document's ⋯ menu → Re-ingest** (the same button
labelled *Retry* on a failed document). Or over the API:

```bash
# 1. list documents and note their rag_doc_id
curl -s -H "Authorization: Bearer $ENCH_API_KEY" \
     http://localhost:3100/api/v1/documents | jq '.documents[] | {rag_doc_id, filename, status}'

# 2. re-ingest one. Note: the parameter is the rag_doc_id, NOT the document's
#    UUID — the UUID does not match and you get a 404 here (and, on the DELETE
#    endpoint, a misleading HTTP 200 {"status":"not_found"} that deletes nothing).
curl -s -X POST -H "Authorization: Bearer $ENCH_API_KEY" \
     "http://localhost:3100/api/v1/documents/reingest?doc_id=doc-abc123..."
# → 202 {"status":"queued","doc_id":"doc-abc123...","job_id":"..."}
```

Add `-H "X-Workspace: <workspace-id>"` to each call if your API key covers more
than one workspace.

A `422` means that document has no stored file (an early text-only ingest) — for
those, delete it and upload the content again:

```bash
curl -s -X DELETE -H "Authorization: Bearer $ENCH_API_KEY" \
     "http://localhost:3100/api/v1/documents?doc_id=doc-abc123..."
```

Re-ingest **one document first** and check its graph before queueing the rest.
On a slow host a full corpus is hours to days, and you want to know the fix took
before you spend that.

If you would rather have delete + re-upload clear the extraction cache for you in
future, set this in `.env` and restart:

```dotenv
DELETE_LLM_CACHE_ON_DOC_DELETE=true
```

That is safe **specifically when `RAG_EXTRACT=1`**: the deterministic extractor
produces the same block for the same chunk every time, so there is nothing
stochastic to preserve. With the LLM extraction path (`RAG_EXTRACT=0`) leave it
`false` — the cache is what keeps repeated ingests of the same text stable there.

## 6. Verify

```sql
-- should be 0 for the workspaces you purged
SELECT count(*) FROM lightrag_llm_cache
WHERE cache_type = 'extract' AND btrim(return_value) = '<|COMPLETE|>';
```

```bash
# and no new silent holes during the re-ingest
docker compose logs rag | grep -c "produced no block"
```

Then open the workspace's graph in the console: the re-ingested documents should
now show entities and relations. Expect the re-ingest to take a while — on a
NAS-class CPU each chunk is a separate multi-second-to-minutes decode.
