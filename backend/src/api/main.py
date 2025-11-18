import json
import logging
import os
import time
from typing import Any, Dict, List, Optional

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field
from starlette.status import HTTP_401_UNAUTHORIZED, HTTP_500_INTERNAL_SERVER_ERROR

# App-level configuration and utilities

SERVICE_NAME = "lms-backend"

def _get_env_bool(name: str, default: bool = False) -> bool:
    """Parse boolean-ish environment variables."""
    val = os.getenv(name)
    if val is None:
        return default
    return val.lower() in {"1", "true", "yes", "y", "on"}

def _get_json_env(name: str, default: Any):
    """Parse JSON from env with fallback."""
    try:
        raw = os.getenv(name)
        if not raw:
            return default
        return json.loads(raw)
    except Exception:
        return default

# Structured logger setup
def setup_logging() -> logging.Logger:
    level = os.getenv("LOG_LEVEL", "INFO").upper()
    logger = logging.getLogger(SERVICE_NAME)
    logger.setLevel(level)
    if not logger.handlers:
        handler = logging.StreamHandler()
        formatter = logging.Formatter(
            fmt='{"timestamp":"%(asctime)s","level":"%(levelname)s","service":"%(name)s","message":"%(message)s"}'
        )
        handler.setFormatter(formatter)
        logger.addHandler(handler)
    return logger

logger = setup_logging()

# Config from environment variables (12-factor)
PORT = int(os.getenv("PORT", "3001"))
CORS_ORIGINS = _get_json_env("CORS_ORIGINS", ["http://localhost:3000"])
FEATURE_FLAGS = _get_json_env("FEATURE_FLAGS", {})

SUPABASE_URL = os.getenv("SUPABASE_URL", "")
SUPABASE_SERVICE_ROLE_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "")
SUPABASE_ANON_KEY = os.getenv("SUPABASE_ANON_KEY", "")
SUPABASE_JWT_SECRET = os.getenv("SUPABASE_JWT_SECRET", "")  # optional
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", os.getenv("AI_PROVIDER_API_KEY", ""))

# Basic input/output models

class HealthResponse(BaseModel):
    status: str = Field(..., description="Overall health status")
    uptime_ms: int = Field(..., description="Server uptime in milliseconds")
    features: Dict[str, Any] = Field(default_factory=dict, description="Feature flags visibility")

# PUBLIC_INTERFACE
class MeResponse(BaseModel):
    """Authenticated user context returned by /auth/me."""
    user_id: Optional[str] = Field(None, description="User UUID from JWT (sub claim)")
    role: Optional[str] = Field(None, description="Role claim if present")
    email: Optional[str] = Field(None, description="Email claim if present")
    metadata: Dict[str, Any] = Field(default_factory=dict, description="Additional JWT claims (non-sensitive)")

# PUBLIC_INTERFACE
class AIRequest(BaseModel):
    """Request body for AI assistance."""
    prompt: str = Field(..., description="User input to send to the AI provider")
    system: Optional[str] = Field(default="You are a helpful teaching assistant.", description="System prompt")
    max_tokens: Optional[int] = Field(default=256, description="Maximum tokens in response")
    temperature: Optional[float] = Field(default=0.2, description="Sampling temperature")
    model: Optional[str] = Field(default="gpt-4o-mini", description="Model identifier (provider dependent)")

# PUBLIC_INTERFACE
class AIResponse(BaseModel):
    """Response model for non-streaming AI endpoint."""
    answer: str = Field(..., description="Assistant response text")
    model: Optional[str] = Field(default=None, description="Model used")
    usage: Optional[Dict[str, Any]] = Field(default=None, description="Token usage if available")

# PUBLIC_INTERFACE
class AutoGradeRequest(BaseModel):
    """Request to auto-grade text answers."""
    rubric: str = Field(..., description="Scoring rubric or instructions")
    answers: List[Dict[str, Any]] = Field(..., description="List of answers with metadata (e.g., student_id, content)")

# PUBLIC_INTERFACE
class AutoGradeResponse(BaseModel):
    """Auto grading result."""
    results: List[Dict[str, Any]] = Field(..., description="Per-answer grade and feedback objects")

