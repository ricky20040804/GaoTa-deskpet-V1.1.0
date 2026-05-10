#!/usr/bin/env python3
"""
Generate a Codex-style desktop pet package.

The output is compatible with this app's current runtime:

    <pet-id>/
      pet.json
      spritesheet.webp    # 1536 x 768, 8 columns x 4 rows, 192 x 192 cells
      preview.png
      <pet-id>.zip

MVP behavior:
- Generate one complete 4x8 spritesheet with an image API.
- Row 0 is idle, row 1 is running, row 2 is failed, row 3 is tail-wagging.
- If --from-static is passed, skip the image API and make a static-but-runnable package.
"""

from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import os
import random
import re
import shutil
import string
import sys
import tempfile
import urllib.error
import urllib.request
import uuid
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

try:
    from PIL import Image, ImageDraw
except ModuleNotFoundError as exc:
    raise SystemExit(
        "This script needs Pillow. Run it with the bundled Codex Python:\n"
        "/Users/ricky/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 "
        "Tools/generate_pet/generate_pet.py ...\n"
        "Or install Pillow into your Python environment."
    ) from exc


FRAME_WIDTH = 192
FRAME_HEIGHT = 192
COLUMNS = 8
ROWS = 4
SHEET_WIDTH = FRAME_WIDTH * COLUMNS
SHEET_HEIGHT = FRAME_HEIGHT * ROWS


@dataclass(frozen=True)
class RuntimeRow:
    name: str
    row: int
    frame_count: int


RUNTIME_ROWS: list[RuntimeRow] = [
    RuntimeRow("idle", 0, 8),
    RuntimeRow("running", 1, 8),
    RuntimeRow("failed", 2, 8),
    RuntimeRow("tail-wagging", 3, 8),
]

SOURCE_ACTIONS: list[RuntimeRow] = [
    RuntimeRow("idle", 0, 8),
    RuntimeRow("running", 1, 8),
    RuntimeRow("failed", 2, 8),
    RuntimeRow("tail-wagging", 3, 8),
]


def slugify(value: str) -> str:
    normalized = value.strip().lower()
    normalized = re.sub(r"[^a-z0-9]+", "-", normalized)
    normalized = normalized.strip("-")
    if normalized:
        return normalized
    return "pet-" + "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))


def ensure_rgba(image: Image.Image) -> Image.Image:
    if image.mode != "RGBA":
        return image.convert("RGBA")
    return image


def trim_transparent(image: Image.Image) -> Image.Image:
    image = ensure_rgba(image)
    alpha = image.getchannel("A")
    bbox = alpha.getbbox()
    if not bbox:
        return image
    return image.crop(bbox)


def fit_into_cell(image: Image.Image, padding: int = 8) -> Image.Image:
    image = trim_transparent(image)
    max_width = FRAME_WIDTH - padding * 2
    max_height = FRAME_HEIGHT - padding * 2
    if image.width <= 0 or image.height <= 0:
        return Image.new("RGBA", (FRAME_WIDTH, FRAME_HEIGHT), (0, 0, 0, 0))

    scale = min(max_width / image.width, max_height / image.height, 1.0)
    resized = image.resize(
        (max(1, int(image.width * scale)), max(1, int(image.height * scale))),
        Image.Resampling.LANCZOS,
    )

    cell = Image.new("RGBA", (FRAME_WIDTH, FRAME_HEIGHT), (0, 0, 0, 0))
    x = (FRAME_WIDTH - resized.width) // 2
    y = FRAME_HEIGHT - resized.height - padding
    cell.alpha_composite(resized, (x, y))
    return cell


def split_action_strip(strip: Image.Image, frame_count: int, *, mode: str = "resize-strip") -> list[Image.Image]:
    strip = ensure_rgba(strip)
    if mode == "resize-strip":
        normalized = strip.resize((FRAME_WIDTH * frame_count, FRAME_HEIGHT), Image.Resampling.LANCZOS)
        frames: list[Image.Image] = []
        for index in range(frame_count):
            frame = normalized.crop((index * FRAME_WIDTH, 0, (index + 1) * FRAME_WIDTH, FRAME_HEIGHT))
            frames.append(ensure_rgba(frame))
        return frames

    if mode != "crop-fit":
        raise ValueError(f"Unknown split mode: {mode}")

    frames: list[Image.Image] = []
    for index in range(frame_count):
        left = round(strip.width * index / frame_count)
        right = round(strip.width * (index + 1) / frame_count)
        frame = strip.crop((left, 0, right, strip.height))
        frames.append(fit_into_cell(frame))
    return frames


