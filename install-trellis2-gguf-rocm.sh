#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")" || exit 1

node_name="Trellis2 GGUF (ROCm)"
echo "'$node_name' install script — adapted for Linux + ROCm"
echo ""

# ---- Colors ----
warning='\033[33m'
gray='\033[90m'
red='\033[91m'
green='\033[92m'
yellow='\033[93m'
blue='\033[94m'
magenta='\033[95m'
cyan='\033[96m'
white='\033[97m'
reset='\033[0m'

# ---- Locate Python from comfy-env venv ----
COMFY_ROOT="$(pwd)"
VENV_DIR="${COMFY_ROOT}/comfy-env"
COMFYUI_DIR="${COMFY_ROOT}/ComfyUI"
PYTHON_EXE=""

if [ -x "${VENV_DIR}/bin/python" ]; then
    PYTHON_EXE="${VENV_DIR}/bin/python"
    # Activate venv so pip installs go to the right place
    source "${VENV_DIR}/bin/activate"
elif command -v python3 &>/dev/null; then
    PYTHON_EXE="python3"
fi

if [ -z "$PYTHON_EXE" ]; then
    echo ""
    echo -e "    ${red}Could not find Python. Expected venv at ${yellow}${VENV_DIR}${reset}"
    echo ""
    exit 1
fi

echo -e "${green}Using Python: ${yellow}${PYTHON_EXE}${reset}"
echo ""

# ---- Check if ComfyUI is already running ----
PORT=8188
if ss -tlnp 2>/dev/null | grep -q ":${PORT} " || lsof -iTCP:"$PORT" -sTCP:LISTEN &>/dev/null; then
    echo ""
    echo -e "    ${white}ComfyUI${reset} is already running on port ${green}${PORT}${reset}. ${white}Please close it first.${reset}"
    echo ""
    exit 1
fi

# ---- Check versions (Python, Torch, ROCm) ----
echo -e "${green}:::::::::::::: Checking ${yellow}Python, Torch, ROCm ${green}versions${reset}"
echo ""

PYTHON_VERSION=$($PYTHON_EXE --version 2>&1 | awk '{print $2}' | cut -d. -f1,2)
TORCH_VERSION="Not found"
ROCM_VERSION="Not available"