# PUBLIC_INTERFACE
class SupabaseWebhookPayload(BaseModel):
    """Supabase webhook payload model (generic)."""
    type: str = Field(..., description="Event type (e.g., INSERT, UPDATE)")
    table: Optional[str] = Field(None, description="Table name if available")
    record: Optional[Dict[str, Any]] = Field(None, description="New record data")
    schema: Optional[str] = Field("public", description="Schema name")
    old_record: Optional[Dict[str, Any]] = Field(None, description="Previous record data (for UPDATE/DELETE)")

# Security: JWT verification (Supabase)
# We avoid adding PyJWT dependency; use simple verification via Authorization header presence and optionally decode using HMAC if secret present.
# For robust verification, projects should add a JWT library; here we verify bearer format and pass along claims if using Supabase JWT secret via simple base64 decode.
import base64
import hashlib
import hmac

def _base64url_decode(input_str: str) -> bytes:
    rem = len(input_str) % 4
    if rem:
        input_str += "=" * (4 - rem)
    return base64.urlsafe_b64decode(input_str.encode("utf-8"))

def verify_jwt_and_get_claims(authorization: Optional[str] = Header(None)) -> Dict[str, Any]:
    """
    Verify JWT from Authorization header if provided.
    If SUPABASE_JWT_SECRET is available, perform HMAC SHA256 verification.
    Returns claims dict or raises HTTPException for invalid token.
    """
    if not authorization:
        raise HTTPException(status_code=HTTP_401_UNAUTHORIZED, detail="Missing Authorization header")
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=HTTP_401_UNAUTHORIZED, detail="Invalid auth scheme")
    token = authorization.split(" ", 1)[1].strip()
    try:
        header_b64, payload_b64, signature_b64 = token.split(".")
    except ValueError:
        raise HTTPException(status_code=HTTP_401_UNAUTHORIZED, detail="Malformed JWT")

    # Decode claims
    try:
        payload_json = _base64url_decode(payload_b64).decode("utf-8")
        claims = json.loads(payload_json)
    except Exception:
        raise HTTPException(status_code=HTTP_401_UNAUTHORIZED, detail="Invalid JWT payload")

    # Optional signature verification if secret provided
    if SUPABASE_JWT_SECRET:
        try:
            signing_input = f"{header_b64}.{payload_b64}".encode("utf-8")
            expected_sig = hmac.new(SUPABASE_JWT_SECRET.encode("utf-8"), signing_input, hashlib.sha256).digest()
            actual_sig = _base64url_decode(signature_b64)
            if not hmac.compare_digest(expected_sig, actual_sig):
                raise HTTPException(status_code=HTTP_401_UNAUTHORIZED, detail="Invalid JWT signature")
        except HTTPException:
            raise
        except Exception:
            raise HTTPException(status_code=HTTP_401_UNAUTHORIZED, detail="JWT signature verification failed")

    return claims

# Supabase client (lightweight via httpx)
import httpx

class SupabaseClient:
    """Minimal Supabase REST client using PostgREST endpoint."""
    def __init__(self, url: str, anon_key: str, service_key: Optional[str] = None):
        if not url:
            raise ValueError("SUPABASE_URL is required")
        self.base_url = url.rstrip("/") + "/rest/v1"
        self.anon_key = anon_key
        self.service_key = service_key or anon_key

    async def select(self, table: str, query: str = "*", filters: Optional[Dict[str, str]] = None, auth_role: str = "service") -> List[Dict[str, Any]]:
        headers = {
            "apikey": self.anon_key,
            "Authorization": f"Bearer {self.service_key if auth_role=='service' else self.anon_key}",
            "Accept": "application/json",
        }
        params = {"select": query}
        if filters:
            params.update(filters)
        async with httpx.AsyncClient(timeout=15.0) as client:
            res = await client.get(f"{self.base_url}/{table}", headers=headers, params=params)
            res.raise_for_status()
            return res.json()

