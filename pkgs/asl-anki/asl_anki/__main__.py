"""asl-anki: Generate Anki flashcards for ASL vocabulary via signasl.org."""

import argparse
import hashlib
import logging
import re
import subprocess
import tempfile
import time
from pathlib import Path

import genanki
import requests
from bs4 import BeautifulSoup
import yt_dlp

logger = logging.getLogger(__name__)

SIGNASL_BASE = "https://www.signasl.org/sign"
HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (X11; Linux x86_64; rv:124.0) Gecko/20100101 Firefox/124.0"
    )
}

# Stable IDs derived from fixed strings so re-importing updates existing notes
# rather than creating duplicates. genanki requires IDs in range [1<<30, 1<<31).
def _stable_id(seed: str) -> int:
    h = int(hashlib.md5(seed.encode()).hexdigest(), 16)
    lo, hi = 1 << 30, 1 << 31
    return lo + (h % (hi - lo))

ASL_MODEL = genanki.Model(
    model_id=_stable_id("asl-anki-model-v1"),
    name="ASL Sign",
    fields=[{"name": "ASL"}, {"name": "Sign"}],
    templates=[
        {
            "name": "ASL → Sign",
            "qfmt": "<div style='font-size:2em;font-weight:bold'>{{ASL}}</div>",
            "afmt": (
                "{{FrontSide}}"
                "<hr>"
                "<div style='text-align:center'>{{Sign}}</div>"
            ),
        },
        {
            "name": "Sign → ASL",
            "qfmt": "<div style='text-align:center'>{{Sign}}</div>",
            "afmt": (
                "{{FrontSide}}"
                "<hr>"
                "<div style='font-size:2em;font-weight:bold;text-align:center'>{{ASL}}</div>"
            ),
        },
    ],
)


def sanitize_name(word: str) -> str:
    """'Thank You' -> 'thank_you'"""
    name = word.lower().strip()
    name = re.sub(r"[^\w\s-]", "", name)
    name = re.sub(r"[\s-]+", "_", name)
    name = name.strip("_")
    return name or "unknown"


def find_video_url(word: str) -> tuple[str | None, str]:
    """
    Scrape signasl.org for a word's first video URL.
    Returns (url, kind) where kind is 'mp4', 'youtube', 'not_found', or 'error'.
    """
    url = f"{SIGNASL_BASE}/{word.lower().replace(' ', '-')}"
    logger.debug("Fetching %s", url)

    try:
        resp = requests.get(url, headers=HEADERS, timeout=15)
        resp.raise_for_status()
    except requests.exceptions.HTTPError as e:
        if e.response is not None and e.response.status_code == 404:
            return None, "not_found"
        logger.error("HTTP error for '%s': %s", word, e)
        return None, "error"
    except requests.exceptions.RequestException as e:
        logger.error("Network error for '%s': %s", word, e)
        return None, "error"

    soup = BeautifulSoup(resp.text, "html.parser")

    # 1. Direct <video> or <source> tags
    for tag in soup.find_all(["video", "source"]):
        src = tag.get("src", "") or tag.get("data-src", "")
        if src and re.search(r"\.mp4", src, re.IGNORECASE):
            if src.startswith("//"):
                src = "https:" + src
            elif src.startswith("/"):
                src = "https://www.signasl.org" + src
            logger.debug("Found direct MP4: %s", src)
            return src, "mp4"

    # 2. YouTube embeds
    for iframe in soup.find_all("iframe"):
        src = iframe.get("src", "")
        if "youtube.com" in src or "youtu.be" in src:
            if src.startswith("//"):
                src = "https:" + src
            logger.debug("Found YouTube embed: %s", src)
            return src, "youtube"

    # 3. Any anchor or data attribute pointing to mp4
    for tag in soup.find_all(True):
        for attr in ("href", "data-video", "data-src", "data-url"):
            val = tag.get(attr, "")
            if val and re.search(r"\.mp4", val, re.IGNORECASE):
                if val.startswith("//"):
                    val = "https:" + val
                elif val.startswith("/"):
                    val = "https://www.signasl.org" + val
                logger.debug("Found MP4 in attr %s: %s", attr, val)
                return val, "mp4"

    return None, "not_found"


