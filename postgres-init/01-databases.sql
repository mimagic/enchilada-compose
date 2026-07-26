-- Self-host datastore collapse (plan §3.1b): ONE pgvector image, TWO databases.
--
-- The dev/base stack (infra/docker-compose.yml) runs two separate Postgres
-- containers — `postgres-proxy` (Enchilada proxy state: accounts, api_keys, …)
-- and `postgres-lightrag` (LightRAG kv/vector/doc_status). They differ ONLY by
-- database name, so the self-host stack folds them into a single
-- `pgvector/pgvector:pg16` container hosting both DBs. No application code
-- change: the API points DATABASE_URL at .../enchilada_proxy and the RAG service
-- points its DATABASE_URL at .../enchilada_lightrag on the same host.
--
-- POSTGRES_DB=enchilada_proxy is created by the image's own entrypoint; this
-- script (mounted into /docker-entrypoint-initdb.d, runs once on first init as
-- the superuser) creates the SECOND database and enables the vector extension
-- in both. LightRAG's PGVectorStorage requires the `vector` extension.

-- Second database for the LightRAG engine store.
CREATE DATABASE enchilada_lightrag;

-- pgvector extension in the proxy DB (harmless if unused there; keeps both DBs
-- symmetric and future-proofs proxy-side embeddings).
\connect enchilada_proxy
CREATE EXTENSION IF NOT EXISTS vector;

-- pgvector extension in the LightRAG DB (REQUIRED — LightRAG stores embeddings
-- via PGVectorStorage).
\connect enchilada_lightrag
CREATE EXTENSION IF NOT EXISTS vector;