# AI provider (OpenAI compatible, via httpx)
class AIProvider:
    """Simple AI provider using OpenAI Chat Completions API."""
    def __init__(self, api_key: str):
        self.api_key = api_key
        self.base_url = "https://api.openai.com/v1"
        if not self.api_key:
            logger.warning("OPENAI_API_KEY not provided; AI features will be disabled.")

    async def chat(self, req: AIRequest) -> AIResponse:
        if not self.api_key:
            raise HTTPException(status_code=HTTP_500_INTERNAL_SERVER_ERROR, detail="AI provider not configured")
        payload = {
            "model": req.model or "gpt-4o-mini",
            "messages": [
                {"role": "system", "content": req.system or "You are a helpful teaching assistant."},
                {"role": "user", "content": req.prompt},
            ],
            "max_tokens": req.max_tokens or 256,
            "temperature": req.temperature if req.temperature is not None else 0.2,
        }
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"}
        async with httpx.AsyncClient(timeout=60.0) as client:
            r = await client.post(f"{self.base_url}/chat/completions", headers=headers, json=payload)
            r.raise_for_status()
            data = r.json()
            content = data.get("choices", [{}])[0].get("message", {}).get("content", "")
            usage = data.get("usage")
            return AIResponse(answer=content, model=data.get("model"), usage=usage)

    async def stream_chat(self, req: AIRequest):
        """Yield Server-Sent Events lines from streaming response."""
        if not self.api_key:
            raise HTTPException(status_code=HTTP_500_INTERNAL_SERVER_ERROR, detail="AI provider not configured")
        payload = {
            "model": req.model or "gpt-4o-mini",
            "messages": [
                {"role": "system", "content": req.system or "You are a helpful teaching assistant."},
                {"role": "user", "content": req.prompt},
            ],
            "max_tokens": req.max_tokens or 256,
            "temperature": req.temperature if req.temperature is not None else 0.2,
            "stream": True,
        }
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"}
        async with httpx.AsyncClient(timeout=None) as client:
            async with client.stream("POST", f"{self.base_url}/chat/completions", headers=headers, json=payload) as r:
                r.raise_for_status()
                async for line in r.aiter_lines():
                    if not line:
                        continue
                    yield f"data: {line}\n\n"

# Initialize app with metadata, tags
app = FastAPI(
    title="EduSphere LMS Backend",
    description="Backend API for EduSphere LMS with Supabase integration and AI assistance.",
    version="1.0.0",
    openapi_tags=[
        {"name": "Health", "description": "Health and service information"},
        {"name": "Auth", "description": "Authentication utilities"},
        {"name": "AI", "description": "AI assistance endpoints"},
        {"name": "Grades", "description": "Grading and automation"},
        {"name": "Webhooks", "description": "Inbound webhooks (Supabase, etc.)"},
        {"name": "Docs", "description": "Documentation and usage notes"},
    ],
)