def download_mp4(url: str, dest: Path) -> bool:
    """Download a direct .mp4 URL via requests."""
    logger.debug("Downloading MP4 to %s", dest)
    try:
        with requests.get(url, headers=HEADERS, timeout=60, stream=True) as resp:
            resp.raise_for_status()
            with open(dest, "wb") as f:
                for chunk in resp.iter_content(chunk_size=65536):
                    f.write(chunk)
        return True
    except requests.exceptions.RequestException as e:
        logger.error("Download failed for %s: %s", url, e)
        return False


def download_youtube(url: str, dest_dir: Path) -> Path | None:
    """
    Download a YouTube URL via yt-dlp Python API.
    Returns path to downloaded file, or None on failure.
    """
    # Normalise embed URLs
    url = re.sub(r"/embed/([^?&]+)", r"/watch?v=\1", url)

    ydl_opts = {
        "format": "bestvideo[ext=mp4]/bestvideo",
        "outtmpl": str(dest_dir / "video.%(ext)s"),
        "quiet": not logger.isEnabledFor(logging.DEBUG),
        "no_warnings": not logger.isEnabledFor(logging.DEBUG),
    }

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([url])
    except Exception as e:
        logger.error("yt-dlp failed for %s: %s", url, e)
        return None

    files = sorted(dest_dir.glob("video.*"))
    if not files:
        logger.error("yt-dlp produced no output in %s", dest_dir)
        return None
    return files[0]


def get_video_dimensions(path: Path) -> tuple[int, int] | None:
    """Return (width, height) of the first video stream, or None on failure."""
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height",
        "-of", "csv=s=x:p=0",
        str(path),
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        w, h = map(int, result.stdout.strip().split("x"))
        return w, h
    except Exception:
        return None


