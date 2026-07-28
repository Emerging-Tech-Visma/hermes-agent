# External Knowledge via the ETAP "Database" MCP Server

**How Hermes reads a knowledge base that lives in another system — the Visma Agentic
Platform (ETAP) — instead of building its own.** This is the *reuse* path (Option A);
the *build-your-own* path is [KNOWLEDGE-DATASTORE.md](KNOWLEDGE-DATASTORE.md) (Vertex AI
Search, ADC-auth). Verified working 2026-07-20.

## What it is

ETAP calls them **"Databases"** in the UI; in ETAP's codebase they are **Knowledge Graphs**
(graph or vector kind) — workspace-scoped, backed by Cloud SQL Postgres (one schema per
graph). **You never touch Postgres.** Each database is exposed as an **in-app MCP server**
that any external MCP client — including Hermes — can query with a bearer token. That is the
*intended* external-access path (the endpoint's own docstring: the URL is built from the
public origin "so the Anthropic agent can reach it from outside").

So Hermes gets the *same* curated, Drive-synced, PII-masked, ontology-aware knowledge as
ETAP's own agents, with **one source of truth and zero data duplication**.

## Canonical facts (current link)

| Thing | Value |
|---|---|
| ETAP database ("graph") name / id | `Vismo` / `gulizayy0i3tcaulm` |
| ETAP workspace id | `zCfVDRmJebtNGCkGgtzz` |
| Platform host (europe-west4, EU) | `vap-api--test-vstdt-cm.europe-west4.hosted.app` |
| MCP endpoint | `POST https://<host>/api/mcp/kg/<graphId>` |
| Transport | MCP Streamable HTTP / JSON-RPC 2.0 (single POST; no SSE stream) |
| Auth | `Authorization: Bearer kgmcp_…` (per-graph token) |
| Tools (graph kind, all read-only) | `kg_semantic_search`, `kg_graph_neighborhood`, `kg_list_themes`, `kg_ontology`, `kg_resolution_history` (a *vector*-kind DB exposes semantic search only) |

> Region note: the ETAP KG runs in **europe-west4** (Netherlands, EU member) — actually a
> stricter residency posture than Hermes' own chat model (now `gemini-3.6-flash` @ `global` —
> an accepted EU-residency exception; see AGENTS.md). The KG stays EU-region-pinned regardless.

## Get the token (ETAP side)

The token is **show-once** — stored only as a salted SHA-256 hash, never recoverable.

1. In ETAP open the **Databases** panel for the `Vismo` graph. Minting is *agent/binding*-level
   (the modal is titled *Databases — {agent}*), so the graph must be **attached to an agent
   binding** in that workspace first (**Attach**).
2. Click **Rotate token**. The response shows, once: `token` (`kgmcp_…`) and the exact
   `mcpServerUrl`. Copy both immediately.

Rotating/Detaching invalidates the previous token instantly.

## Wire it into Hermes (dashboard → ADD MCP SERVER)

Dashboard **MCP → Add MCP server**:

| Field | Value |
|---|---|
| NAME | `etap-vismo-kg` |
| TRANSPORT | `HTTP/SSE` |
| URL | the `mcpServerUrl` from Rotate (e.g. `https://vap-api--test-vstdt-cm.europe-west4.hosted.app/api/mcp/kg/gulizayy0i3tcaulm`) |
| AUTHENTICATION | `Bearer token` |
| BEARER TOKEN | the raw `kgmcp_…` — **no** `Bearer ` prefix |

The dialog stores the token in the **profile's `.env`**; `config.yaml` keeps only an
env-var reference — so config stays commit-safe, the secret does not.

Equivalent `config.yaml` shape (if editing by hand instead of the dialog):

```yaml
mcp_servers:
  etap-vismo-kg:
    url: "https://vap-api--test-vstdt-cm.europe-west4.hosted.app/api/mcp/kg/gulizayy0i3tcaulm"
    headers:
      Authorization: "Bearer ${ETAP_VISMO_KG_TOKEN}"   # value lives in .env
    enabled: true
    timeout: 120
```

## Verify

After adding, the server should list its tools (`kg_semantic_search`, …). Then ask the agent
something that forces a lookup ("search the etap-vismo-kg database for …") and confirm it
returns grounded results.

## Gotchas (don't rediscover these)

- **Double `Bearer` → 401.** AUTHENTICATION=`Bearer token` makes the client add the scheme, so
  paste only `kgmcp_…`. Pasting `Bearer kgmcp_…` sends `Authorization: Bearer Bearer …`.
- **Rotate/Detach in ETAP silently breaks Hermes.** The rotate fan-out refreshes ETAP's *own*
  bindings, **not** Hermes — Hermes starts getting 401s until you re-paste the new token. If
  someone detaches the graph, the token hash is deleted and the link is dead. Treat any burst
  of MCP 401s as "someone rotated/detached in ETAP."
- **Token is show-once + unrecoverable.** Lost it → Rotate again (which invalidates the old one).
- **Read-only, PII-masked, single-graph, workspace-scoped.** Low blast radius if leaked, but
  it is still a long-lived credential — keep it in `.env`, never in `config.yaml` or git.
- **It's not a raw DB.** No SQL, no writes — only the read-only KG tools above. For write access
  or a different corpus, build your own store ([KNOWLEDGE-DATASTORE.md](KNOWLEDGE-DATASTORE.md)).

## When to prefer build-your-own instead

Reuse (this doc) wins for a shared, already-curated, graph-shaped corpus. Build a Vertex AI
Search datastore instead when you want Hermes **decoupled** from ETAP's lifecycle/token, ADC
(key-free) auth, or the knowledge is plain-doc/URL search rather than a knowledge graph.