# CORS configuration
app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS or ["http://localhost:3000"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Global instances
_start_time = time.time()
supabase_client = SupabaseClient(SUPABASE_URL, SUPABASE_ANON_KEY or SUPABASE_SERVICE_ROLE_KEY or "", SUPABASE_SERVICE_ROLE_KEY or None) if SUPABASE_URL else None
ai_provider = AIProvider(OPENAI_API_KEY)

@app.middleware("http")
async def add_request_logging(request: Request, call_next):
    """Structured logging middleware for requests."""
    start = time.time()
    try:
        response = await call_next(request)
        duration = int((time.time() - start) * 1000)
        logger.info(
            json.dumps(
                {
                    "path": request.url.path,
                    "method": request.method,
                    "status": response.status_code,
                    "duration_ms": duration,
                }
            )
        )
        return response
    except Exception as ex:
        duration = int((time.time() - start) * 1000)
        logger.exception(
            json.dumps(
                {
                    "path": request.url.path,
                    "method": request.method,
                    "status": 500,
                    "duration_ms": duration,
                    "error": str(ex),
                }
            )
        )
        return JSONResponse({"error": "Internal server error"}, status_code=500)

@app.get("/", response_model=HealthResponse, tags=["Health"], summary="Health Check", description="Returns basic health info and feature flags.")
def health_check() -> HealthResponse:
    """Health check endpoint."""
    uptime_ms = int((time.time() - _start_time) * 1000)
    return HealthResponse(status="ok", uptime_ms=uptime_ms, features=FEATURE_FLAGS or {})

@app.get("/healthz", response_model=HealthResponse, tags=["Health"], summary="Kubernetes-style health", description="Alternate health endpoint")
def healthz() -> HealthResponse:
    uptime_ms = int((time.time() - _start_time) * 1000)
    return HealthResponse(status="ok", uptime_ms=uptime_ms, features=FEATURE_FLAGS or {})

# PUBLIC_INTERFACE
@app.get("/auth/me", response_model=MeResponse, tags=["Auth"], summary="Get current user", description="Return claims from the JWT provided in Authorization header.")
def auth_me(claims: Dict[str, Any] = Depends(verify_jwt_and_get_claims)) -> MeResponse:
    """
    Returns user info based on JWT.
    Requires Authorization: Bearer <token>.
    If SUPABASE_JWT_SECRET is configured, signature verification is performed.
    """
    # Only include non-sensitive claims
    safe_claims = {k: v for k, v in claims.items() if k not in {"exp", "iat", "nbf"}}
    return MeResponse(
        user_id=safe_claims.get("sub") or safe_claims.get("user_id"),
        role=safe_claims.get("role"),
        email=safe_claims.get("email"),
        metadata=safe_claims,
    )

# PUBLIC_INTERFACE
@app.post("/ai/assist", response_model=AIResponse, tags=["AI"], summary="AI assistance", description="Get a single AI response for a prompt.")
async def ai_assist(req: AIRequest, claims: Dict[str, Any] = Depends(verify_jwt_and_get_claims)) -> AIResponse:
    """Invoke the AI provider to assist with a given prompt."""
    return await ai_provider.chat(req)

# PUBLIC_INTERFACE
@app.post("/ai/assist/stream", tags=["AI"], summary="AI assistance (streaming SSE)", description="Stream AI tokens as Server-Sent Events.")
async def ai_assist_stream(req: AIRequest, claims: Dict[str, Any] = Depends(verify_jwt_and_get_claims)):
    """Streaming variant of AI assistance. Returns an SSE stream."""
    async def event_generator():
        async for chunk in ai_provider.stream_chat(req):
            yield chunk
    return StreamingResponse(event_generator(), media_type="text/event-stream")

# PUBLIC_INTERFACE
@app.post("/grades/auto", response_model=AutoGradeResponse, tags=["Grades"], summary="Auto grade answers", description="Generate grades and feedback using AI based on rubric.")
async def grades_auto(body: AutoGradeRequest, claims: Dict[str, Any] = Depends(verify_jwt_and_get_claims)) -> AutoGradeResponse:
    """
    Auto-grade student answers with an AI rubric.
    This uses the AI provider; ensure OPENAI_API_KEY (or AI_PROVIDER_API_KEY) is configured.
    """
    system = "You are an expert grader. Grade according to the rubric strictly. Return concise feedback."
    results: List[Dict[str, Any]] = []
    for ans in body.answers:
        content = ans.get("content", "")
        student_id = ans.get("student_id")
        prompt = f"Rubric:\n{body.rubric}\n\nAnswer:\n{content}\n\nProvide a JSON with fields: grade (0-100), feedback (string)."
        ai_req = AIRequest(prompt=prompt, system=system, max_tokens=200, temperature=0.0)
        try:
            res = await ai_provider.chat(ai_req)
            # attempt to parse json from response; fallback to raw
            parsed: Dict[str, Any]
            try:
                parsed = json.loads(res.answer)
            except Exception:
                parsed = {"grade": None, "feedback": res.answer}
            results.append({"student_id": student_id, "result": parsed})
        except HTTPException as e:
            results.append({"student_id": student_id, "error": e.detail})
        except Exception as e:
            # Avoid f-strings without placeholders to satisfy flake8 F541
            results.append({"student_id": student_id, "error": "grading_failed: " + str(e)})
    return AutoGradeResponse(results=results)

# PUBLIC_INTERFACE
@app.post("/webhooks/supabase", tags=["Webhooks"], summary="Supabase webhook", description="Endpoint to receive Supabase webhooks for DB changes.")
async def supabase_webhook(payload: SupabaseWebhookPayload, request: Request):
    """
    Receives Supabase webhooks (e.g., table changes).
    This is a generic handler; extend with business logic as needed.
    """
    # Minimal signature check can be added here using a secret header if configured.
    logger.info(json.dumps({
        "event": payload.type,
        "table": payload.table,
        "schema": payload.schema,
    }))
    return {"received": True}

# PUBLIC_INTERFACE
@app.get("/docs/websocket", tags=["Docs"], summary="WebSocket usage notes", description="Explain real-time connections for the project.")
def websocket_docs():
    """
    Provides usage notes for any WebSocket endpoints (none are exposed here yet).
    """
    return {
        "websocket_endpoints": [],
        "note": "This project uses Supabase Realtime for chat/announcements. No backend WebSocket endpoints are currently exposed."
    }
