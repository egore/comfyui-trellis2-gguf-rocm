#!/bin/bash

# Install in this order
# pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm7.2
# pip install comfy-cli
# comfy install --restore

source comfy-env/bin/activate
pip install --upgrade comfy-cli onnxruntime
comfy update

# ROCm / gfx1102 (RX 7600 XT) runtime settings
export HSA_OVERRIDE_GFX_VERSION=11.0.0        # Needed for gfx1102 compatibility with some ROCm libs
export ATTN_BACKEND=sdpa                       # Force PyTorch SDPA — reliable on ROCm (avoids flash_attn/xformers issues)
export TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1

comfy launch -- --use-pytorch-cross-attention