def static_frames(reference_path: Path, frame_count: int) -> list[Image.Image]:
    base = fit_into_cell(Image.open(reference_path))
    return [base.copy() for _ in range(frame_count)]


def mirror_frames(frames: Iterable[Image.Image]) -> list[Image.Image]:
    return [frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT) for frame in frames]


def build_sheet(action_frames: dict[str, list[Image.Image]]) -> Image.Image:
    sheet = Image.new("RGBA", (SHEET_WIDTH, SHEET_HEIGHT), (0, 0, 0, 0))

    for row in RUNTIME_ROWS:
        frames = action_frames[row.name]

        for column, frame in enumerate(frames[: row.frame_count]):
            sheet.alpha_composite(frame, (column * FRAME_WIDTH, row.row * FRAME_HEIGHT))

    return sheet


def normalize_sheet(image: Image.Image) -> Image.Image:
    image = ensure_rgba(image)
    if image.size == (SHEET_WIDTH, SHEET_HEIGHT):
        return image
    return image.resize((SHEET_WIDTH, SHEET_HEIGHT), Image.Resampling.LANCZOS)


def remove_chroma_background(image: Image.Image) -> Image.Image:
    image = ensure_rgba(image)
    pixels = image.load()
    for y in range(image.height):
        for x in range(image.width):
            r, g, b, a = pixels[x, y]
            green_screen = g > 150 and r < 120 and b < 140 and g - max(r, b) > 45
            red_screen = r > 160 and g < 120 and b < 120 and r - max(g, b) > 55
            if green_screen or red_screen:
                pixels[x, y] = (r, g, b, 0)
    return image


def build_preview(sheet: Image.Image) -> Image.Image:
    scale = 0.5
    preview = Image.new("RGBA", (int(SHEET_WIDTH * scale), int(SHEET_HEIGHT * scale)), (245, 245, 245, 255))
    checker = Image.new("RGBA", (16, 16), (255, 255, 255, 255))
    draw = ImageDraw.Draw(checker)
    draw.rectangle((0, 0, 7, 7), fill=(225, 225, 225, 255))
    draw.rectangle((8, 8, 15, 15), fill=(225, 225, 225, 255))
    for y in range(0, preview.height, checker.height):
        for x in range(0, preview.width, checker.width):
            preview.alpha_composite(checker, (x, y))

    preview.alpha_composite(sheet.resize(preview.size, Image.Resampling.NEAREST), (0, 0))
    grid = ImageDraw.Draw(preview)
    for x in range(0, preview.width + 1, int(FRAME_WIDTH * scale)):
        grid.line((x, 0, x, preview.height), fill=(0, 0, 0, 80), width=1)
    for y in range(0, preview.height + 1, int(FRAME_HEIGHT * scale)):
        grid.line((0, y, preview.width, y), fill=(0, 0, 0, 80), width=1)
    return preview.convert("RGB")


