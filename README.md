# edusphere-learning-platform-263906-263916

Backend (FastAPI)
- Set environment variables (copy backend/.env.example to .env and fill values).
- Install dependencies: pip install -r backend/requirements.txt
- Run dev server: uvicorn src.api.main:app --host 0.0.0.0 --port ${PORT:-3001} --reload
- Generate OpenAPI: python -m src.api.generate_openapi

Key endpoints
- GET / and /healthz — Health
- GET /auth/me — Returns JWT claims (requires Authorization: Bearer)
- POST /ai/assist — AI response (requires OPENAI_API_KEY)
- POST /ai/assist/stream — AI SSE stream
- POST /grades/auto — Auto grade using rubric
- POST /webhooks/supabase — Generic Supabase webhook handler