def detect_motion_crop(input_path: Path, pad_fraction: float = 0.08) -> dict | None:
    """
    Two-pass motion bounding box detection via ffmpeg tblend+cropdetect.

    tblend=all_mode=difference produces a frame showing only what changed
    between consecutive frames. cropdetect then finds the non-black bounding
    box of that difference image — i.e., where motion occurred.

    Returns {'x': X, 'y': Y, 'w': W, 'h': H, 'vid_w': VW, 'vid_h': VH}
    or None if detection fails or no motion is found.
    """
    dims = get_video_dimensions(input_path)
    if dims is None:
        logger.warning("Could not read video dimensions; skipping motion crop.")
        return None
    vid_w, vid_h = dims

    cmd = [
        "ffmpeg", "-loglevel", "error",
        "-i", str(input_path),
        "-vf", "tblend=all_mode=difference,cropdetect=limit=16:round=2:reset=0",
        "-f", "null", "-",
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        logger.warning("Motion detection timed out.")
        return None
    except FileNotFoundError:
        logger.error("ffmpeg not found during motion detection.")
        return None

    # Parse all cropdetect output lines; format: "x1:N x2:N y1:N y2:N w:N h:N ..."
    pattern = re.compile(r"x1:(\d+)\s+x2:(\d+)\s+y1:(\d+)\s+y2:(\d+)")
    x1s, x2s, y1s, y2s = [], [], [], []
    for line in result.stderr.splitlines():
        m = pattern.search(line)
        if m:
            x1s.append(int(m.group(1)))
            x2s.append(int(m.group(2)))
            y1s.append(int(m.group(3)))
            y2s.append(int(m.group(4)))

    if not x1s:
        logger.debug("cropdetect found no motion; skipping motion crop.")
        return None

    # Union bounding box across all frames
    bx1, bx2 = min(x1s), max(x2s)
    by1, by2 = min(y1s), max(y2s)

    # Pad outward by pad_fraction of the detected region (minimum 8px each side)
    pad_x = max(int((bx2 - bx1) * pad_fraction), 8)
    pad_y = max(int((by2 - by1) * pad_fraction), 8)

    x = max(0, bx1 - pad_x)
    y = max(0, by1 - pad_y)
    w = min(vid_w, bx2 + pad_x) - x
    h = min(vid_h, by2 + pad_y) - y

    # ffmpeg crop requires even dimensions
    w -= w % 2
    h -= h % 2

    if w <= 0 or h <= 0:
        logger.debug("Motion crop box degenerate; skipping.")
        return None

    logger.debug(
        "Motion crop: w=%d h=%d x=%d y=%d  (source: %dx%d)", w, h, x, y, vid_w, vid_h
    )
    return {"x": x, "y": y, "w": w, "h": h, "vid_w": vid_w, "vid_h": vid_h}


def process_video(
    input_path: Path,
    output_path: Path,
    crop: dict | None = None,
    crop_vertical: bool = False,
) -> bool:
    """
    Convert video → GIF via ffmpeg | gifski pipeline.
    Mirrors the agif fish function: -an, scale, yuv4mpegpipe → gifski stdin.

    crop: result of detect_motion_crop(); None means no cropping.
    crop_vertical: if False (default), only horizontal bounds are applied
                   and the full height is preserved.
    """
    fps = 15
    resolution = 480

    filters: list[str] = []

    if crop is not None:
        cx, cy = crop["x"], crop["y"]
        cw, ch = crop["w"], crop["h"]
        if crop_vertical:
            filters.append(f"crop={cw}:{ch}:{cx}:{cy}")
        else:
            # Horizontal only: keep full video height, x-offset only
            filters.append(f"crop={cw}:{crop['vid_h']}:{cx}:0")

    filters.append(f"fps={fps},scale=-2:{resolution}:flags=lanczos")
    filter_str = ",".join(filters)

    loglevel = "error" if not logger.isEnabledFor(logging.DEBUG) else "warning"

    ffmpeg_cmd = [
        "ffmpeg",
        "-loglevel", loglevel,
        "-i", str(input_path),
        "-an",
        "-filter:v", filter_str,
        "-f", "yuv4mpegpipe",
        "-",
    ]

    gifski_cmd = [
        "gifski",
        "-o", str(output_path),
        "--fps", str(fps),
        "--quality", "85",
        "--lossy-quality", "30",
        "-",
    ]

    logger.debug("ffmpeg pipeline → %s", output_path)

    try:
        ffmpeg_proc = subprocess.Popen(
            ffmpeg_cmd,
            stdout=subprocess.PIPE,
            stderr=None,
        )
        assert ffmpeg_proc.stdout is not None
        gifski_proc = subprocess.Popen(
            gifski_cmd,
            stdin=ffmpeg_proc.stdout,
            stdout=subprocess.DEVNULL,
            stderr=None,
        )
        ffmpeg_proc.stdout.close()
        gifski_proc.wait()
        ffmpeg_proc.wait()

        if ffmpeg_proc.returncode != 0:
            logger.error("ffmpeg exited with %d", ffmpeg_proc.returncode)
            return False
        if gifski_proc.returncode != 0:
            logger.error("gifski exited with %d", gifski_proc.returncode)
            return False
        return True

    except FileNotFoundError as e:
        logger.error("Tool not found — ensure ffmpeg and gifski are in PATH: %s", e)
        return False
    except Exception as e:
        logger.error("Video processing error: %s", e)
        return False


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate ASL Anki flashcards from a word list.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Example:\n"
            "  asl-anki words.txt\n"
            "  asl-anki words.txt --output-dir ./media --verbose\n\n"
            "Output:\n"
            "  anki_media/   — directory of GIF files\n"
            "  asl_deck.tsv  — tab-separated Anki import file\n"
            "  not_found.txt — words for which no video was found\n"
        ),
    )
    parser.add_argument(
        "words_file",
        type=argparse.FileType("r"),
        help="Text file with one ASL vocabulary word per line.",
    )
    parser.add_argument(
        "--output-dir",
        default="anki_media",
        metavar="DIR",
        help="Directory to save GIF files (default: anki_media/).",
    )
    parser.add_argument(
        "--output",
        default="asl_deck.apkg",
        metavar="FILE",
        help="Output .apkg file for Anki import (default: asl_deck.apkg).",
    )
    parser.add_argument(
        "--deck-name",
        default="ASL Vocabulary",
        metavar="NAME",
        help="Anki deck name (default: 'ASL Vocabulary').",
    )
    parser.add_argument(
        "--tags",
        nargs="+",
        default=[],
        metavar="TAG",
        help="Tags to apply to every card (e.g. --tags unit_5 chapter_1).",
    )
    parser.add_argument(
        "--no-crop-horizontal",
        dest="crop_horizontal",
        action="store_false",
        default=True,
        help="Disable automatic horizontal cropping to region of motion.",
    )
    parser.add_argument(
        "--crop-vertical",
        action="store_true",
        default=False,
        help="Also crop vertically to the region of motion (opt-in).",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Enable debug logging.",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s: %(message)s",
    )

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    words = [line.strip() for line in args.words_file if line.strip()]
    args.words_file.close()

    if not words:
        logger.error("No words found in input file.")
        raise SystemExit(1)

    deck = genanki.Deck(
        deck_id=_stable_id(f"asl-anki-deck-{args.deck_name}"),
        name=args.deck_name,
    )
    media_files: list[str] = []
    not_found: list[str] = []

    for idx, word in enumerate(words, 1):
        logger.info("[%d/%d] %s", idx, len(words), word)
        safe_name = sanitize_name(word)
        gif_name = f"{safe_name}.gif"
        gif_path = output_dir / gif_name

        # Skip download if GIF already exists from a previous run
        if gif_path.exists():
            logger.info("  Skipping (already exists): %s", gif_name)
        else:
            # --- Phase 1: find video ---
            video_url, url_type = find_video_url(word)

            if url_type in ("not_found", "error") or video_url is None:
                logger.warning("  Not found: %s", word)
                not_found.append(word)
                time.sleep(1)
                continue

            # --- Phase 2: download & process ---
            do_crop = args.crop_horizontal or args.crop_vertical

            with tempfile.TemporaryDirectory(prefix="asl_anki_") as tmpdir:
                tmp = Path(tmpdir)
                video_path: Path | None = None

                if url_type == "mp4":
                    raw_path = tmp / "raw.mp4"
                    if download_mp4(video_url, raw_path):
                        video_path = raw_path
                elif url_type == "youtube":
                    video_path = download_youtube(video_url, tmp)

                if video_path is None:
                    logger.error("  Download failed: %s", word)
                    not_found.append(word)
                    time.sleep(1)
                    continue

                crop = detect_motion_crop(video_path) if do_crop else None
                if do_crop and crop is None:
                    logger.debug("  Motion detection yielded no crop; encoding full frame.")
                ok = process_video(
                    video_path, gif_path,
                    crop=crop,
                    crop_vertical=args.crop_vertical,
                )

            if not ok:
                logger.error("  Failed to produce GIF for: %s", word)
                not_found.append(word)
                gif_path.unlink(missing_ok=True)
                time.sleep(1)
                continue

            logger.info("  -> %s", gif_name)
            time.sleep(1.5)

        # --- Phase 3: add note to deck ---
        note = genanki.Note(
            model=ASL_MODEL,
            fields=[word.upper(), f'<img src="{gif_name}">'],
            tags=args.tags,
        )
        deck.add_note(note)
        media_files.append(str(gif_path))

    # --- Write .apkg ---
    package = genanki.Package(deck)
    package.media_files = media_files
    package.write_to_file(args.output)

    if not_found:
        not_found_path = Path("not_found.txt")
        not_found_path.write_text("\n".join(not_found) + "\n")
        logger.info("%d word(s) not found — see not_found.txt", len(not_found))

    n_cards = len(media_files)
    logger.info("Done. %d/%d cards written to %s", n_cards, len(words), args.output)


if __name__ == "__main__":
    main()