def write_manifest(output_dir: Path, pet_id: str, display_name: str, description: str) -> None:
    manifest = {
        "id": pet_id,
        "displayName": display_name,
        "description": description,
        "spritesheetPath": "spritesheet.webp",
    }
    (output_dir / "pet.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def zip_package(output_dir: Path, pet_id: str) -> Path:
    zip_path = output_dir / f"{pet_id}.zip"
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.write(output_dir / "pet.json", arcname=f"{pet_id}/pet.json")
        archive.write(output_dir / "spritesheet.webp", arcname=f"{pet_id}/spritesheet.webp")
        archive.write(output_dir / "preview.png", arcname=f"{pet_id}/preview.png")
    return zip_path


def install_package(output_dir: Path, pet_id: str) -> Path:
    destination = Path.home() / ".codex" / "pets" / pet_id
    try:
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copy2(output_dir / "pet.json", destination / "pet.json")
        shutil.copy2(output_dir / "spritesheet.webp", destination / "spritesheet.webp")
    except PermissionError as exc:
        raise RuntimeError(
            f"Could not install to {destination}. The package was generated successfully; "
            "copy pet.json and spritesheet.webp there manually, or run this script with permission to write ~/.codex/pets."
        ) from exc
    return destination


def multipart_encode(fields: dict[str, str], files: list[tuple[str, Path]]) -> tuple[bytes, str]:
    boundary = "----CodexPetBoundary" + uuid.uuid4().hex
    body = bytearray()

    def add_line(value: str | bytes = b"") -> None:
        if isinstance(value, str):
            body.extend(value.encode("utf-8"))
        else:
            body.extend(value)
        body.extend(b"\r\n")

    for name, value in fields.items():
        add_line(f"--{boundary}")
        add_line(f'Content-Disposition: form-data; name="{name}"')
        add_line()
        add_line(value)

    for field_name, path in files:
        mime_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        add_line(f"--{boundary}")
        add_line(f'Content-Disposition: form-data; name="{field_name}"; filename="{path.name}"')
        add_line(f"Content-Type: {mime_type}")
        add_line()
        body.extend(path.read_bytes())
        body.extend(b"\r\n")

    add_line(f"--{boundary}--")
    return bytes(body), boundary


def image_to_data_url(path: Path, *, for_dashscope: bool = False) -> str:
    image = Image.open(path)
    buffer = tempfile.NamedTemporaryFile(suffix=".jpg" if for_dashscope else path.suffix)
    try:
        if for_dashscope:
            # DashScope docs say input PNG is accepted but transparent channels are not.
            # Flattening here makes alpha-heavy references predictable.
            rgb = Image.new("RGB", image.size, (255, 255, 255))
            if image.mode == "RGBA":
                rgb.paste(image, mask=image.getchannel("A"))
            else:
                rgb.paste(image.convert("RGB"))
            rgb.save(buffer.name, "JPEG", quality=95)
            mime_type = "image/jpeg"
        else:
            shutil.copy2(path, buffer.name)
            mime_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"

        encoded = base64.b64encode(Path(buffer.name).read_bytes()).decode("ascii")
        return f"data:{mime_type};base64,{encoded}"
    finally:
        buffer.close()


def json_post(url: str, payload: dict, headers: dict[str, str], timeout: int = 180) -> dict:
    request = urllib.request.Request(
        url,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        method="POST",
        headers=headers,
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Image request failed: HTTP {exc.code}\n{detail}") from exc


def download_image(url: str) -> Image.Image:
    request = urllib.request.Request(url, headers={"User-Agent": "gaotadeskpet-generator/0.1"})
    with urllib.request.urlopen(request, timeout=180) as response:
        suffix = ".png"
        content_type = response.headers.get("Content-Type", "")
        if "webp" in content_type:
            suffix = ".webp"
        elif "jpeg" in content_type or "jpg" in content_type:
            suffix = ".jpg"
        with tempfile.NamedTemporaryFile(suffix=suffix) as temp:
            temp.write(response.read())
            temp.flush()
            return ensure_rgba(Image.open(temp.name).copy())


def openai_image_edit(
    *,
    api_key: str,
    model: str,
    reference_path: Path,
    prompt: str,
    size: str,
    output_format: str,
    quality: str,
) -> Image.Image:
    fields = {
        "model": model,
        "prompt": prompt,
        "size": size,
        "background": "transparent",
        "output_format": output_format,
        "quality": quality,
    }
    body, boundary = multipart_encode(fields, [("image[]", reference_path)])
    request = urllib.request.Request(
        "https://api.openai.com/v1/images/edits",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"OpenAI image request failed: HTTP {exc.code}\n{detail}") from exc

    try:
        encoded = payload["data"][0]["b64_json"]
    except (KeyError, IndexError) as exc:
        raise RuntimeError(f"OpenAI response did not contain data[0].b64_json:\n{json.dumps(payload)[:1000]}") from exc

    with tempfile.NamedTemporaryFile(suffix=f".{output_format}") as temp:
        temp.write(base64.b64decode(encoded))
        temp.flush()
        return ensure_rgba(Image.open(temp.name).copy())


def dashscope_image_edit(
    *,
    api_key: str,
    model: str,
    endpoint: str,
    reference_path: Path,
    prompt: str,
    size: str,
    prompt_extend: bool,
    seed: int | None,
) -> Image.Image:
    content: list[dict[str, str]] = [
        {"text": prompt},
        {"image": image_to_data_url(reference_path, for_dashscope=True)},
    ]
    parameters: dict[str, object] = {
        "prompt_extend": prompt_extend,
        "watermark": False,
        "n": 1,
        "enable_interleave": False,
        "size": size,
        "negative_prompt": (
            "文字，水印，边框，网格线，背景，阴影，裁切身体，多个角色，"
            "低清晰度，肢体畸形，颜色漂移，角色服装不一致，"
            "每行少于8个角色，每行多于8个角色，每行6个角色，每行7个角色，每行9个角色，"
            "第9列，第9个角色，额外角色，跨格角色，合并格子，"
            "漫画分镜，海报构图，大插画，角色出格，角色重叠，"
            "多余的腿，缺少腿，腿交叉错误，四肢方向错误，双前腿同时向前，"
            "双后腿同时向后，人类跑步姿势，向左跑，面朝左，正面跑，背面跑，"
            "跑步方向混乱"
        ),
    }
    if seed is not None:
        parameters["seed"] = seed

    payload = {
        "model": model,
        "input": {
            "messages": [
                {
                    "role": "user",
                    "content": content,
                }
            ]
        },
        "parameters": parameters,
    }
    response = json_post(
        endpoint,
        payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )

    try:
        generated_url = response["output"]["choices"][0]["message"]["content"][0]["image"]
    except (KeyError, IndexError) as exc:
        raise RuntimeError(f"DashScope response did not contain an image URL:\n{json.dumps(response, ensure_ascii=False)[:1200]}") from exc

    return download_image(generated_url)


def sheet_prompt(display_name: str, style: str, description: str) -> str:
    return f"""
Use the uploaded reference image as the character identity for a desktop pet named {display_name}.
Create exactly one complete spritesheet image. The whole image must be the final spritesheet.

Canvas:
- Aspect ratio: 2:1.
- The final image is one single spritesheet with exactly 4 horizontal rows and exactly 8 vertical columns.
- This means exactly 32 separate character drawings total.
- Every row must contain exactly 8 character drawings. Not 6. Not 7. Not 9. Exactly 8.
- Every row has exactly these column slots: column 1, column 2, column 3, column 4, column 5, column 6, column 7, column 8.
- There is no column 9. Do not draw a ninth character after column 8.
- Every column position must be evenly spaced from left to right, using the full width as 8 equal slots.
- Imagine the canvas is divided into 32 equal invisible square cells: 4 rows x 8 columns. Place one and only one character inside each cell.
- The character must stay completely inside its own invisible cell. Do not let any character cross into another cell.
- Leave consistent empty green padding around each character inside its cell.
- Do not draw visible grid lines, borders, text, labels, numbers, scenery, props, shadows, or UI.
- Use a flat pure chroma-key green background (#00FF00) everywhere outside the character.

Rows:
- Row 1 must contain exactly 8 idle character poses, calm breathing/blinking, one character per cell.
- Row 2 must contain exactly 8 running character poses, one character per cell.
- Row 2 direction is mandatory: every running frame must be a side-view pose facing right and running toward the right.
- In Row 2, the character's head, face, nose, chest, body direction, and motion direction must all point to the right in every one of the 8 cells.
- Do not draw Row 2 facing left, facing forward, facing backward, diagonal, or mixed directions.
- If the uploaded character is a four-legged animal, Row 2 running gait must be anatomically consistent. Use this exact 8-frame leg cycle:
  frame 1: left front leg reaches forward, left rear leg pushes backward, right front leg moves backward, right rear leg reaches forward.
  frame 2: left front leg vertical under shoulder, left rear leg lifting forward, right front leg lifting forward, right rear leg vertical under hip.
  frame 3: left front leg moves backward, left rear leg reaches forward, right front leg reaches forward, right rear leg pushes backward.
  frame 4: left front leg lifting forward, left rear leg vertical under hip, right front leg vertical under shoulder, right rear leg lifting forward.
  frame 5: repeat frame 1 with a slightly different body bounce.
  frame 6: repeat frame 2 with a slightly different body bounce.
  frame 7: repeat frame 3 with a slightly different body bounce.
  frame 8: repeat frame 4 with a slightly different body bounce.
- For four-legged characters in Row 2, diagonal leg pairs must alternate clearly: left front + right rear forward, then right front + left rear forward.
- If the uploaded character is not four-legged, use an anatomically natural 8-frame running cycle for that character instead.
- Do not draw impossible limbs, missing limbs, extra limbs, crossed limbs, or both front legs forward at the same time for four-legged characters.
- Row 3 must contain exactly 8 failed character poses, disappointed or confused but still cute, one character per cell.
- Row 4 must contain exactly 8 tail-wagging character poses, the character happily wagging its tail, one character per cell.
- In Row 4, the tail movement must be the main visible change from frame to frame. Do not make the character wave a paw or hand.

Style: {style}.
Character notes: {description}.

Strict requirements:
- Same character, same costume, same colors, same proportions in every frame.
- Green screen background only, no gradients and no texture.
- Full body visible in every frame.
- Keep every character centered inside its own equal-sized cell with consistent size.
- Each row must read left-to-right as a smooth looping animation.
- The image itself should already look like an animation spritesheet, not a poster, comic page, or collage.
- Do not merge cells.
- Do not create large illustrations spanning multiple cells.
- Do not make rows with fewer than 8 characters.
- Do not make any row with 6 or 7 characters.
- Do not make rows with more than 8 characters.
- Do not make any row with 9 characters.
- Do not add an extra pose at the far right edge.
- Do not crop off heads, ears, tails, paws, or body parts.
""".strip()


def generate_full_sheet(args: argparse.Namespace) -> Image.Image:
    env_name = "DASHSCOPE_API_KEY" if args.provider == "dashscope" else "OPENAI_API_KEY"
    api_key = os.environ.get(env_name)
    if not api_key:
        raise SystemExit(f"{env_name} is required unless you pass --from-static or --rebuild-from-strips.")

    print(f"Generating one 4x8 spritesheet with {args.provider}...", file=sys.stderr)
    prompt = sheet_prompt(args.name, args.style, args.description)
    if args.provider == "dashscope":
        sheet = dashscope_image_edit(
            api_key=api_key,
            model=args.model,
            endpoint=args.dashscope_endpoint,
            reference_path=args.input,
            prompt=prompt,
            size=args.size,
            prompt_extend=args.prompt_extend,
            seed=args.seed,
        )
    else:
        sheet = openai_image_edit(
            api_key=api_key,
            model=args.model,
            reference_path=args.input,
            prompt=prompt,
            size=args.size,
            output_format=args.output_format,
            quality=args.quality,
        )
    if args.keep_intermediates:
        args.output.mkdir(parents=True, exist_ok=True)
        sheet.save(args.output / f"raw-spritesheet.{args.output_format}")
    return remove_chroma_background(normalize_sheet(sheet))


def generate_action_frames(args: argparse.Namespace, action: RuntimeRow) -> list[Image.Image]:
    if args.rebuild_from_strips:
        strip_dir = args.rebuild_from_strips.expanduser().resolve()
        strip_path = strip_dir / f"{action.name}-strip.png"
        if action.name == "running" and not strip_path.exists():
            strip_path = strip_dir / "running-right-strip.png"
        if action.name == "tail-wagging" and not strip_path.exists():
            strip_path = strip_dir / "waving-strip.png"
        if not strip_path.exists():
            raise SystemExit(f"Missing strip image: {strip_path}")
        return split_action_strip(Image.open(strip_path), action.frame_count, mode=args.split_mode)

    if args.from_static:
        return static_frames(args.input, action.frame_count)

    env_name = "DASHSCOPE_API_KEY" if args.provider == "dashscope" else "OPENAI_API_KEY"
    api_key = os.environ.get(env_name)
    if not api_key:
        raise SystemExit(f"{env_name} is required unless you pass --from-static or --rebuild-from-strips.")

    print(f"Generating {action.name} ({action.frame_count} frames) with {args.provider}...", file=sys.stderr)
    prompt = action_prompt(action, args.name, args.style, args.description)
    if args.provider == "dashscope":
        strip = dashscope_image_edit(
            api_key=api_key,
            model=args.model,
            endpoint=args.dashscope_endpoint,
            reference_path=args.input,
            prompt=prompt,
            size=args.size,
            prompt_extend=args.prompt_extend,
            seed=args.seed,
        )
    else:
        strip = openai_image_edit(
            api_key=api_key,
            model=args.model,
            reference_path=args.input,
            prompt=prompt,
            size=args.size,
            output_format=args.output_format,
            quality=args.quality,
        )
    if args.keep_intermediates:
        args.output.mkdir(parents=True, exist_ok=True)
        strip.save(args.output / f"{action.name}-strip.{args.output_format}")
    return split_action_strip(strip, action.frame_count, mode=args.split_mode)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a desktop pet spritesheet package.")
    parser.add_argument("--input", type=Path, help="Reference character image path.")
    parser.add_argument("--name", required=True, help="Pet display name.")
    parser.add_argument("--description", default="A cute desktop companion.", help="Pet description.")
    parser.add_argument("--style", default="cute sticker-like 2D character art", help="Visual style prompt.")
    parser.add_argument("--id", dest="pet_id", help="Pet id. Defaults to a slug from --name.")
    parser.add_argument("--output", type=Path, default=Path("GeneratedPets"), help="Output root directory.")
    parser.add_argument("--provider", default="dashscope", choices=["dashscope", "openai"], help="Image API provider.")
    parser.add_argument("--model", default="wan2.6-image", help="Image model name.")
    parser.add_argument("--size", default="1536*768", help="Output size for the generated 4x8 spritesheet.")
    parser.add_argument("--quality", default="medium", choices=["low", "medium", "high", "auto"])
    parser.add_argument("--output-format", default="png", choices=["png", "webp"])
    parser.add_argument(
        "--dashscope-endpoint",
        default="https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation",
        help="DashScope Wan2.6 endpoint. Use dashscope-intl.aliyuncs.com or dashscope-us.aliyuncs.com if your key is from those regions.",
    )
    parser.add_argument("--prompt-extend", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--seed", type=int)
    parser.add_argument(
        "--split-mode",
        default="resize-strip",
        choices=["resize-strip", "crop-fit"],
        help="Only used with --rebuild-from-strips. Turns old action strips into 192x192 frames.",
    )
    parser.add_argument("--from-static", action="store_true", help="Skip the image API and repeat the reference image into frames.")
    parser.add_argument(
        "--rebuild-from-strips",
        type=Path,
        help="Reuse old idle/running-right/tail-wagging-or-waving/failed strip PNGs from a generated pet directory and rebuild a 4x8 spritesheet.webp.",
    )
    parser.add_argument("--keep-intermediates", action="store_true", help="Save generated action strips.")
    parser.add_argument("--install", action="store_true", help="Copy pet.json and spritesheet.webp into ~/.codex/pets/<pet-id>.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.input:
        args.input = args.input.expanduser().resolve()
    if not args.rebuild_from_strips:
        if not args.input:
            raise SystemExit("--input is required unless you pass --rebuild-from-strips.")
        if not args.input.exists():
            raise SystemExit(f"Input image does not exist: {args.input}")

    pet_id = slugify(args.pet_id or args.name)
    package_dir = args.output.expanduser().resolve() / pet_id
    package_dir.mkdir(parents=True, exist_ok=True)
    args.output = package_dir

    if args.from_static or args.rebuild_from_strips:
        action_frames: dict[str, list[Image.Image]] = {}
        for action in SOURCE_ACTIONS:
            action_frames[action.name] = generate_action_frames(args, action)
        sheet = build_sheet(action_frames)
    else:
        sheet = generate_full_sheet(args)

    sheet.save(package_dir / "spritesheet.webp", "WEBP", lossless=True, quality=100, method=6)
    build_preview(sheet).save(package_dir / "preview.png")
    write_manifest(package_dir, pet_id, args.name, args.description)
    zip_path = zip_package(package_dir, pet_id)

    print(f"Wrote {package_dir / 'spritesheet.webp'}")
    print(f"Wrote {package_dir / 'pet.json'}")
    print(f"Wrote {package_dir / 'preview.png'}")
    print(f"Wrote {zip_path}")

    if args.install:
        try:
            destination = install_package(package_dir, pet_id)
            print(f"Installed to {destination}")
        except RuntimeError as exc:
            print(f"Install skipped: {exc}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
