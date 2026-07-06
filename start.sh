#!/bin/bash
# start.sh — RunPod entrypoint for generador_free
set -uo pipefail

echo "========================================="
echo "  generador_free - Open Generative AI"
echo "========================================="

# ── SSH ──────────────────────────────────────────────────────────────────────
mkdir -p /run/sshd /root/.ssh
chmod 700 /root/.ssh
echo "root:root" | chpasswd
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
ssh-keygen -A 2>/dev/null

# Extra key injected by RunPod (env var / secret), on top of the one baked at build time.
if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
  echo "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
  echo "SSH key injected from env"
fi

chown -R root:root /root/.ssh
sshd -t 2>&1
service ssh start 2>/dev/null || /usr/sbin/sshd
echo "SSH running: $(ss -tlnp 2>/dev/null | grep :22 || echo 'check manually')"

# ── Terminal config ──────────────────────────────────────────────────────────
echo 'export TERM=xterm-256color' >> /root/.bashrc
echo 'export PS1="\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ "' >> /root/.bashrc
cp /root/.bashrc /root/.bash_profile 2>/dev/null || true

# ── FileBrowser ──────────────────────────────────────────────────────────────
echo "[1/4] FileBrowser (:8080)..."
filebrowser -r / -p 8080 --address 0.0.0.0 --noauth &> /var/log/filebrowser.log &

# ── JupyterLab ────────────────────────────────────────────────────────────────
echo "[2/4] JupyterLab (:8888)..."
jupyter lab --allow-root --no-browser --port=8888 --ip=0.0.0.0 \
  --ServerApp.token='' \
  --ServerApp.password='' \
  --ServerApp.allow_origin='*' \
  --ServerApp.allow_remote_access=True \
  --ServerApp.disable_check_xsrf=True \
  &> /var/log/jupyterlab.log &

# ── Wan2GP (Gradio, :7860) ───────────────────────────────────────────────────
echo "[3/4] Wan2GP (:7860)..."
(
  cd /opt/wan2gp
  python3 wgp.py --listen --server-name 0.0.0.0 &> /var/log/wan2gp.log
) &

# ── sd.cpp sanity check ──────────────────────────────────────────────────────
if [[ -x /opt/sd-cpp/bin/sd-cli ]]; then
  echo "sd.cpp binary ready at /opt/sd-cpp/bin/sd-cli"
else
  echo "WARNING: sd-cli not found — sd.cpp will be unavailable"
fi

# ── Open Generative AI (Next.js, :3000, foreground) ──────────────────────────
echo "[4/4] Starting Open Generative AI..."
echo "========================================="
cd /app
exec npm start
