# Knowledge Layer v2 — Vertex AI Search (Drive + verified webpages)

**Supersedes Part 3 (rclone mirror) of [SLACK-TEAM-SETUP.md](SLACK-TEAM-SETUP.md), and removes
the need for OpenViking.** Knowledge moves from "files on the VM disk" to a managed,
GCP-native vector datastore that stays linked to Google Drive.

## Revised architecture

```
Slack (Socket Mode)
   → Hermes gateway on hermes-agent VM
       → chat model: Vertex AI  gemini-3.6-flash (region global — EU-residency exception)
       → knowledge:  Vertex AI Search app  ← Drive connector (live index)
                                            ← website data store (verified URLs only)
          (exposed to Hermes via Google's managed Vertex AI Search MCP server)
       → memory: Hermes built-in (MEMORY.md / USER.md) — no external provider
```

What this removes from the v1 install: OpenViking + its venv, the vertex-token-refresh
timer/restart hack, the rclone Drive mirror and sync timer, and the SA key file for rclone.
What stays: the VM, Hermes + gateway, Vertex model config, Slack config, GCS backup
(now backing up `~/.hermes` instead of an OpenViking workspace).

> Naming note: Vertex AI Search is being rebranded **Agent Search** under the
> "Gemini Enterprise Agent Platform" — console pages may show either name.

## 1. Create the datastores (console: AI Applications / Agent Search)

```bash
gcloud services enable discoveryengine.googleapis.com
```

**Drive data store** — in the console create a data store with source **Google Workspace →
Google Drive**, scoped to your knowledge Shared Drive (or specific folders: Marketing,
Finance, Kennet). Requires connecting your Workspace org (you're on visma.com); the index
stays in sync with Drive automatically and honors Drive ACLs.

**Website data store** — create a second data store with source **Website URLs**, listing
only the verified pages, e.g.:

```
include: www.visma.com/products/*
include: docs.example-vendor.com/pricing
exclude: */blog/*
```

Then create one **search app** attached to both data stores.

**Team scoping:** for hard separation between marketing and finance knowledge, create
per-team data stores (or engines) — e.g. `marketing-kb` (Marketing Drive folder + marketing
URLs) and `finance-kb` — so the finance corpus is never queryable from the marketing
channel's tool. One shared app is fine for a pilot; split before real confidential use.

## 2. Wire it to Hermes via MCP

Google provides a managed **Vertex AI Search MCP server**; Hermes supports MCP
(`hermes-agent.nousresearch.com/docs/guides/use-mcp-with-hermes`). Register it under
`mcp_servers` in `config.yaml` (shape per [REFERENCE.md](REFERENCE.md)), authenticated by
the VM's service account (grant it `roles/discoveryengine.viewer` on the project or
per-engine):

```yaml
mcp_servers:
  vertex-ai-search:
    url: "https://<vertex-ai-search-mcp-endpoint>"
    auth: oauth          # OAuth 2.1 PKCE; token persistence + refresh handled
    enabled: true
    timeout: 120
    tools:
      include: []        # optionally whitelist just the search/answer tools
```

```bash
gcloud projects add-iam-policy-binding test-disco-cm \
  --member="serviceAccount:hermes-agent@test-disco-cm.iam.gserviceaccount.com" \
  --role="roles/discoveryengine.viewer"
```

Fallback if the managed MCP server doesn't fit: a ~50-line custom MCP tool calling the
Discovery Engine `search`/`answer` API with ADC — same identity, no keys.

Update the per-channel prompts in `config.yaml` to point at the tool instead of file paths:

```yaml
slack:
  channel_prompts:
    "C0MARKETING": |
      You are the marketing team's assistant. Answer knowledge questions by
      querying the marketing knowledge search tool (Drive docs + approved
      webpages). Cite document titles/URLs. Say so when nothing relevant is found.
    "C0FINANCE": |
      Finance group's assistant. Use the finance knowledge search tool; ground
      every figure in a retrieved document and cite it. Never estimate figures.
```

## 3. Memory: built-in now, Honcho later if needed

- **Now:** `hermes memory off` / `memory.provider` unset — built-in MEMORY.md + USER.md.
  Zero infra, good enough for a pilot.
- **Later, if you want per-user memory** (the bot remembering each teammate's context
  across sessions): **Honcho**, not OpenViking — Hermes' docs position Honcho as best for
  cross-session *user modeling* with distinct peer identities, which matches a multi-user
  team bot. OpenViking's filesystem-hierarchy design targets a single agent's working
  context, and its GCP integration cost us the token-refresh hack. Honcho self-hosted
  (Docker + Postgres/pgvector on the same VM) keeps everything in `test-disco-cm`.

## Why Vertex AI Search beats the rclone/OpenViking approach for this use case

| | rclone mirror + OpenViking (v1) | Vertex AI Search (v2) |
|---|---|---|
| Drive freshness | 15-min sync timer | Managed connector, auto-indexed |
| Vector search over docs | DIY via OpenViking | Managed (chunking, embeddings, ranking) |
| Verified webpages | manual scraping | native website data store with URL allowlist |
| ACLs | none (whatever's on disk) | Drive ACL-aware |
| Moving parts on VM | venv + 3 timers + token hack | one MCP registration |
| Cost | ~$2–8/mo tokens | search pricing ≈ $2–4 per 1k queries + small index cost |

Alternative considered: **Vertex AI RAG Engine** can also import a Drive folder into a
corpus (`rag.import_files(paths=["https://drive.google.com/drive/folders/…"])`) with
managed vector search — more control, but imports are point-in-time (re-import to refresh)
and there's no website source. Pick RAG Engine only if you need custom chunking/embedding
control; otherwise Vertex AI Search is the better default here.

Complement (not a replacement): the bundled **`google-workspace` skill** (Gmail, Calendar,
Drive, Docs, Sheets via gws CLI/Python) lets the agent open/act on a specific Drive doc
live — great for "read this file", but it has no vector index or ACL-scoped retrieval, so
it doesn't replace Vertex AI Search for "search across everything". Bind it per-channel via
`slack.channel_skill_bindings` if the team wants direct Drive actions alongside search.

## Cost delta vs v1

Roughly neutral: drop OpenViking's token spend, add Vertex AI Search
(~$2–4 per 1,000 queries, standard edition + a small indexing cost — a small team's usage
is likely $5–20/mo). VM could now shrink to e2-small (~$13/mo) since only Hermes runs on it.

Sources: [Vertex AI Search data stores](https://docs.cloud.google.com/generative-ai-app-builder/docs/create-data-store-es),
[Grounding with Agent Search](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/grounding/grounding-with-vertex-ai-search),
[RAG Engine Drive import](https://cloud.google.com/vertex-ai/generative-ai/docs/samples/generativeaionvertexai-rag-import-files-async),
[RAG Engine + Vector Search](https://cloud.google.com/vertex-ai/generative-ai/docs/rag-engine/use-vertexai-vector-search)
