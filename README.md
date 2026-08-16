# llamacpp-vast

Prebuilt llama.cpp (CUDA 12.6, `sm_86`) baked into Vast.ai's base image, so renting
a fresh RTX 3090 box means pulling an image instead of recompiling.

The ~17 GB GGUF is **not** in the image — it's pulled from Hugging Face on first run
and cached under `/workspace/models`.

| | |
|---|---|
| Image | `vdtnico/llamacpp-vast:latest` |
| Base | `vastai/base-image:cuda-12.6.3-auto` (SSH, Jupyter and the portal keep working) |
| Binaries | `/opt/llamacpp/bin` — on `PATH` and `LD_LIBRARY_PATH` |
| Model cache | `/workspace/models` (override with `MODEL_DIR`) |
| Server logs | `/workspace/logs/llama-server.log` |
| Port | `10200` |

---

## 1. Create a Docker Hub access token

1. Sign in at [hub.docker.com](https://hub.docker.com).
2. If you don't already have one, create the repository: **Repositories → Create repository**,
   name `llamacpp-vast`, visibility **Public** (private works too, but then Vast needs
   Docker credentials on the template — public is simpler).
3. Go to **Account Settings → Personal access tokens → Generate new token**.
   - Description: `github-actions-llamacpp-vast`
   - Permissions: **Read & Write** (Read-only cannot push)
4. Copy the token now — Docker Hub shows it exactly once.

## 2. Add the repo secrets on GitHub

Create the GitHub repo first (web UI, or `gh repo create NicoVDT/llamacpp-vast --private --source . --remote origin`),
then **Settings → Secrets and variables → Actions → New repository secret**:

| Name | Value |
|---|---|
| `DOCKERHUB_USERNAME` | your Docker Hub username, e.g. `vdtnico` |
| `DOCKERHUB_TOKEN` | the token from step 1 |

The workflow builds `${DOCKERHUB_USERNAME}/llamacpp-vast`, so the username secret
also determines the namespace.

## 3. Push the repo (Windows / PowerShell)

The 79 MB tarball is committed, so this first push is the one slow part — after that
Actions does all the heavy lifting and nothing large leaves your machine again.

```powershell
cd C:\Users\Nico\llamacpp-vast
git init -b main
git add .
git commit -m "llama.cpp CUDA 12.6 sm_86 image for Vast.ai"
git remote add origin https://github.com/NicoVDT/llamacpp-vast.git
git push -u origin main
```

GitHub warns that `llamacpp-cu126-sm86.tar.gz` is over 50 MB. That's a warning, not an
error — the hard limit is 100 MB and the file is 79 MB.

Watch the build under the **Actions** tab. It takes roughly 8–15 minutes, most of it
pulling the CUDA base image. When it's green:

```powershell
docker manifest inspect vdtnico/llamacpp-vast:latest
```

Rebuild later by pushing any change, or from **Actions → Build and push image → Run workflow**.

## 4. Vast.ai template

**Templates → Create/Edit template.**

**Image path/tag**

```
vdtnico/llamacpp-vast:latest
```

**Docker options** — this is where the port mapping goes, and `10200` must be listed
or Vast will not open it:

```
-p 10200:10200 -p 22:22 -p 8080:8080 -p 8384:8384 -p 72299:72299
```

Keep whatever ports the stock Vast template already had (SSH, portal, Jupyter) and
just add `-p 10200:10200`.

**Environment variables**

| Variable | Value | Notes |
|---|---|---|
| `LLAMA_API_KEY` | *your key* | **Required.** The server refuses to start without it. Never in the image. |
| `OPEN_BUTTON_PORT` | `10200` | Optional — makes Vast's "Open" button hit the server. |
| `HF_TOKEN` | *your HF token* | Optional — only for gated repos or rate limits. |

Everything else has a working default baked in and only needs setting to override:
`MODEL_REPO`, `MODEL_QUANT`, `MODEL_FILE`, `MODEL_PATH`, `MODEL_DIR`, `MODEL_REVISION`,
`LLAMA_PORT`, `LLAMA_CTX`, `LLAMA_NGL`, `LLAMA_PARALLEL`, `LLAMA_ALIAS`,
`LLAMA_CACHE_TYPE_K`, `LLAMA_CACHE_TYPE_V`, `LLAMA_EXTRA_ARGS`, `TMUX_SESSION`,
`LOG_DIR`, `HF_ENDPOINT`, `VERIFY_SHA256`.

`VERIFY_SHA256=1` checks the downloaded file against the repo's `SHA256SUMS.txt`
(which this one publishes). Off by default because hashing 17 GB costs a few minutes
on every start, and the download is already length-verified.

**Disk space:** ask for at least **40 GB**. The image is ~20 GB and the model is ~17 GB.

**On-start script** (optional) — starts the server automatically on boot:

```
start-llama.sh
```

Leave it empty if you'd rather start it by hand, which is easier to debug the first time.

## 5. Start the server on a fresh instance

SSH in using the command Vast shows on the instance card, then:

```bash
start-llama.sh
```

That will:

1. Look up the `Q4_K_M` GGUF in `Blackfrost-AI/Qwen3.8-27B-ABLITERATED-GGUF` via the
   Hugging Face API (handles multi-part shards; resumes a partial download; skips the
   download entirely if the file is already complete). Against the repo as it stands
   today that resolves to a single file, `Qwen3.8-27B-ABLITERATED-Q4_K_M.gguf`,
   16,810,716,384 bytes (15.7 GiB) — verified, not assumed.
2. Launch `llama-server` in a detached tmux session named `llama`.
3. Wait until `/health` answers, then print the URL.

First run downloads ~17 GB. Later runs on the same instance start in under a minute.

Useful follow-ups:

```bash
tmux attach -t llama          # watch the server (detach: Ctrl-b then d)
tail -f /workspace/logs/llama-server.log
tmux kill-session -t llama    # stop it
start-llama.sh --download     # fetch the model only, don't start
start-llama.sh --foreground   # run in the foreground instead of tmux
nvidia-smi                    # confirm the 3090 and VRAM use
```

**Test it** — from the instance:

```bash
curl -s http://127.0.0.1:10200/v1/models -H "Authorization: Bearer $LLAMA_API_KEY"
```

From your Windows machine, using the **external** host and port Vast maps to `10200`
(shown on the instance card as something like `ssh5.vast.ai:41xxx`):

```powershell
curl.exe -s http://ssh5.vast.ai:41234/v1/chat/completions -H "Content-Type: application/json" -H "Authorization: Bearer YOUR_KEY" -d "{\"model\":\"qwen-local\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
```

Use `curl.exe`, not `curl` — bare `curl` in PowerShell is an alias for
`Invoke-WebRequest`, which takes different arguments.

---

## Server command

`start-llama.sh` runs exactly this:

```
llama-server -m <model.gguf> --host 0.0.0.0 --port 10200 -ngl 99 \
  --flash-attn on --jinja -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 \
  --parallel 1 --alias qwen-local --api-key <LLAMA_API_KEY>
```

## What's in the image

The tarball has one top-level `bin/` directory holding executables **and** shared
objects together — there is no separate `lib/` — so both `PATH` and `LD_LIBRARY_PATH`
point at `/opt/llamacpp/bin`. `llama-server` is at `/opt/llamacpp/bin/llama-server`.

The build drops the ~45 `test-*` binaries and keeps `llama-server`, `llama-cli`,
`llama-bench`, `llama-quantize`, `llama-gguf-split`, the mtmd tools and every `.so`.

`libggml-cuda.so` links `libcublas.so.12` and `libcudart.so.12`. The Dockerfile checks
for them and installs the CUDA 12.6 runtime libs **only if the base image lacks them**,
which avoids adding ~700 MB for nothing. A build-time `ldd` check fails the build on any
unresolved library, so a missing dependency surfaces in CI rather than on a rented box.
`libcuda.so.1` is expected to be missing at build time — it comes from the host driver.

No `ENTRYPOINT` or `CMD` is set, deliberately: overriding either breaks Vast's SSH,
Jupyter and portal, which are started by the base image's own entrypoint.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `LLAMA_API_KEY is not set` | Add it to the template's environment variables, or `export LLAMA_API_KEY=...` before running. |
| `bad interpreter: ...^M` | `start-llama.sh` got CRLF endings. `.gitattributes` prevents it and the Dockerfile strips them; if you edited the file outside git, re-save it as LF. |
| `error while loading shared libraries: libcublas.so.12` | Base image changed and lost cuBLAS. Rerun the build — the Dockerfile's check will install it. |
| `no .gguf matching 'Q4_K_M' found` | Repo renamed or reshared its files. List them at `https://huggingface.co/Blackfrost-AI/Qwen3.8-27B-ABLITERATED-GGUF/tree/main` and set `MODEL_FILE=<exact-name.gguf>`. |
| Several matches, none of them shards | Ambiguous quant string; the script stops instead of guessing. Set `MODEL_FILE`. |
| Connection refused from outside | `-p 10200:10200` missing from the template's Docker options, or you used the internal port instead of the external one Vast maps. |
| Out of VRAM at load | 27B Q4_K_M plus 128k of q8_0 KV is tight on 24 GB. Lower `LLAMA_CTX` (e.g. `65536`). |
| Actions fails with "no space left on device" | The disk-cleanup step was removed or the base image grew. Re-add it, or build on a larger runner. |
| Download died partway | Just rerun `start-llama.sh` — it resumes from the byte it stopped at. |
