from fastapi import APIRouter

from app.schemas.health import HealthResponse

router = APIRouter(prefix="/v1", tags=["health"])


@router.get("/health")
def health() -> HealthResponse:
    return HealthResponse(status="ok")
