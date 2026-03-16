from fastapi import FastAPI, Request, Response
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
import httpx
import os

app = FastAPI(docs_url=None, redoc_url=None)

GODOT = os.getenv("GODOT_API", "http://deadly-pool-server:8081")


@app.api_route("/api/{path:path}", methods=["GET", "POST"])
async def proxy(path: str, request: Request) -> Response:
    url = f"{GODOT}/api/{path}"
    if request.url.query:
        url += f"?{request.url.query}"
    body = await request.body()
    async with httpx.AsyncClient(timeout=10.0) as client:
        r = await client.request(
            request.method,
            url,
            content=body if body else None,
            headers={"Content-Type": "application/json"} if body else {},
        )
    return Response(content=r.content, status_code=r.status_code,
                    media_type="application/json")


@app.get("/logs")
async def logs_page() -> FileResponse:
    return FileResponse("static/logs.html")


@app.get("/tuning")
async def tuning_page() -> FileResponse:
    return FileResponse("static/tuning.html")


app.mount("/", StaticFiles(directory="static", html=True), name="static")