TORCH_INFO=$($PYTHON_EXE -c "
import torch
v = torch.__version__.split('+')[0]
hip = torch.version.hip or 'N'
major_minor = '.'.join(v.split('.')[:2])
print(f'{major_minor}|{hip}')
" 2>/dev/null)

if [ -n "$TORCH_INFO" ]; then
    TORCH_VERSION="${TORCH_INFO%%|*}"
    ROCM_VERSION="${TORCH_INFO##*|}"
    if [ "$ROCM_VERSION" = "N" ]; then ROCM_VERSION="Not available"; fi
fi

echo -e "${green}   Python  : ${yellow}${PYTHON_VERSION}${reset}"
echo -e "${green}   PyTorch : ${yellow}${TORCH_VERSION}${reset}"
echo -e "${green}   ROCm    : ${yellow}${ROCM_VERSION}${reset}"
echo ""

# Validate we actually have ROCm torch
if [ "$ROCM_VERSION" = "Not available" ]; then
    echo -e "${red}ERROR: PyTorch does not appear to have ROCm/HIP support.${reset}"
    echo -e "${yellow}Install ROCm torch first, e.g.:${reset}"
    echo -e "${gray}  pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm7.2${reset}"
    exit 1
fi

# Soft version warnings (non-fatal)
WARNINGS=0
if ! $PYTHON_EXE -c "import torch; assert torch.cuda.is_available() or torch.hip.is_available()" 2>/dev/null; then
    # torch.cuda.is_available() returns True on ROCm builds too (HIP layer)
    if ! $PYTHON_EXE -c "import torch; assert torch.cuda.is_available()" 2>/dev/null; then
        echo -e "${warning}WARNING: ${red}torch.cuda.is_available() returned False. GPU acceleration may not work.${reset}"
        WARNINGS=1
    fi
fi

if [ "$WARNINGS" -eq 0 ]; then
    echo -e "${green}:::::::::::::: Versions look good!${reset}"
else
    echo -e "${yellow}:::::::::::::: Proceeding despite warnings...${reset}"
fi
echo ""

# ---- PIP args ----
PIPargs="--no-cache-dir --no-warn-script-location --timeout=1000 --retries 20"

# ---- ROCm environment for building CUDA/HIP extensions ----
export ROCM_HOME="${ROCM_HOME:-/opt/rocm}"
export HIP_HOME="${ROCM_HOME}"
export CUDA_HOME="${ROCM_HOME}"
export FORCE_CUDA=1
export HCC_AMDGPU_TARGET="gfx1102"
export AMDGPU_TARGETS="gfx1102"
export PYTORCH_ROCM_ARCH="gfx1102"

echo -e "${green}ROCm build env:${reset}"
echo -e "   ROCM_HOME=${ROCM_HOME}"
echo -e "   GPU arch=${HCC_AMDGPU_TARGET}"
echo ""

# ---- Model download (DINOv3) ----
model_url="https://huggingface.co/PIA-SPACE-LAB/dinov3-vitl-pretrain-lvd1689m/resolve/main/model.safetensors"
model_name="model.safetensors"
model_folder="${COMFY_ROOT}/ComfyUI/models/facebook/dinov3-vitl16-pretrain-lvd1689m"
config_url="https://huggingface.co/PIA-SPACE-LAB/dinov3-vitl-pretrain-lvd1689m/resolve/main/config.json"
config_name="config.json"
pre_config_url="https://huggingface.co/PIA-SPACE-LAB/dinov3-vitl-pretrain-lvd1689m/resolve/main/preprocessor_config.json"
pre_config_name="preprocessor_config.json"

mkdir -p "$model_folder"

# Only download if not already present
if [ ! -f "${model_folder}/${model_name}" ]; then
    echo -e "${green}Downloading ${yellow}DINOv3 ${model_name}${reset}"
    curl -L -o "${model_folder}/${model_name}" "$model_url"
else
    echo -e "${green}DINOv3 ${model_name} already exists, skipping download${reset}"
fi
curl -L -o "${model_folder}/${config_name}" "$config_url"
curl -L -o "${model_folder}/${pre_config_name}" "$pre_config_url"
echo -e "${yellow}DINOv3${green} model files ready${reset}"
echo ""

# ---- Site-packages path ----
SITE_PACKAGES=$($PYTHON_EXE -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)

if [ -d "$SITE_PACKAGES" ]; then
    find "$SITE_PACKAGES" -maxdepth 1 -type d -name '~*' -exec rm -rf {} + 2>/dev/null || true
fi

# Skip downloading LFS files
export GIT_LFS_SKIP_SMUDGE=1

# ---- Erase stale packages ----
erase_folder() {
    if [ -d "$1" ]; then rm -rf "$1"; fi
}

erase_folder "${SITE_PACKAGES}/o_voxel"
erase_folder "${SITE_PACKAGES}/o_voxel-0.0.1.dist-info"
erase_folder "${SITE_PACKAGES}/cumesh"
erase_folder "${SITE_PACKAGES}/cumesh-0.0.1.dist-info"
erase_folder "${SITE_PACKAGES}/cumesh-1.0.dist-info"
erase_folder "${SITE_PACKAGES}/nvdiffrast"
erase_folder "${SITE_PACKAGES}/nvdiffrast-0.4.0.dist-info"
erase_folder "${SITE_PACKAGES}/nvdiffrec_render"
erase_folder "${SITE_PACKAGES}/nvdiffrec_render-0.0.0.dist-info"
erase_folder "${SITE_PACKAGES}/flex_gemm"
erase_folder "${SITE_PACKAGES}/flex_gemm-0.0.1.dist-info"

# ---- Install ComfyUI-Trellis2-GGUF custom node ----
echo -e "${green}:::::::::::::: Installing${yellow} ${node_name}${reset}"
echo ""
CUSTOM_NODES="${COMFY_ROOT}/ComfyUI/custom_nodes"
TRELLIS_GGUF="${CUSTOM_NODES}/ComfyUI-Trellis2-GGUF"

if [ -d "$TRELLIS_GGUF" ]; then rm -rf "$TRELLIS_GGUF"; fi
git clone https://github.com/Aero-Ex/ComfyUI-Trellis2-GGUF "$TRELLIS_GGUF"
# Install requirements one-by-one so a single unavailable package (e.g. open3d
# on Python 3.14) doesn't block all the others
while IFS= read -r pkg || [ -n "$pkg" ]; do
    pkg=$(echo "$pkg" | xargs)  # trim whitespace
    if [ -z "$pkg" ]; then continue; fi
    if [ "${pkg:0:1}" = "#" ]; then continue; fi
    $PYTHON_EXE -m pip install "$pkg" --no-deps $PIPargs || \
        echo -e "${warning}WARNING: Failed to install '$pkg' — continuing...${reset}"
done < "${TRELLIS_GGUF}/requirements.txt"
$PYTHON_EXE -m pip install --upgrade huggingface_hub --no-deps $PIPargs
echo ""

# ---- Build CUDA/HIP extensions from source (ROCm) ----
# These packages contain CUDA kernels that can be compiled via HIP on ROCm.
# We build from source instead of using prebuilt Windows/CUDA wheels.

TMPBUILD="/tmp/trellis2-rocm-build"
mkdir -p "$TMPBUILD"

# Ensure build deps
$PYTHON_EXE -m pip install setuptools wheel ninja $PIPargs

# --- CuMesh (works with HIP after patching) ---
echo ""
echo -e "${green}:::::::::::::: Building ${yellow}CuMesh${green} from source (ROCm)${reset}"
if [ -d "${TMPBUILD}/CuMesh" ]; then rm -rf "${TMPBUILD}/CuMesh"; fi
git clone --recursive https://github.com/visualbruno/CuMesh.git "${TMPBUILD}/CuMesh"

# Patch CuMesh for ROCm/HIP compatibility
echo -e "${yellow}Applying ROCm patches to CuMesh...${reset}"

# 1) clean_up.cu: Replace ::cuda::std::tuple with rocprim::tuple on HIP
#    rocprim's DeviceRadixSort decomposer requires rocprim::tuple (not thrust or std)
#    IMPORTANT: do the text replacement BEFORE inserting the #define block
CLEAN_UP="${TMPBUILD}/CuMesh/src/clean_up.cu"
if [ -f "$CLEAN_UP" ]; then
    sed -i 's/::cuda::std::tuple/CUMESH_TUPLE/g' "$CLEAN_UP"
    sed -i '/#include <cub\/cub.cuh>/a \
#ifdef __HIP_PLATFORM_AMD__\
#include <rocprim\/types\/tuple.hpp>\
#define CUMESH_TUPLE rocprim::tuple\
#else\
#define CUMESH_TUPLE ::cuda::std::tuple\
#endif' "$CLEAN_UP"
    # rocprim::tuple has explicit constructors — brace init {a,b,c} won't work
    sed -i 's/return {key\.x, key\.y, key\.z};/return CUMESH_TUPLE<int\&, int\&, int\&>(key.x, key.y, key.z);/' "$CLEAN_UP"
fi

# 2) dtypes.cuh: Make Vec3f default constructor __host__ __device__ (not just __device__)
#    hipcub::DeviceSegmentedReduce needs a host-callable default constructor for identity values
DTYPES="${TMPBUILD}/CuMesh/src/dtypes.cuh"
if [ -f "$DTYPES" ]; then
    sed -i 's/__device__ __forceinline__ Vec3f();/__host__ __device__ __forceinline__ Vec3f();/' "$DTYPES"
    sed -i 's/^__device__ __forceinline__ Vec3f::Vec3f() {/__host__ __device__ __forceinline__ Vec3f::Vec3f() {/' "$DTYPES"
fi

# 3) setup.py: Remove NVCC-specific flags from cubvh extension on HIP,
#    and init the cubvh eigen submodule
CUMESH_SETUP="${TMPBUILD}/CuMesh/setup.py"
if [ -f "$CUMESH_SETUP" ]; then
    sed -i '/"--extended-lambda",/d' "$CUMESH_SETUP"
    sed -i '/"--expt-relaxed-constexpr",/d' "$CUMESH_SETUP"
    sed -i '/"-U__CUDA_NO_HALF_OPERATORS__",/d' "$CUMESH_SETUP"
    sed -i '/"-U__CUDA_NO_HALF_CONVERSIONS__",/d' "$CUMESH_SETUP"
    sed -i '/"-U__CUDA_NO_HALF2_OPERATORS__",/d' "$CUMESH_SETUP"
fi

# Init cubvh's eigen (cubvh is vendored, not a git submodule, so it has
# no .git dir and git-submodule won't work — just clone eigen directly)
CUBVH_EIGEN="${TMPBUILD}/CuMesh/third_party/cubvh/third_party/eigen"
if [ -d "${TMPBUILD}/CuMesh/third_party/cubvh" ] && [ ! -f "${CUBVH_EIGEN}/Eigen/Dense" ]; then
    echo -e "${yellow}Cloning Eigen for cubvh...${reset}"
    mkdir -p "${TMPBUILD}/CuMesh/third_party/cubvh/third_party"
    rm -rf "${CUBVH_EIGEN}"
    git clone --depth 1 https://gitlab.com/libeigen/eigen.git "${CUBVH_EIGEN}"
fi

$PYTHON_EXE -m pip install "${TMPBUILD}/CuMesh" --no-build-isolation $PIPargs
echo ""

# Apply the remeshing.py fix from visualbruno
if [ -f "${SITE_PACKAGES}/cumesh/remeshing.py" ]; then
    cp "${SITE_PACKAGES}/cumesh/remeshing.py" "${SITE_PACKAGES}/cumesh/remeshing.py.bak"
fi
curl -L -o "${SITE_PACKAGES}/cumesh/remeshing.py" \
    "https://raw.githubusercontent.com/visualbruno/CuMesh/main/cumesh/remeshing.py"

# --- FlexGEMM (builds with HIP) ---
echo -e "${green}:::::::::::::: Building ${yellow}FlexGEMM${green} from source (ROCm)${reset}"
if [ -d "${TMPBUILD}/FlexGEMM" ]; then rm -rf "${TMPBUILD}/FlexGEMM"; fi
git clone --recursive https://github.com/JeffreyXiang/FlexGEMM.git "${TMPBUILD}/FlexGEMM"
$PYTHON_EXE -m pip install "${TMPBUILD}/FlexGEMM" --no-build-isolation $PIPargs
# Patch FlexGEMM Triton config: disable TF32 on ROCm (NVIDIA-only precision format)
FLEX_SPCONV_CFG="${SITE_PACKAGES}/flex_gemm/kernels/triton/spconv/config.py"
if [ -f "$FLEX_SPCONV_CFG" ]; then
    sed -i '1s/^/import torch\n/' "$FLEX_SPCONV_CFG"
    sed -i 's/^allow_tf32 = True$/# TF32 is NVIDIA-only. On ROCm, Triton only supports ieee\/bf16x3\/bf16x6.\nallow_tf32 = not getattr(torch.version, "hip", None)/' "$FLEX_SPCONV_CFG"
    echo -e "${green}Patched FlexGEMM: disabled TF32 on ROCm${reset}"
fi
# Clear stale Triton compilation cache
rm -rf ~/.triton/cache 2>/dev/null
echo ""

# --- o-voxel (builds with HIP via TRELLIS.2 source) ---
echo -e "${green}:::::::::::::: Building ${yellow}o-voxel${green} from source (ROCm)${reset}"
TRELLIS2_SRC="${TMPBUILD}/TRELLIS.2"
if [ -d "$TRELLIS2_SRC" ]; then rm -rf "$TRELLIS2_SRC"; fi
git clone --depth 1 --recursive https://github.com/microsoft/TRELLIS.2.git "$TRELLIS2_SRC"
# Ensure the eigen submodule is populated (needed for o-voxel build)
if [ ! -f "${TRELLIS2_SRC}/o-voxel/third_party/eigen/Eigen/Dense" ]; then
    echo -e "${yellow}Initializing eigen submodule...${reset}"
    git -C "$TRELLIS2_SRC" submodule update --init --recursive
fi
if [ -d "${TRELLIS2_SRC}/o-voxel" ]; then
    # Remove cumesh git dependency — we already built our patched ROCm version above
    sed -i '/cumesh.*git+/d' "${TRELLIS2_SRC}/o-voxel/pyproject.toml"
    $PYTHON_EXE -m pip install "${TRELLIS2_SRC}/o-voxel" --no-build-isolation $PIPargs
    # Apply Trellis2 GGUF patches to o_voxel (adds tiled_flexible_dual_grid_to_mesh)
    OVOXEL_INSTALLED="${SITE_PACKAGES}/o_voxel/convert"
    TRELLIS2_GGUF="${COMFY_ROOT}/ComfyUI/custom_nodes/ComfyUI-Trellis2-GGUF"
    if [ -f "${TRELLIS2_GGUF}/patch/flexible_dual_grid.py" ] && [ -d "$OVOXEL_INSTALLED" ]; then
        cp "${TRELLIS2_GGUF}/patch/flexible_dual_grid.py" "${OVOXEL_INSTALLED}/flexible_dual_grid.py"
        echo -e "${green}Patched o_voxel with tiled_flexible_dual_grid_to_mesh${reset}"
    fi
else
    echo -e "${warning}WARNING: o-voxel directory not found in TRELLIS.2 repo${reset}"
fi
echo ""

# --- nvdiffrast v0.4.0 (patched for ROCm/HIP) ---
# Builds interpolate/texture/antialias ops with HIP. The CUDA rasterizer is
# stubbed out because CudaRaster uses PTX inline assembly.
echo -e "${green}:::::::::::::: Building ${yellow}nvdiffrast v0.4.0${green} from source (ROCm)${reset}"
if [ -d "${TMPBUILD}/nvdiffrast" ]; then rm -rf "${TMPBUILD}/nvdiffrast"; fi
git clone -b v0.4.0 https://github.com/NVlabs/nvdiffrast.git "${TMPBUILD}/nvdiffrast"

echo -e "${yellow}Applying ROCm patches to nvdiffrast v0.4.0...${reset}"
NVDR="${TMPBUILD}/nvdiffrast"

# 1) __frcp_rz is CUDA-only; replace with 1.0f/x which compiles on both
sed -i 's/__frcp_rz(\(.*\))/(__fdividef(1.0f, \1))/g' "${NVDR}/csrc/common/texture_kernel.cu"

# 2) Warp sync functions on ROCm 7.2 require 64-bit masks.
#    Cast 0xffffffffu mask literals and change amask to unsigned long long.
sed -i 's/0xffffffffu/(unsigned long long)0xffffffffu/g' \
    "${NVDR}/csrc/common/antialias.cu" \
    "${NVDR}/csrc/common/interpolate.cu" \
    "${NVDR}/csrc/common/common.h"
sed -i 's/unsigned int amask/unsigned long long amask/g' \
    "${NVDR}/csrc/common/antialias.cu"

# 3) Remove -lineinfo NVCC flag that hipcc doesn't understand
sed -i 's/"-lineinfo"//g' "${NVDR}/setup.py"

# 4) The cudaraster module uses NVIDIA PTX inline assembly and cannot be ported to HIP.
#    Remove cudaraster sources AND torch_rasterize (deeply coupled to CudaRaster internals).
sed -i '/cudaraster\/impl\/Buffer.cpp/d' "${NVDR}/setup.py"
sed -i '/cudaraster\/impl\/CudaRaster.cpp/d' "${NVDR}/setup.py"
sed -i '/cudaraster\/impl\/RasterImpl.cpp/d' "${NVDR}/setup.py"
sed -i '/cudaraster\/impl\/RasterImpl_kernel.cu/d' "${NVDR}/setup.py"
sed -i '/torch_rasterize/d' "${NVDR}/setup.py"

# 4b) Create stub rasterize implementations so torch_bindings links successfully.
cat > "${NVDR}/csrc/torch/torch_rasterize_stub.cu" << 'STUBEOF'
#include "torch_common.inl"
#include "torch_types.h"
#include <tuple>

RasterizeCRStateWrapper::RasterizeCRStateWrapper(int deviceIdx) : cr(nullptr), cudaDeviceIdx(deviceIdx) {}
RasterizeCRStateWrapper::~RasterizeCRStateWrapper() {}

std::tuple<torch::Tensor, torch::Tensor> rasterize_fwd_cuda(RasterizeCRStateWrapper&, torch::Tensor, torch::Tensor, std::tuple<int,int>, torch::Tensor, int) { throw std::runtime_error("CUDA rasterizer not available on ROCm. Use RasterizeGLContext."); }
torch::Tensor rasterize_grad(torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor) { throw std::runtime_error("CUDA rasterizer not available on ROCm."); }
torch::Tensor rasterize_grad_db(torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor) { throw std::runtime_error("CUDA rasterizer not available on ROCm."); }
STUBEOF

# Add stub to setup.py sources list
sed -i '/torch_bindings/a\                "csrc/torch/torch_rasterize_stub.cu",' "${NVDR}/setup.py"

# 5) Patch framework.h to use HIP includes on ROCm.
cat > "${NVDR}/csrc/common/framework.h" << 'FWEOF'
#pragma once

#ifdef NVDR_TORCH

#if defined(__HIP_PLATFORM_AMD__)
#include <torch/extension.h>
#include <ATen/hip/HIPContext.h>
#include <ATen/hip/HIPUtils.h>
#include <c10/hip/HIPGuard.h>
#include <pybind11/numpy.h>
#define NVDR_CHECK(COND, ERR) do { TORCH_CHECK(COND, ERR) } while(0)
#define NVDR_CHECK_CUDA_ERROR(HIP_CALL) do { hipError_t err = HIP_CALL; TORCH_CHECK(!err, "HIP error: ", hipGetErrorString(hipGetLastError()), "[", #HIP_CALL, ";]"); } while(0)
#else
#ifndef __CUDACC__
#include <torch/extension.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/cuda/CUDAUtils.h>
#include <c10/cuda/CUDAGuard.h>
#include <pybind11/numpy.h>
#endif
#define NVDR_CHECK(COND, ERR) do { TORCH_CHECK(COND, ERR) } while(0)
#define NVDR_CHECK_CUDA_ERROR(CUDA_CALL) do { cudaError_t err = CUDA_CALL; TORCH_CHECK(!err, "Cuda error: ", cudaGetLastError(), "[", #CUDA_CALL, ";]"); } while(0)
#endif

#endif // NVDR_TORCH
FWEOF

# 6) Fix narrowing conversion error in torch_antialias.cpp (clang is stricter than nvcc)
sed -i 's/(uint64_t)p\.allocTriangles/(int64_t)p.allocTriangles/g' "${NVDR}/csrc/torch/torch_antialias.cpp"

# 7) Rename .cpp files to .cu so they get compiled with hipcc
for f in torch_antialias torch_bindings torch_interpolate torch_texture; do
    if [ -f "${NVDR}/csrc/torch/${f}.cpp" ]; then
        mv "${NVDR}/csrc/torch/${f}.cpp" "${NVDR}/csrc/torch/${f}.cu"
        sed -i "s|csrc/torch/${f}.cpp|csrc/torch/${f}.cu|" "${NVDR}/setup.py"
    fi
done
for f in common texture; do
    if [ -f "${NVDR}/csrc/common/${f}.cpp" ]; then
        mv "${NVDR}/csrc/common/${f}.cpp" "${NVDR}/csrc/common/${f}.cu"
        sed -i "s|csrc/common/${f}.cpp|csrc/common/${f}.cu|" "${NVDR}/setup.py"
    fi
done

$PYTHON_EXE -m pip install "${NVDR}" --no-build-isolation $PIPargs || \
    echo -e "${warning}WARNING: nvdiffrast v0.4.0 build failed. Some rendering features may not work.${reset}"
echo ""

# --- nvdiffrast GL plugin from v0.3.5 ---
# v0.4.0 removed the OpenGL rasterizer. We build the GL plugin from v0.3.5 sources
# as a separate extension module, then patch ops.py to load it for RasterizeGLContext.
# The GL plugin uses EGL for headless OpenGL and HIP-GL interop for buffer sharing.
echo -e "${green}:::::::::::::: Building ${yellow}nvdiffrast GL plugin${green} from v0.3.5 sources${reset}"
if [ -d "${TMPBUILD}/nvdiffrast_gl" ]; then rm -rf "${TMPBUILD}/nvdiffrast_gl"; fi
git clone -b v0.3.5 https://github.com/NVlabs/nvdiffrast.git "${TMPBUILD}/nvdiffrast_gl"

NVDR_GL="${TMPBUILD}/nvdiffrast_gl/nvdiffrast"
NVDR_INSTALLED="${SITE_PACKAGES}/nvdiffrast"

echo -e "${yellow}Patching v0.3.5 GL sources for ROCm/HIP...${reset}"

# Patch common.cpp: replace cuda_runtime.h with hip equivalent
sed -i 's|#include <cuda_runtime.h>|#if defined(__HIP_PLATFORM_AMD__)\n#include <hip/hip_runtime.h>\n#else\n#include <cuda_runtime.h>\n#endif|' "${NVDR_GL}/common/common.cpp"

# Patch common.h: replace cuda.h with hip equivalent
sed -i 's|#include <cuda.h>|#if defined(__HIP_PLATFORM_AMD__)\n#include <hip/hip_runtime.h>\n#else\n#include <cuda.h>\n#endif|' "${NVDR_GL}/common/common.h"

# Patch glutil.h: replace cuda_gl_interop.h with hip_gl_interop.h on ROCm
# hip_gl_interop.h requires hip_runtime.h for type definitions (hipError_t etc.)
sed -i 's|#include <cuda_gl_interop.h>|#if defined(__HIP_PLATFORM_AMD__)\n#include <hip/hip_runtime.h>\n#include <hip/hip_gl_interop.h>\n#else\n#include <cuda_gl_interop.h>\n#endif|' "${NVDR_GL}/common/glutil.h"

# Patch framework.h for ROCm/HIP — must match v0.3.5 macro definitions exactly.
# On ROCm, we include HIP runtime and provide CUDA→HIP type aliases so that the
# original nvdiffrast GL sources compile without modification.
cat > "${NVDR_GL}/common/framework.h" << 'FWGLEOF'
#pragma once

#ifdef NVDR_TORCH

#if defined(__HIP_PLATFORM_AMD__)
// ROCm/HIP path — provide CUDA→HIP type aliases for the GL plugin sources
#include <hip/hip_runtime.h>

// CUDA→HIP type aliases
typedef hipStream_t                 cudaStream_t;
typedef hipError_t                  cudaError_t;
typedef hipGraphicsResource_t       cudaGraphicsResource_t;

// CUDA→HIP constant aliases
#define cudaSuccess                 hipSuccess
#define cudaMemcpyDeviceToDevice    hipMemcpyDeviceToDevice
#define cudaGraphicsRegisterFlagsWriteDiscard hipGraphicsRegisterFlagsWriteDiscard

// CUDA→HIP function aliases
#define cudaGraphicsGLRegisterBuffer    hipGraphicsGLRegisterBuffer
#define cudaGraphicsMapResources        hipGraphicsMapResources
#define cudaGraphicsUnmapResources      hipGraphicsUnmapResources
#define cudaGraphicsResourceGetMappedPointer hipGraphicsResourceGetMappedPointer
#define cudaGraphicsUnregisterResource  hipGraphicsUnregisterResource
#define cudaMemcpyAsync                 hipMemcpyAsync
#define cudaDeviceSynchronize           hipDeviceSynchronize
#define cudaDeviceGetAttribute          hipDeviceGetAttribute
#define cudaDevAttrComputeCapabilityMajor hipDeviceAttributeComputeCapabilityMajor
#define cudaDeviceGetPCIBusId           hipDeviceGetPCIBusId
#define cudaGraphicsSubResourceGetMappedArray hipGraphicsSubResourceGetMappedArray
#define cudaArrayGetInfo                hipArrayGetInfo
typedef hipArray_t                      cudaArray_t;
typedef hipChannelFormatDesc            cudaChannelFormatDesc;
typedef hipExtent                       cudaExtent;
#define cudaChannelFormatKindFloat      hipChannelFormatKindFloat
#define cudaMemcpy3DParms               hipMemcpy3DParms
#define cudaMemcpy3DAsync               hipMemcpy3DAsync
#define cudaGraphicsGLRegisterImage     hipGraphicsGLRegisterImage
#define cudaGraphicsRegisterFlagsReadOnly hipGraphicsRegisterFlagsReadOnly

#include <torch/extension.h>
#include <c10/hip/HIPStream.h>
#include <c10/hip/HIPGuard.h>
#include <pybind11/numpy.h>

// at::cuda namespace aliases for ROCm
namespace at { namespace cuda {
    using c10::cuda::OptionalCUDAGuard;
    inline c10::cuda::CUDAStream getCurrentCUDAStream(c10::DeviceIndex device_index = -1) {
        return c10::hip::getCurrentHIPStream(device_index);
    }
    inline bool check_device(c10::ArrayRef<at::Tensor> ts) {
        if (ts.empty()) return true;
        at::Device curDevice = ts.front().device();
        for (const at::Tensor& t : ts) { if (t.device() != curDevice) return false; }
        return true;
    }
}}
#else
// CUDA path (original)
#ifndef __CUDACC__
#include <torch/extension.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/cuda/CUDAUtils.h>
#include <c10/cuda/CUDAGuard.h>
#include <pybind11/numpy.h>
#endif
#endif

#define NVDR_CTX_ARGS int _nvdr_ctx_dummy
#define NVDR_CTX_PARAMS 0
#define NVDR_CHECK(COND, ERR) do { TORCH_CHECK(COND, ERR) } while(0)
#define NVDR_CHECK_GL_ERROR(GL_CALL) do { GL_CALL; GLenum err = glGetError(); TORCH_CHECK(err == GL_NO_ERROR, "OpenGL error: ", getGLErrorString(err), "[", #GL_CALL, ";]"); } while(0)

#if defined(__HIP_PLATFORM_AMD__)
#define NVDR_CHECK_CUDA_ERROR(CALL) do { hipError_t err = CALL; TORCH_CHECK(!err, "HIP error: ", hipGetErrorString(err), "[", #CALL, ";]"); } while(0)
#else
#define NVDR_CHECK_CUDA_ERROR(CUDA_CALL) do { cudaError_t err = CUDA_CALL; TORCH_CHECK(!err, "Cuda error: ", cudaGetLastError(), "[", #CUDA_CALL, ";]"); } while(0)
#endif

#endif // NVDR_TORCH
FWGLEOF

# Build GL plugin as CppExtension (NOT CUDAExtension to avoid hipify mangling).
# framework.h provides all CUDA→HIP type/function aliases, so hipcc's auto-mapping
# is not needed. We just need the ROCm include path for hip_runtime.h.
cat > "${TMPBUILD}/nvdiffrast_gl/setup_gl.py" << 'GLSETUPEOF'
import os
from setuptools import setup
from torch.utils.cpp_extension import CppExtension, BuildExtension

nvdr_dir = os.path.join(os.path.dirname(__file__), 'nvdiffrast')

# Find ROCm include path
rocm_include = '/opt/rocm/include'
if not os.path.isdir(rocm_include):
    rocm_include = os.environ.get('ROCM_PATH', '/opt/rocm') + '/include'

setup(
    name='nvdiffrast_plugin_gl',
    ext_modules=[
        CppExtension(
            name='nvdiffrast_plugin_gl',
            sources=[
                os.path.join(nvdr_dir, 'common', 'common.cpp'),
                os.path.join(nvdr_dir, 'common', 'glutil.cpp'),
                os.path.join(nvdr_dir, 'common', 'rasterize_gl.cpp'),
                os.path.join(nvdr_dir, 'torch', 'torch_bindings_gl.cpp'),
                os.path.join(nvdr_dir, 'torch', 'torch_rasterize_gl.cpp'),
            ],
            include_dirs=[
                os.path.join(nvdr_dir, 'common'),
                os.path.join(nvdr_dir, 'torch'),
                rocm_include,
            ],
            define_macros=[('NVDR_TORCH', None), ('__HIP_PLATFORM_AMD__', '1')],
            libraries=['GL', 'EGL', 'amdhip64'],
            library_dirs=['/opt/rocm/lib'],
        ),
    ],
    cmdclass={'build_ext': BuildExtension},
)
GLSETUPEOF

echo -e "${yellow}Building GL plugin extension...${reset}"
cd "${TMPBUILD}/nvdiffrast_gl"
$PYTHON_EXE setup_gl.py build_ext --inplace 2>&1
GL_SO=$(find "${TMPBUILD}/nvdiffrast_gl" -name 'nvdiffrast_plugin_gl*.so' -type f | head -1)
if [ -n "$GL_SO" ]; then
    cp "$GL_SO" "${SITE_PACKAGES}/"
    echo -e "${green}GL plugin built and installed: $(basename $GL_SO)${reset}"
else
    echo -e "${warning}WARNING: nvdiffrast GL plugin build failed. OpenGL rasterization will not work.${reset}"
fi
cd "${COMFY_ROOT}"
echo ""

# Now patch the installed ops.py to restore the GL context and dispatch logic.
echo -e "${yellow}Patching nvdiffrast ops.py to restore OpenGL rasterizer support...${reset}"
NVDR_OPS="${NVDR_INSTALLED}/torch/ops.py"

$PYTHON_EXE << PYEOF
import re

with open("${NVDR_OPS}", "r") as f:
    content = f.read()

# 1. Add import for the pre-built GL plugin (after existing imports)
gl_imports = '''
import importlib
import logging

# Pre-built GL plugin for OpenGL rasterizer (from v0.3.5 sources)
_gl_plugin = None
def _get_gl_plugin():
    global _gl_plugin
    if _gl_plugin is not None:
        return _gl_plugin
    try:
        import nvdiffrast_plugin_gl
        _gl_plugin = nvdiffrast_plugin_gl
    except ImportError:
        raise RuntimeError(
            "nvdiffrast GL plugin not found. "
            "The OpenGL rasterizer requires the nvdiffrast_plugin_gl extension. "
            "Please rebuild with the ROCm install script."
        )
    return _gl_plugin
'''

# Insert after the existing imports
content = content.replace('import _nvdiffrast_c', 'import _nvdiffrast_c' + gl_imports)

# 2. Replace the stub RasterizeGLContext with a real one
old_gl_class = re.compile(
    r'class RasterizeGLContext\(RasterizeCudaContext\):.*?(?=\n#[-]+|\nclass |\Z)',
    re.DOTALL
)
new_gl_class = '''class RasterizeGLContext:
    def __init__(self, output_db=True, mode='automatic', device=None):
        assert output_db is True or output_db is False
        assert mode in ['automatic', 'manual']
        self.output_db = output_db
        self.mode = mode
        if device is None:
            cuda_device_idx = torch.cuda.current_device()
        else:
            with torch.cuda.device(device):
                cuda_device_idx = torch.cuda.current_device()
        self.cpp_wrapper = _get_gl_plugin().RasterizeGLStateWrapper(output_db, mode == 'automatic', cuda_device_idx)
        self.active_depth_peeler = None

    def set_context(self):
        assert self.mode == 'manual'
        self.cpp_wrapper.set_context()

    def release_context(self):
        assert self.mode == 'manual'
        self.cpp_wrapper.release_context()

'''
content = old_gl_class.sub(new_gl_class, content)

# 3. Patch _rasterize_func.forward to dispatch GL vs CUDA
old_forward = '''    def forward(ctx, raster_ctx, pos, tri, resolution, ranges, grad_db, peeling_idx):
        out, out_db = _nvdiffrast_c.rasterize_fwd_cuda(raster_ctx.cpp_wrapper, pos, tri, resolution, ranges, peeling_idx)'''
new_forward = '''    def forward(ctx, raster_ctx, pos, tri, resolution, ranges, grad_db, peeling_idx):
        if isinstance(raster_ctx, RasterizeGLContext):
            out, out_db = _get_gl_plugin().rasterize_fwd_gl(raster_ctx.cpp_wrapper, pos, tri, resolution, ranges, peeling_idx)
        else:
            out, out_db = _nvdiffrast_c.rasterize_fwd_cuda(raster_ctx.cpp_wrapper, pos, tri, resolution, ranges, peeling_idx)'''
content = content.replace(old_forward, new_forward)

# 4. Patch the rasterize() function to accept both context types
content = content.replace(
    'assert isinstance(glctx, RasterizeCudaContext)',
    'assert isinstance(glctx, (RasterizeGLContext, RasterizeCudaContext))'
)

# 5. Add output_db handling for GL context (v0.4.0 removed it)
content = content.replace(
    '''    assert grad_db is True or grad_db is False

    # Sanitize inputs.''',
    '''    assert grad_db is True or grad_db is False
    grad_db = grad_db and getattr(glctx, 'output_db', True)

    # Sanitize inputs.'''
)

with open("${NVDR_OPS}", "w") as f:
    f.write(content)

print("ops.py patched successfully")
PYEOF

# Clear bytecode cache so the patched ops.py is used
find "${NVDR_INSTALLED}" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

echo ""

# --- nvdiffrec_render (patched for ROCm/HIP) ---
echo -e "${green}:::::::::::::: Building ${yellow}nvdiffrec_render${green} from source (ROCm)${reset}"
if [ -d "${TMPBUILD}/nvdiffrec" ]; then rm -rf "${TMPBUILD}/nvdiffrec"; fi
git clone -b renderutils https://github.com/JeffreyXiang/nvdiffrec.git "${TMPBUILD}/nvdiffrec"

echo -e "${yellow}Applying ROCm patches to nvdiffrec_render...${reset}"
NVREC="${TMPBUILD}/nvdiffrec"
NVREC_SRC="${NVREC}/nvdiffrec_render/renderutils/c_src"

# Remove -lcuda -lnvrtc linker flags (CUDA-only)
sed -i "s/'-lcuda', '-lnvrtc'//g" "${NVREC}/setup.py"

# Fix 64-bit warp sync masks for ROCm 7.2
sed -i 's/0xFFFFFFFF/(unsigned long long)0xFFFFFFFF/g' "${NVREC_SRC}/loss.cu"

# Rename .cpp files to .cu so hipcc compiles them (need CUDA→HIP header mapping)
for f in common torch_bindings; do
    if [ -f "${NVREC_SRC}/${f}.cpp" ]; then
        mv "${NVREC_SRC}/${f}.cpp" "${NVREC_SRC}/${f}.cu"
        sed -i "s|${f}.cpp|${f}.cu|" "${NVREC}/setup.py"
    fi
done

# Patch torch_bindings to use HIP headers
sed -i 's|#include <ATen/cuda/CUDAContext.h>|#ifdef __HIP_PLATFORM_AMD__\n#include <ATen/hip/HIPContext.h>\n#include <ATen/hip/HIPUtils.h>\n#else\n#include <ATen/cuda/CUDAContext.h>\n#endif|' "${NVREC_SRC}/torch_bindings.cu"
sed -i 's|#include <ATen/cuda/CUDAUtils.h>||' "${NVREC_SRC}/torch_bindings.cu"

# Replace cudaError_t/cudaGetLastError with HIP equivalents
sed -i 's/cudaError_t/hipError_t/g; s/cudaGetLastError/hipGetLastError/g; s/AT_CUDA_CHECK/AT_CUDA_CHECK/g' "${NVREC_SRC}/torch_bindings.cu"

$PYTHON_EXE -m pip install "${NVREC}" --no-build-isolation $PIPargs || \
    echo -e "${warning}WARNING: nvdiffrec_render build failed. Some mesh features may not work.${reset}"
echo ""

# ---- Install remaining deps ----
$PYTHON_EXE -m pip install --upgrade pooch --no-deps $PIPargs

# Do NOT force numpy downgrade — Python 3.14 requires numpy >= 2.x
echo -e "${green}Checking numpy version...${reset}"
$PYTHON_EXE -c "import numpy; print(f'numpy {numpy.__version__} installed')"

# ---- Patch Trellis2 GGUF plugin: use OpenGL rasterizer instead of CUDA (ROCm) ----
TRELLIS_PLUGIN="${COMFYUI_DIR}/custom_nodes/ComfyUI-Trellis2-GGUF"
if [ -d "$TRELLIS_PLUGIN" ]; then
    echo -e "${green}:::::::::::::: Patching ${yellow}Trellis2 GGUF${green}: RasterizeCudaContext → RasterizeGLContext${reset}"
    find "$TRELLIS_PLUGIN" -name '*.py' -exec sed -i 's/RasterizeCudaContext/RasterizeGLContext/g' {} +
fi

# ---- Cleanup ----
echo ""
echo -e "${green}Cleaning up build temp files...${reset}"
rm -rf "$TMPBUILD"

# ---- Final Messages ----
echo ""
echo -e "${green}══════════════════════════════════════════════════════════════════${reset}"
echo -e "${green}::::::::::::::${yellow} ${node_name} ${green}Installation Complete${reset}"
echo -e "${green}══════════════════════════════════════════════════════════════════${reset}"
echo ""
echo -e "${cyan}Important notes for ROCm:${reset}"
echo -e "  - nvdiffrast uses the ${yellow}OpenGL${reset} backend (no CUDA rasterizer on AMD)"
echo -e "  - Make sure to launch ComfyUI with: ${yellow}--use-pytorch-cross-attention${reset}"
echo -e "  - If you get HIP compile errors, check that ${yellow}PYTORCH_ROCM_ARCH=gfx1102${reset} matches your GPU"
echo -e "  - Some features relying on CUDA-only kernels may have reduced performance"
echo ""
