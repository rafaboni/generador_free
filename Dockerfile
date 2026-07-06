# syntax=docker/dockerfile:1.4
# generador_free — Open Generative AI + sd.cpp (CUDA) + Wan2GP, for RunPod GPU pods.
# Disk is ephemeral: everything below is just "install and be ready to run".
# No model weights are baked in or auto-downloaded — pick what you need each
# session from Settings -> Local Models (sd.cpp) or Wan2GP's own UI on :7860.
FROM nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_BREAK_SYSTEM_PACKAGES=1

# --- Fix apt mirrors + retry on transient failures ---
RUN sed -i 's|http://archive.ubuntu.com|https://us.archive.ubuntu.com|g' /etc/apt/sources.list && \
    echo "Acquire::Retries 5;" > /etc/apt/apt.conf.d/80retry

# --- System deps ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates gnupg curl wget \
    git git-lfs \
    build-essential cmake ninja-build unzip \
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

# ─────────────────────────────────────────────────────────────────────────────
# sd.cpp — built from source with CUDA (the prebuilt GitHub release binary is
# CPU-only on Linux x86_64). Target archs cover the common RunPod GPU tiers:
# V100 / T4 / A100 / 3090-A6000 / 4090-L40 / H100.
# ─────────────────────────────────────────────────────────────────────────────
ARG CACHE_DATE=1
ARG SD_CUDA_ARCHITECTURES="70;75;80;86;89;90"
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

# ─────────────────────────────────────────────────────────────────────────────
# Wan2GP — video / large-image engine, served as its own Gradio app on :7860.
# Steps mirror Wan2GP's own official Dockerfile (CUDA wheels + SageAttention
# compiled for the same arch list as sd.cpp above).
# ─────────────────────────────────────────────────────────────────────────────
RUN echo "cache-bust: ${CACHE_DATE}" > /dev/null && \
    git clone --depth 1 https://github.com/deepbeepmeep/Wan2GP.git /opt/wan2gp

WORKDIR /opt/wan2gp
RUN pip install --upgrade pip setuptools wheel

# Pin torch to what Wan2GP tests against before requirements.txt pulls generic versions.
RUN pip install torch==2.10.0+cu128 torchvision==0.25.0+cu128 torchaudio==2.10.0+cu128 \
    --index-url https://download.pytorch.org/whl/cu128

RUN pip install -r requirements.txt

ENV TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0"
ENV FORCE_CUDA="1"
ENV MAX_JOBS="8"
COPY patch_sageattention.py /tmp/patch_sageattention.py
RUN git clone --depth 1 https://github.com/thu-ml/SageAttention.git /tmp/sageattention && \
    cp /tmp/patch_sageattention.py /tmp/sageattention/patch_sageattention.py && \
    cd /tmp/sageattention && \
    python3 patch_sageattention.py && \
    pip install --no-build-isolation . && \
    rm -rf /tmp/sageattention /tmp/patch_sageattention.py

ENV HF_HOME=/root/.cache/huggingface

# ─────────────────────────────────────────────────────────────────────────────
# Open Generative AI — cloned as-is, unmodified, same as any other custom-node
# style install in this Dockerfile. Served on :3000 via its normal cloud-API
# based UI (this image does not wire sd.cpp/Wan2GP into it).
# ─────────────────────────────────────────────────────────────────────────────
WORKDIR /app
RUN echo "cache-bust: ${CACHE_DATE}" > /dev/null && \
    git clone --recursive --depth 1 https://github.com/Anil-matcha/Open-Generative-AI.git . && \
    npm install && \
    npm run build:packages && \
    npm run build

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 3000 7860 8080 8888 22
CMD ["/start.sh"]
