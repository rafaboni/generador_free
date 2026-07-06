# syntax=docker/dockerfile:1.4
# generador_free — Open Generative AI + sd.cpp (CUDA) + Wan2GP, for RunPod GPU pods.
# Disk is ephemeral: everything below is just "install and be ready to run".
# No model weights are baked in or auto-downloaded — pick what you need each
# session from Settings -> Local Models (sd.cpp) or Wan2GP's own UI on :7860.
#
# Multi-stage: sd.cpp needs nvcc (CUDA "devel" image) to compile with GPU
# support. Everything else (Wan2GP, Open Generative AI) is plain Python/Node
# with prebuilt PyTorch wheels — no compiler needed — so the final image ships
# on the much lighter CUDA "runtime" base (same pattern as comfy-cuda).

# ─── Stage 1: compile sd.cpp with CUDA ────────────────────────────────────────
FROM nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04 AS sdcpp-builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git build-essential cmake ninja-build \
    && rm -rf /var/lib/apt/lists/*

# Target archs: Ampere (A100/A6000/3090, sm_80/86) and Ada (4090/L40, sm_89) —
# the GPUs actually rented on RunPod for this. Fewer archs = much faster nvcc
# build (was 6 archs spanning V100-H100, ~1-2h; now 3, ~15-20min).
ARG CACHE_DATE=1
ARG SD_CUDA_ARCHITECTURES="80;86;89"
WORKDIR /opt
RUN echo "cache-bust: ${CACHE_DATE}" > /dev/null && \
    git clone --recursive --depth 1 https://github.com/leejet/stable-diffusion.cpp.git && \
    cmake -S stable-diffusion.cpp -B stable-diffusion.cpp/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DSD_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${SD_CUDA_ARCHITECTURES}" && \
    cmake --build stable-diffusion.cpp/build --config Release -j"$(nproc)"

RUN mkdir -p /opt/sd-cpp/bin && \
    cp /opt/stable-diffusion.cpp/build/bin/sd-cli /opt/sd-cpp/bin/ && \
    find /opt/stable-diffusion.cpp/build -name "*.so*" -exec cp {} /opt/sd-cpp/bin/ \; ; \
    chmod +x /opt/sd-cpp/bin/*

# ─── Stage 2: runtime image ────────────────────────────────────────────────────
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_BREAK_SYSTEM_PACKAGES=1

# --- Fix apt mirrors + retry on transient failures ---
RUN sed -i 's|http://archive.ubuntu.com|https://us.archive.ubuntu.com|g' /etc/apt/sources.list && \
    echo "Acquire::Retries 5;" > /etc/apt/apt.conf.d/80retry

# --- System deps ---
# build-essential is still needed here: several Wan2GP requirements.txt deps
# (e.g. insightface) build a Cython/C++ extension at pip-install time and need
# g++. This is much lighter than the full CUDA "devel" toolkit we dropped —
# no nvcc, no cudnn-devel headers, just a plain C/C++ compiler.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates gnupg curl wget \
    git git-lfs \
    build-essential \
    python3 python3-pip python3-dev \
    ffmpeg libgl1 libglib2.0-0 libsm6 libxext6 libxrender-dev \
    openssh-server \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /root/.ssh && chmod 700 /root/.ssh

# --- Node.js 20 (for the Next.js app) ---
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# --- SSH public key ---
COPY authorized_keys /root/.ssh/authorized_keys
RUN chmod 600 /root/.ssh/authorized_keys

# --- FileBrowser ---
RUN curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash || true

# --- JupyterLab ---
RUN pip install jupyterlab

# --- sd.cpp (compiled with CUDA in stage 1) ---
COPY --from=sdcpp-builder /opt/sd-cpp /opt/sd-cpp

# ─────────────────────────────────────────────────────────────────────────────
# Wan2GP — video / large-image engine, served as its own Gradio app on :7860.
# No SageAttention: it's an optional ~2x speed optimization for attention, not
# a requirement — without it Wan2GP just uses PyTorch's built-in `sdpa`
# (scaled_dot_product_attention), which ships prebuilt in the torch wheel and
# needs no compilation. Dropping it removes the second CUDA source-compile
# (and the OOM risk that came with it on a 2-core/7GB CI runner).
# ─────────────────────────────────────────────────────────────────────────────
ARG CACHE_DATE=1
RUN echo "cache-bust: ${CACHE_DATE}" > /dev/null && \
    git clone --depth 1 https://github.com/deepbeepmeep/Wan2GP.git /opt/wan2gp

WORKDIR /opt/wan2gp
RUN pip install --upgrade pip setuptools wheel

# Generic cu124 wheel (prebuilt, no compilation) — matches the runtime base above.
RUN pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124

RUN pip install -r requirements.txt

ENV HF_HOME=/root/.cache/huggingface

# ─────────────────────────────────────────────────────────────────────────────
# Open Generative AI — cloned as-is, unmodified, same as any other custom-node
# style install in this Dockerfile. Served on :3000 via its normal cloud-API
# based UI (this image does not wire sd.cpp/Wan2GP into it).
# ─────────────────────────────────────────────────────────────────────────────
WORKDIR /app
# Two of the three pinned submodule commits are dangling upstream (they don't
# exist in Anil-matcha/Open-Poe-AI or Anil-matcha/Open-AI-Design-Agent — a bug
# in the parent repo's index, not fixable from here without push access to
# it). Only Vibe-Workflow's pinned commit is valid. Work around the other two
# by swapping them for fresh clones of their current main branch.
RUN echo "cache-bust: ${CACHE_DATE}" > /dev/null && \
    git clone https://github.com/Anil-matcha/Open-Generative-AI.git . && \
    git submodule update --init packages/Vibe-Workflow && \
    rm -rf packages/Open-AI-Design-Agent packages/Open-Poe-AI && \
    git clone --depth 1 https://github.com/Anil-matcha/Open-AI-Design-Agent.git packages/Open-AI-Design-Agent && \
    git clone --depth 1 https://github.com/Anil-matcha/Open-Poe-AI.git packages/Open-Poe-AI && \
    npm install && \
    npm run build:packages && \
    npm run build

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 3000 7860 8080 8888 22
CMD ["/start.sh"]
