# ComfyUI Trellis 2 GGUF — ROCm

Trellis2 GGUF custom nodes for ComfyUI, patched to build and run on **AMD GPUs via ROCm**.

Inspired by https://www.youtube.com/watch?v=FuFm8zBHDWI.
Started from the Windows installer at https://pixel-artistry.com/trellis2gguf and adapted to Linux + ROCm 7.2.

## Tested Environment

| Component | Version |
|-----------|---------|
| GPU | AMD Radeon RX 7600 XT (gfx1102) |
| OS | Arch Linux |
| ROCm | 7.2 |
| Python | 3.14 |
| PyTorch | 2.11.0+rocm7.2 |

## Setup

### 1. Initial ComfyUI installation

```bash
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm7.2
pip install comfy-cli
comfy install --restore
```

### 2. Install Trellis2 GGUF nodes

```bash
./install-trellis2-gguf-rocm.sh
```

This script clones the [ComfyUI-Trellis2-GGUF](https://github.com/Aero-Ex/ComfyUI-Trellis2-GGUF) repo and builds all native extensions from source with ROCm/HIP patches applied automatically.

### 3. Run ComfyUI

```bash
./run.sh
```

Sets the required ROCm environment variables (`HSA_OVERRIDE_GFX_VERSION`, `ATTN_BACKEND=sdpa`) and launches ComfyUI.

## What the install script patches

The original Trellis2 GGUF nodes depend on several CUDA-only C++ extensions. The install script applies the following ROCm fixes at build time (no upstream changes needed):

### nvdiffrast
- Replaces `__frcp_rz` (CUDA intrinsic) with `__fdividef`
- Casts warp sync masks to 64-bit (ROCm 7.2 requirement)
- Removes `-lineinfo` NVCC flag
- Removes the `cudaraster` module (uses NVIDIA PTX assembly) and provides runtime stubs — the **OpenGL rasterizer** (`RasterizeGLContext`) still works
- Rewrites `framework.h` with conditional HIP/CUDA includes and `NVDR_CHECK` macros
- Fixes `uint64_t` narrowing (clang is stricter than NVCC)
- Renames `.cpp` → `.cu` so `hipcc` compiles files that need CUDA→HIP header translation

### nvdiffrec_render
- Removes `-lcuda -lnvrtc` linker flags
- Fixes 64-bit warp sync masks
- Renames `.cpp` → `.cu` and patches CUDA headers to HIP equivalents

### CuMesh
- Replaces `::cuda::std::tuple` with `rocprim::tuple`
- Fixes brace-init for explicit rocprim constructors
- Adds `__host__` to `Vec3f` default constructor
- Removes NVCC-only compiler flags

### o-voxel / cubvh
- Ensures Eigen submodule is properly cloned

## Workflow Notes

The GGUF variant uses node names with a `_GGUF` suffix (e.g. `Trellis2SimplifyMesh_GGUF`). If loading workflows built for the original (non-GGUF) Trellis2 plugin, you'll need to append `_GGUF` to the node type names in the workflow JSON.