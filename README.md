# RecipeCreator

**RecipeCreator** turns a photo of your fridge or pantry into a practical cooking plan. Upload an image, and the system identifies ingredients, finds similar recipes from a vector database, and uses a large language model to pick the best match, suggest substitutions from what you already have, and list anything you still need to buy.

---

## Features

- **Vision-based ingredient detection** — Analyzes fridge/pantry photos and returns a structured list of food items.
- **Semantic recipe search** — Embeds your ingredient list and queries a Pinecone index for the closest matching recipes (by design: top 3 candidates).
- **AI recipe refinement** — Combines your ingredients with retrieved recipes to produce a single recommendation with step-by-step instructions, substitution hints, and a small shopping list for missing essentials.
- **Async processing** — Upload returns immediately with a `task_id`; a Celery worker runs the pipeline so the API stays responsive.
- **Web UI** — A simple React front end for drag-and-drop upload, status polling, and readable results (plus raw JSON for debugging).

---

## How it works

1. **Client** sends a `POST /upload-fridge` request with an image (`multipart/form-data`, field name `file`).
2. **API** enqueues a Celery **chain**: extract ingredients → match recipes → refine output.
3. **Worker** runs each stage: Gemini (vision + JSON refinement), OpenAI embeddings, Pinecone query.
4. **Client** polls `GET /tasks/{task_id}` until status is `SUCCESS` or `FAILURE`.

---

## Repository layout

| Path | Role |
|------|------|
| `backend/app/main.py` | FastAPI app, CORS, upload and task-status routes |
| `backend/app/worker.py` | Celery app and task definitions |
| `backend/app/gemini_client.py` | Gemini calls for extraction and refinement |
| `backend/app/matcher.py` | OpenAI embeddings + Pinecone retrieval |
| `backend/docker-compose.yml` | Local stack: API, worker, Redis |
| `frontend/` | Vite + React UI |
| `backend/terraform/` | AWS networking and ECS-related infrastructure |
| `.github/workflows/deploy.yml` | Build images, push to ECR, force ECS redeploy on `main` |

---

## Prerequisites

- **Docker** (recommended for backend + worker + Redis), or Python 3.11+ with Redis and Celery run manually.
- **API keys**: `GOOGLE_API_KEY`, `OPENAI_API_KEY`, `PINECONE_API_KEY`.
- A Pinecone index (expected name in code: `fridge-ai-recipes`) populated with recipe metadata compatible with the matcher (e.g. `name`, `ingredients`, `steps` in vector metadata).

---

## Quick start (backend)

From `backend/`:

1. Create a `.env` file with the keys above (Compose loads it from this directory).
2. Run:

```bash
docker compose up --build
```

- API: `http://localhost:8000`
- Interactive docs: `http://localhost:8000/docs`

---

## Quick start (frontend)

From `frontend/`:

```bash
npm install
npm run dev
```

By default the UI calls `http://localhost:8000`. Override with:

```env
VITE_API_URL=https://your-api-host
```

Allowed browser origins for CORS can be set on the API with `CORS_ORIGINS` (comma-separated). Defaults include common Vite dev and preview URLs.

---

## API summary

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Health message and endpoint hints |
| `GET` | `/docs` | Swagger UI |
| `POST` | `/upload-fridge` | Body: `file` (image). Response: `task_id`, `status` message |
| `GET` | `/tasks/{task_id}` | Response: `task_id`, Celery `status`, `result` when finished |

Typical Celery statuses: `PENDING`, `STARTED`, `SUCCESS`, `FAILURE`.

---

## Deployment

Pushing to `main` can trigger **GitHub Actions** when `backend/app/**`, `backend/Dockerfile`, or `backend/requirements.txt` change: images are built and pushed to **Amazon ECR**, then **ECS** services are forced to redeploy. Infrastructure details live under `backend/terraform/`.
