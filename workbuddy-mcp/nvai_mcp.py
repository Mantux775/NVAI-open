"""NVAI-open MCP Server for WorkBuddy.

Wraps NVAI-open REST API to provide image generation, editing, and restoration
tools accessible from WorkBuddy via MCP protocol.

Usage:
    python nvai_mcp.py [--api-url URL]

Default API URL: http://127.0.0.1:3000

The server connects to a running NVAI-open instance and exposes MCP tools:
- generate_image: Text-to-image generation
- edit_image: Image-to-image editing (inpainting, outpainting)
- restore_image: Photo restoration (repair, colorize, sharpen)
- upscale_image: Image upscaling
- list_models: List available image models
- list_assets: List generated assets
- health: Check NVAI-open status

"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys
from pathlib import Path
from typing import Any

from mcp.server.mcpserver import Context, MCPServer

# Try to import httpx
try:
    import httpx
    HAS_HTTPX = True
except ImportError:
    HAS_HTTPX = False

# Default NVAI-open API URL
DEFAULT_API_URL = "http://127.0.0.1:3000"

server = MCPServer(
    "nvai-open",
    version="1.0.0",
    instructions=(
        "NVAI-open MCP Server provides local AI image generation, editing, and restoration. "
        "All tools connect to a running NVAI-open instance (default: http://127.0.0.1:3000). "
        "Before generating images, call health() to verify the backend is running. "
        "Use list_models() to see available image models and their features. "
        "Image generation returns a job_id that can be checked with get_job_status(). "
        "Generated images are saved to the NVAI-open assets directory and can be listed with list_assets()."
    ),
)


# ============================================================
# Helper Functions
# ============================================================

def _get_api_url() -> str:
    """Get the NVAI-open API URL from environment or default."""
    return os.getenv("NVAI_API_URL", DEFAULT_API_URL)


async def _client(api_url: str) -> httpx.AsyncClient:
    """Create an async HTTP client with timeout."""
    return httpx.AsyncClient(base_url=api_url, timeout=60.0)


def _parse_args():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(description="NVAI-open MCP Server for WorkBuddy")
    parser.add_argument(
        "--api-url",
        type=str,
        default=DEFAULT_API_URL,
        help=f"NVAI-open API URL (default: {DEFAULT_API_URL})"
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8120,
        help="MCP server port (default: 8120)"
    )
    return parser.parse_args()


# ============================================================
# MCP Tools
# ============================================================

@server.tool()
async def health(ctx: Context, api_url: str = DEFAULT_API_URL) -> dict[str, Any]:
    """Check NVAI-open backend health status.

    Returns:
        dict with backend status, GPU info, active models, and queue status.
    """
    async with await _client(api_url) as c:
        r = await c.get("/api/health")
        if r.status_code == 200:
            return {"status": "ok", "data": r.json()}
        return {"status": "error", "error": f"HTTP {r.status_code}: {_detail(r)}"}


@server.tool()
async def list_models(
    ctx: Context,
    kind: str = "image",
    api_url: str = DEFAULT_API_URL,
    detailed: bool = False
) -> dict[str, Any]:
    """List available models.

    Args:
        kind: Model kind - 'image', 'video', 'audio', '3d', 'lora', 'upscale'
        api_url: NVAI-open API URL
        detailed: If True, return detailed model info including features

    Returns:
        List of available models with metadata.
    """
    async with await _client(api_url) as c:
        params = {"kind": kind}
        if detailed:
            params["detailed"] = "true"
        r = await c.get("/api/models", params=params)
        if r.status_code == 200:
            return {"status": "ok", "data": r.json()}
        return {"status": "error", "error": f"HTTP {r.status_code}: {_detail(r)}"}


@server.tool()
async def generate_image(
    ctx: Context,
    prompt: str,
    negative_prompt: str = "",
    model_id: str | None = None,
    width: int = 1024,
    height: int = 1024,
    steps: int | None = None,
    cfg: float | None = None,
    seed: int | None = None,
    batch_size: int = 1,
    wait: bool = True,
    wait_secs: int = 300,
    api_url: str = DEFAULT_API_URL
) -> dict[str, Any]:
    """Generate an image from text prompt.

    Args:
        prompt: Positive prompt describing the image to generate
        negative_prompt: Negative prompt (optional)
        model_id: Model ID (optional, uses active model if not specified)
        width: Image width (256-2560, multiple of 8, default: 1024)
        height: Image height (256-2560, multiple of 8, default: 1024)
        steps: Sampling steps (1-150, optional)
        cfg: CFG scale (0-30, optional)
        seed: Random seed (optional)
        batch_size: Number of images to generate (1-8, default: 1)
        wait: If True, wait for completion and return file path. If False, return job_id immediately.
        wait_secs: Maximum wait time in seconds (default: 300)
        api_url: NVAI-open API URL

    Returns:
        dict with job status and asset paths (if wait=True).
    """
    async with await _client(api_url) as c:
        payload = {
            "prompt": prompt,
            "negative_prompt": negative_prompt,
            "model_id": model_id,
            "width": width,
            "height": height,
            "steps": steps,
            "cfg": cfg,
            "seed": seed,
            "batch_size": batch_size,
        }

        r = await c.post("/api/generate/image", json=payload)
        if r.status_code == 200:
            job = r.json()
            job_id = job.get("id")
            if not wait:
                return {
                    "status": "queued",
                    "job_id": job_id,
                    "message": "Job submitted. Use get_job_status() to check progress."
                }

            # Wait for job completion
            return await _wait_for_job(job_id, c, wait_secs)
        return {"status": "error", "error": f"HTTP {r.status_code}: {_detail(r)}"}


@server.tool()
async def edit_image(
    ctx: Context,
    image_asset_id: str,
    prompt: str,
    negative_prompt: str = "",
    denoise: float = 0.7,
    mask_asset_id: str | None = None,
    outpaint: list[int] | None = None,
    model_id: str | None = None,
    width: int | None = None,
    height: int | None = None,
    steps: int | None = None,
    cfg: float | None = None,
    seed: int | None = None,
    batch_size: int = 1,
    hires: bool = False,
    upsample_prompt: bool | None = None,
    reference_asset_ids: list[str] | None = None,
    wait: bool = True,
    wait_secs: int = 300,
    api_url: str = DEFAULT_API_URL
) -> dict[str, Any]:
    """Edit an existing image (image-to-image).

    Supports: inpainting (with mask), outpainting (extend image),
    style transfer (with reference images), and general editing.

    Args:
        image_asset_id: Source image asset ID
        prompt: Edit prompt describing desired changes
        negative_prompt: Negative prompt (optional)
        denoise: Edit strength (0.0-1.0, 0.3=gentle, 0.7=moderate, 1.0=complete)
        mask_asset_id: Mask for inpainting (white=edit, black=keep)
        outpaint: [left, top, right, bottom] pixels to extend (optional)
        model_id: Model ID (optional)
        width: Output width (optional, calculated if not specified)
        height: Output height (optional, calculated if not specified)
        steps: Sampling steps (optional)
        cfg: CFG scale (optional)
        seed: Random seed (optional)
        batch_size: Number of edits (1-8, default: 1)
        hires: Enable high-res fix (default: False)
        upsample_prompt: Let model expand prompt (FLUX 3 only, optional)
        reference_asset_ids: Reference images for style/consistency (optional)
        wait: Wait for completion (default: True)
        wait_secs: Maximum wait time in seconds (default: 300)
        api_url: NVAI-open API URL

    Returns:
        dict with job status and asset paths.
    """
    async with await _client(api_url) as c:
        payload = {
            "image_asset_id": image_asset_id,
            "prompt": prompt,
            "negative_prompt": negative_prompt,
            "denoise": denoise,
            "mask_asset_id": mask_asset_id,
            "outpaint": outpaint,
            "model_id": model_id,
            "width": width,
            "height": height,
            "steps": steps,
            "cfg": cfg,
            "seed": seed,
            "batch_size": batch_size,
            "hires": hires,
            "upsample_prompt": upsample_prompt,
            "reference_asset_ids": reference_asset_ids or [],
        }

        r = await c.post("/api/generate/image", json=payload)
        if r.status_code == 200:
            job = r.json()
            job_id = job.get("id")
            if not wait:
                return {
                    "status": "queued",
                    "job_id": job_id,
                    "message": "Edit job submitted. Use get_job_status() to check progress."
                }
            return await _wait_for_job(job_id, c, wait_secs)
        return {"status": "error", "error": f"HTTP {r.status_code}: {_detail(r)}"}


@server.tool()
async def restore_image(
    ctx: Context,
    image_asset_id: str | None = None,
    image_path: str | None = None,
    repair_mode: str = "auto",
    batch_size: int = 1,
    wait: bool = True,
    wait_secs: int = 300,
    api_url: str = DEFAULT_API_URL
) -> dict[str, Any]:
    """Restore and enhance old/damaged photos.

    Uses FLUX 3's upsampler for automatic damage detection and repair.
    Supports: damage repair, colorization, and sharpening.

    Args:
        image_asset_id: Source image asset ID (optional if image_path provided)
        image_path: Local file path to image (optional if image_asset_id provided)
        repair_mode: "auto" (default), "thorough" (complete repair), "gentle" (minimal)
        batch_size: Number of images to restore (1-8, default: 1)
        wait: Wait for completion (default: True)
        wait_secs: Maximum wait time in seconds (default: 300)
        api_url: NVAI-open API URL

    Returns:
        dict with job status and restored image paths.
    """
    async with await _client(api_url) as c:
        payload = {
            "image_asset_id": image_asset_id,
            "image_path": image_path,
            "repair_mode": repair_mode,
            "batch_size": batch_size,
        }

        r = await c.post("/api/image/restore", json=payload)
        if r.status_code == 200:
            job = r.json()
            job_id = job.get("id")
            if not wait:
                return {
                    "status": "queued",
                    "job_id": job_id,
                    "message": "Restore job submitted. Use get_job_status() to check progress."
                }
            return await _wait_for_job(job_id, c, wait_secs)
        return {"status": "error", "error": f"HTTP {r.status_code}: {_detail(r)}"}


@server.tool()
async def upscale_image(
    ctx: Context,
    image_asset_id: str,
    wait: bool = True,
    wait_secs: int = 300,
    api_url: str = DEFAULT_API_URL
) -> dict[str, Any]:
    """Upscale an image using AI super-resolution.

    Doubles image dimensions while preserving and enhancing details.

    Args:
        image_asset_id: Source image asset ID
        wait: Wait for completion (default: True)
        wait_secs: Maximum wait time in seconds (default: 300)
        api_url: NVAI-open API URL

    Returns:
        dict with job status and upscaled image path.
    """
    async with await _client(api_url) as c:
        payload = {"asset_id": image_asset_id}

        r = await c.post("/api/image/upscale", json=payload)
        if r.status_code == 200:
            job = r.json()
            job_id = job.get("id")
            if not wait:
                return {
                    "status": "queued",
                    "job_id": job_id,
                    "message": "Upscale job submitted. Use get_job_status() to check progress."
                }
            return await _wait_for_job(job_id, c, wait_secs)
        return {"status": "error", "error": f"HTTP {r.status_code}: {_detail(r)}"}


@server.tool()
async def list_assets(
    ctx: Context,
    kind: str = "image",
    limit: int = 50,
    api_url: str = DEFAULT_API_URL
) -> dict[str, Any]:
    """List generated assets (images, videos, audio, etc.).

    Args:
        kind: Asset kind - 'image', 'video', 'audio', 'mesh' (default: image)
        limit: Maximum number of assets to return (default: 50)
        api_url: NVAI-open API URL

    Returns:
        List of assets with metadata.
    """
    async with await _client(api_url) as c:
        params = {"kind": kind, "limit": limit}
        r = await c.get("/api/assets", params=params)
        if r.status_code == 200:
            return {"status": "ok", "data": r.json()}
        return {"status": "error", "error": f"HTTP {r.status_code}: {_detail(r)}"}


@server.tool()
async def get_job_status(
    ctx: Context,
    job_id: str,
    wait_secs: int = 60,
    api_url: str = DEFAULT_API_URL
) -> dict[str, Any]:
    """Get status of a generation job.

    Args:
        job_id: Job ID from generate_image or other generation tools
        wait_secs: Maximum time to wait for completion (default: 60)
        api_url: NVAI-open API URL

    Returns:
        dict with job status, progress, and result (if complete).
    """
    async with await _client(api_url) as c:
        return await _wait_for_job(job_id, c, wait_secs)


@server.tool()
async def expand_prompt(
    ctx: Context,
    prompt: str,
    width: int = 1024,
    height: int = 1024,
    target: str = "image",
    api_url: str = DEFAULT_API_URL
) -> dict[str, Any]:
    """Expand a short prompt into a detailed image description.

    Uses the model's upsampler to generate a full prompt description.

    Args:
        prompt: Short prompt to expand
        width: Target image width (default: 1024)
        height: Target image height (default: 1024)
        target: Target kind - 'image', 'video', 'audio', etc. (default: image)
        api_url: NVAI-open API URL

    Returns:
        dict with expanded prompt and caption.
    """
    async with await _client(api_url) as c:
        payload = {
            "prompt": prompt,
            "width": width,
            "height": height,
            "target": target,
        }

        r = await c.post("/api/prompt/expand", json=payload)
        if r.status_code == 200:
            return {"status": "ok", "data": r.json()}
        return {"status": "error", "error": f"HTTP {r.status_code}: {_detail(r)}"}


# ============================================================
# Job Waiting Helper
# ============================================================

async def _wait_for_job(job_id: str, client: httpx.AsyncClient, wait_secs: int = 300) -> dict[str, Any]:
    """Wait for a job to complete and return result."""
    import time

    start_time = time.time()
    poll_interval = 2.0  # seconds

    while time.time() - start_time < wait_secs:
        r = await client.get(f"/api/jobs/{job_id}")
        if r.status_code == 404:
            return {
                "status": "error",
                "error": "Job no longer exists (deleted from history)."
            }

        r.raise_for_status()
        job = r.json()
        status = job.get("status", "unknown")

        if status in ("done", "error", "cancelled"):
            return job

        # Wait and poll again
        await asyncio.sleep(poll_interval)

    # Timed out - return current status
    return {
        "status": "timeout",
        "job_id": job_id,
        "message": f"Job still running after {wait_secs}s. Use get_job_status() to check later."
    }


def _detail(r: httpx.Response) -> str:
    """Extract detail from HTTP error response."""
    try:
        detail = r.json().get("detail")
    except ValueError:
        detail = None
    return str(detail or f"HTTP {r.status_code}")


# ============================================================
# Server Entry Point
# ============================================================

if __name__ == "__main__":
    args = _parse_args()

    # Set API URL in environment for tools to use
    os.environ["NVAI_API_URL"] = args.api_url

    print(f"Starting NVAI-open MCP Server...")
    print(f"API URL: {args.api_url}")
    print(f"Server: nvai-open v1.0.0")
    print()
    print("Available tools:")
    print("  - health: Check backend status")
    print("  - list_models: List available models")
    print("  - generate_image: Generate image from prompt")
    print("  - edit_image: Edit existing image")
    print("  - restore_image: Restore old photos")
    print("  - upscale_image: Upscale image resolution")
    print("  - list_assets: List generated assets")
    print("  - get_job_status: Check job progress")
    print("  - expand_prompt: Expand short prompt")
    print()

    # Run MCP server
    from mcp.server.mcpserver import run_server
    run_server(server, port=args.port)
