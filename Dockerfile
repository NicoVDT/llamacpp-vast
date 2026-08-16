# llama.cpp (CUDA 12.6, sm_86 / RTX 3090) on top of Vast.ai's base image.
#
# The Vast base image supplies SSH, Jupyter and the instance portal via its own
# entrypoint + supervisor. We deliberately do NOT set ENTRYPOINT or CMD here --
# overriding either one breaks those services. The server is started manually
# (or via the template's on-start script) with start-llama.sh.
FROM vastai/base-image:cuda-12.6.3-auto

ARG LLAMACPP_TARBALL=llamacpp-cu126-sm86.tar.gz

# The tarball has a single top-level bin/ directory holding BOTH the executables
# and the shared objects (there is no separate lib/), so PATH and LD_LIBRARY_PATH
# both point at /opt/llamacpp/bin.
ENV LLAMA_HOME=/opt/llamacpp \
    PATH=/opt/llamacpp/bin:$PATH \
    LD_LIBRARY_PATH=/opt/llamacpp/bin:$LD_LIBRARY_PATH

# Runtime defaults. Everything here can be overridden from the Vast template's
# environment variables. LLAMA_API_KEY is intentionally absent -- it has no
# default and start-llama.sh refuses to run without it.
ENV MODEL_REPO=Blackfrost-AI/Qwen3.8-27B-ABLITERATED-GGUF \
    MODEL_QUANT=Q4_K_M \
    MODEL_DIR=/workspace/models \
    LOG_DIR=/workspace/logs \
    LLAMA_HOST=0.0.0.0 \
    LLAMA_PORT=10200 \
    LLAMA_NGL=99 \
    LLAMA_CTX=131072 \
    LLAMA_PARALLEL=1 \
    LLAMA_ALIAS=qwen-local \
    LLAMA_CACHE_TYPE_K=q8_0 \
    LLAMA_CACHE_TYPE_V=q8_0 \
    TMUX_SESSION=llama

# curl/jq drive the Hugging Face download; tmux hosts the detached server session.
# The base image usually has all three, so this is normally a no-op layer.
RUN set -eux; \
    missing=""; \
    for p in curl jq tmux ca-certificates; do \
        dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"; \
    done; \
    if [ -n "$missing" ]; then \
        apt-get update; \
        apt-get install -y --no-install-recommends $missing; \
        rm -rf /var/lib/apt/lists/*; \
    else \
        echo "curl/jq/tmux/ca-certificates already present"; \
    fi

# Unpack the prebuilt binaries. The ~45 test-* executables in the tarball are
# useless in a server image, so they get dropped (~15 MB).
COPY ${LLAMACPP_TARBALL} /tmp/llamacpp.tar.gz
RUN set -eux; \
    mkdir -p /opt/llamacpp; \
    tar -xzf /tmp/llamacpp.tar.gz -C /opt/llamacpp; \
    rm -f /tmp/llamacpp.tar.gz; \
    rm -f /opt/llamacpp/bin/test-*; \
    chmod -R a+rX /opt/llamacpp; \
    chmod a+x /opt/llamacpp/bin/llama-*; \
    test -x /opt/llamacpp/bin/llama-server; \
    du -sh /opt/llamacpp

# libggml-cuda.so links libcublas.so.12 + libcudart.so.12. If the base image
# already ships them (it usually does) this costs nothing; if not, pull them in,
# adding the NVIDIA apt repo only as a fallback. Installing unconditionally would
# add ~700 MB for nothing.
RUN set -eux; \
    if ldconfig -p | grep -q 'libcublas\.so\.12'; then \
        echo "cuBLAS 12 already present in base image -- nothing to install"; \
    else \
        echo "cuBLAS 12 missing -- installing CUDA 12.6 runtime libraries"; \
        apt-get update; \
        if ! apt-get install -y --no-install-recommends libcublas-12-6 cuda-cudart-12-6; then \
            . /etc/os-release; \
            distro="$(echo "$ID$VERSION_ID" | tr -d '.')"; \
            apt-get install -y --no-install-recommends wget ca-certificates; \
            wget -qO /tmp/cuda-keyring.deb \
                "https://developer.download.nvidia.com/compute/cuda/repos/${distro}/x86_64/cuda-keyring_1.1-1_all.deb"; \
            dpkg -i /tmp/cuda-keyring.deb; \
            rm -f /tmp/cuda-keyring.deb; \
            apt-get update; \
            apt-get install -y --no-install-recommends libcublas-12-6 cuda-cudart-12-6; \
        fi; \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Fail the build here rather than at 3am on a rented box. libcuda.so.1 is the
# only legitimately-missing library: it comes from the host driver, which the
# container runtime injects at run time and which is absent during the build.
RUN set -eu; \
    unresolved="$( { ldd /opt/llamacpp/bin/llama-server; ldd /opt/llamacpp/bin/libggml-cuda.so; } \
        | awk '/not found/ {print $1}' | grep -v '^libcuda\.so\.1$' | sort -u || true )"; \
    if [ -n "$unresolved" ]; then \
        echo "ERROR: unresolved shared libraries: $unresolved" >&2; \
        exit 1; \
    fi; \
    echo "linkage OK (libcuda.so.1 is provided by the host driver at run time)"

COPY start-llama.sh /usr/local/bin/start-llama.sh
# Strip CRLF in case the file was checked out on Windows without .gitattributes
# taking effect -- a \r after the shebang makes the container report "not found".
RUN sed -i 's/\r$//' /usr/local/bin/start-llama.sh \
 && chmod +x /usr/local/bin/start-llama.sh

EXPOSE 10200
