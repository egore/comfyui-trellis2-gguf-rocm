#!/usr/bin/env bash
# Trellis2 GGUF Model Downloader — Linux + ROCm variant
cd "$(dirname "$0")" || exit 1

echo ""
echo "============================================"
echo "  Trellis2 GGUF Model Downloader (Q4_K_M)"
echo "  Linux + ROCm variant"
echo "============================================"
echo ""

# Locate Python from comfy-env venv
VENV_DIR="$(pwd)/comfy-env"
if [ -x "${VENV_DIR}/bin/python" ]; then
    PYTHON_EXE="${VENV_DIR}/bin/python"
    echo "Using venv Python: ${PYTHON_EXE}"
elif command -v python3 &>/dev/null; then
    PYTHON_EXE="python3"
    echo "Using system Python: ${PYTHON_EXE}"
else
    echo "ERROR: No Python found."
    exit 1
fi
echo ""

$PYTHON_EXE -c '
import os, sys, requests

SCRIPT_DIR = os.environ.get("COMFY_ROOT", os.getcwd())
MODEL_DIR = os.path.join(SCRIPT_DIR, "ComfyUI", "models", "Trellis2")

if not os.path.isdir(os.path.join(SCRIPT_DIR, "ComfyUI")):
    print(f"[ERROR] Could not find ComfyUI folder at:")
    print(f"  {os.path.join(SCRIPT_DIR, 'ComfyUI')}")
    print("Make sure this script is in the same folder as the ComfyUI directory.")
    sys.exit(1)

os.makedirs(MODEL_DIR, exist_ok=True)

REPO_ID = "Aero-Ex/Trellis2-GGUF"
BASE_URL = f"https://huggingface.co/{REPO_ID}/resolve/main"

FILES = [
    # pipeline config
    ("pipeline.json",                                                    "Pipeline Config"),
    # GGUF models + their JSON configs
    ("refiner/ss_flow_img_dit_1_3B_64_bf16.json",                       "Sparse Structure Config"),
    ("refiner/ss_flow_img_dit_1_3B_64_bf16_Q4_K_M.gguf",               "Sparse Structure Model"),
    ("shape/slat_flow_img2shape_dit_1_3B_512_bf16.json",                "Shape 512 Config"),
    ("shape/slat_flow_img2shape_dit_1_3B_512_bf16_Q4_K_M.gguf",        "Shape 512 Model"),
    ("shape/slat_flow_img2shape_dit_1_3B_1024_bf16.json",               "Shape 1024 Config"),
    ("shape/slat_flow_img2shape_dit_1_3B_1024_bf16_Q4_K_M.gguf",       "Shape 1024 Model"),
    ("texture/slat_flow_imgshape2tex_dit_1_3B_512_bf16.json",           "Texture 512 Config"),
    ("texture/slat_flow_imgshape2tex_dit_1_3B_512_bf16_Q4_K_M.gguf",   "Texture 512 Model"),
    ("texture/slat_flow_imgshape2tex_dit_1_3B_1024_bf16.json",          "Texture 1024 Config"),
    ("texture/slat_flow_imgshape2tex_dit_1_3B_1024_bf16_Q4_K_M.gguf",  "Texture 1024 Model"),
    # Encoder/decoder safetensors (always needed)
    ("decoders/Stage1/ss_dec_conv3d_16l8_fp16.json",                    "SS Decoder Config"),
    ("decoders/Stage1/ss_dec_conv3d_16l8_fp16.safetensors",             "SS Decoder Model"),
    ("decoders/Stage2/shape_dec_next_dc_f16c32_fp16.json",              "Shape Decoder Config"),
    ("decoders/Stage2/shape_dec_next_dc_f16c32_fp16.safetensors",       "Shape Decoder Model"),
    ("decoders/Stage2/tex_dec_next_dc_f16c32_fp16.json",                "Texture Decoder Config"),
    ("decoders/Stage2/tex_dec_next_dc_f16c32_fp16.safetensors",         "Texture Decoder Model"),
    ("encoders/shape_enc_next_dc_f16c32_fp16.json",                     "Shape Encoder Config"),
    ("encoders/shape_enc_next_dc_f16c32_fp16.safetensors",              "Shape Encoder Model"),
]

def download_file(url, dest, label):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".tmp"
    try:
        r = requests.get(url, stream=True, timeout=30)
        r.raise_for_status()
        total = int(r.headers.get("content-length", 0))
        downloaded = 0
        with open(tmp, "wb") as f:
            for chunk in r.iter_content(chunk_size=8 * 1024 * 1024):
                f.write(chunk)
                downloaded += len(chunk)
                if total:
                    pct = downloaded / total * 100
                    bar_len = 30
                    filled = int(bar_len * downloaded // total)
                    bar = "=" * filled + "-" * (bar_len - filled)
                    mb_done = downloaded / (1024 * 1024)
                    mb_total = total / (1024 * 1024)
                    sys.stdout.write(f"\r  [{bar}] {pct:5.1f}%  {mb_done:.0f}/{mb_total:.0f} MB")
                    sys.stdout.flush()
        os.replace(tmp, dest)
        if total > 1024 * 1024:
            print()
        return True
    except Exception as e:
        print(f"\n  FAILED: {e}")
        if os.path.exists(tmp):
            os.remove(tmp)
        return False

print(f"Downloading Trellis2 GGUF models (Q4_K_M)")
print(f"Repo:   {REPO_ID}")
print(f"Target: {MODEL_DIR}\n")

failed = []
for i, (filename, label) in enumerate(FILES, 1):
    dest = os.path.join(MODEL_DIR, filename)
    if os.path.isfile(dest):
        size_mb = os.path.getsize(dest) / (1024 * 1024)
        if size_mb > 1:
            print(f"[{i:2d}/{len(FILES)}] {label:25s}  already exists ({size_mb:.0f} MB)")
        else:
            print(f"[{i:2d}/{len(FILES)}] {label:25s}  already exists")
        continue
    url = f"{BASE_URL}/{filename}"
    print(f"[{i:2d}/{len(FILES)}] {label:25s}  downloading...")
    if not download_file(url, dest, label):
        failed.append(filename)
    else:
        size_mb = os.path.getsize(dest) / (1024 * 1024)
        if size_mb > 1:
            print(f"  done ({size_mb:.0f} MB)")
        else:
            print(f"  done")

print("\n" + "=" * 50)
if not failed:
    print("All models downloaded successfully!")
    print(f"\nFiles are in: {MODEL_DIR}")
else:
    print(f"{len(failed)} download(s) failed:")
    for f in failed:
        print(f"  - {f}")
print("=" * 50 + "\n")
'
