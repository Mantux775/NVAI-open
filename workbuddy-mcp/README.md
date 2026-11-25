# NVAI-open MCP Server for WorkBuddy

MCP (Model Context Protocol) server that wraps NVAI-open's REST API to provide image generation, editing, and restoration tools accessible from WorkBuddy.

## Features

- **Generate Images**: Text-to-image generation with multiple models
- **Edit Images**: Image-to-image editing (inpainting, outpainting, style transfer)
- **Restore Photos**: Automatic photo repair, colorization, and sharpening
- **Upscale Images**: AI super-resolution upscaling
- **Expand Prompts**: Convert short prompts into detailed descriptions

## Prerequisites

1. NVAI-open installed and running on your system
   - Default API URL: `http://127.0.0.1:3000`
   - Can be changed with `--api-url` parameter

2. Python 3.9+

## Installation

```bash
# Install dependencies
pip install -r requirements.txt

# Or install manually
pip install mcp httpx
```

## Usage

### Command Line

```bash
# Start with default settings
python nvai_mcp.py

# Specify custom API URL and port
python nvai_mcp.py --api-url http://127.0.0.1:3000 --port 8120
```

### Available Tools

| Tool | Description |
|------|-------------|
| `health` | Check NVAI-open backend health |
| `list_models` | List available image/video/audio models |
| `generate_image` | Generate image from text prompt |
| `edit_image` | Edit existing image (inpainting, outpainting) |
| `restore_image` | Restore old/damaged photos |
| `upscale_image` | Upscale image using AI super-resolution |
| `list_assets` | List generated assets |
| `get_job_status` | Check job progress |
| `expand_prompt` | Expand short prompt into detailed description |

### Example Usage (WorkBuddy)

```python
# Generate an image
result = await generate_image(
    prompt="A beautiful sunset over mountains",
    width=1024,
    height=1024,
    wait=True
)
print(result)

# Edit an image
result = await edit_image(
    image_asset_id="img_12345",
    prompt="Change the sky to blue",
    denoise=0.7,
    wait=True
)

# Restore a photo
result = await restore_image(
    image_path="C:/path/to/old_photo.jpg",
    repair_mode="auto",
    wait=True
)
```

## Configuration

Set environment variables:
- `NVAI_API_URL`: NVAI-open API URL (default: `http://127.0.0.1:3000`)

## Integration with WorkBuddy

To use this MCP server in WorkBuddy:

1. Start the MCP server: `python nvai_mcp.py`
2. Add to WorkBuddy MCP configuration
3. Use the tools in your WorkBuddy conversations

## License

MIT License - based on NVAI-open project
