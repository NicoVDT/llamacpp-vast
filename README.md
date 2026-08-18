# llamacpp-vast

Prebuilt llama.cpp (CUDA 12.6, `sm_86`) on top of Vast.ai's base image, so renting a
fresh RTX 3090 means pulling an image instead of a 25 minute recompile.

The ~19.5 GB GGUF is not in the image. It is pulled from Hugging Face on first run and
cached under `/workspace/models`. The default model is
`orcarouter/Qwen3.8-27B-Uncensored-GGUF` Q5_K_M, a `qwen35` hybrid (Gated DeltaNet plus
full attention) with an MTP speculative-decoding head baked into every quant.

| | |
|---|---|
| Image | `nicovdt/llamacpp-vast:latest` (6.2 GB compressed) |
| Base | `vastai/base-image:cuda-12.6.3-auto`, so SSH, Jupyter and the portal keep working |
| Binaries | `/opt/llamacpp/bin`, on `PATH` and `LD_LIBRARY_PATH` |
| Launcher | `start-llama.sh`, installed to `/usr/local/bin` and on `PATH` |
| Model cache | `/workspace/models` (override with `MODEL_DIR`) |
| Logs | `/workspace/logs/llama-server.log`, `/workspace/logs/tailscaled.log` |
| Port | `10200` |
| Tailnet | `llama-vast` via Tailscale userspace mode, giving a fixed baseURL across rentals |

---

## 1. Create a Docker Hub access token

1. Sign in at [hub.docker.com](https://hub.docker.com).
2. **Account Settings → Personal access tokens → Generate new token**.
   - Description: `github-actions-llamacpp-vast`
   - Permissions: **Read & Write**. Read-only cannot push.
3. Copy it immediately. Docker Hub shows it once.

You do not need to create the repository by hand. The first push creates
`nicovdt/llamacpp-vast` automatically, public by default.

## 2. Add the repo secrets on GitHub

**Settings → Secrets and variables → Actions → New repository secret**:

| Name | Value |
|---|---|
| `DOCKERHUB_USERNAME` | `nicovdt`, lowercase |
| `DOCKERHUB_TOKEN` | the token from step 1 |

`DOCKERHUB_USERNAME` must be lowercase. Docker Hub rejects a mixed-case username at
`docker login`, which fails the build at step 5 before it reaches the build itself.
The GitHub account is `NicoVDT` and the Docker Hub account is `nicovdt`, so this is
easy to get wrong. The workflow lowercases the value when constructing the image name
as a second line of defence, but the login step uses the secret as given.

Rotating the token: generate the new one, update the secret, then delete the old one.
Deleting first breaks the next build with an auth error that looks unrelated.

## 3. Push (Windows, PowerShell)

```powershell
cd C:\Users\Nico\llamacpp-vast
git push origin main
```

GitHub warns that `llamacpp-cu126-sm86.tar.gz` is over 50 MB. That is a warning. The
hard limit is 100 MB and the file is 79 MB.

The build takes about 6 minutes, mostly pulling the CUDA base image. README-only
commits do not trigger it (`paths-ignore`). When it is green:

```powershell
docker manifest inspect nicovdt/llamacpp-vast:latest
```

Rebuild by pushing, or from **Actions → Build and push image → Run workflow**.

## 4. Vast.ai template

**Image path/tag**

```
nicovdt/llamacpp-vast:latest
```

**Docker options**

```
-p 10200:10200 -p 22:22 -p 8080:8080 -p 8384:8384 -p 72299:72299
```

Keep whatever ports the stock template had and add `-p 10200:10200`. With Tailscale
working you do not strictly need that mapping, since the tailnet reaches the server
without one. Keep it as a way back in when an auth key has expired.

Port 10200 was chosen because the base image already uses others: Jupyter holds 8080,
Caddy holds 6006, 1111 and 8384.

**Environment variables**

| Variable | Value | Notes |
|---|---|---|
| `LLAMA_API_KEY` | your key | Required. The script refuses to start without it. Never baked into the image. |
| `HF_TOKEN` | your HF token | Required for this model. The default repo is gated, so the download 401s without it. See section 7. |
| `TS_AUTHKEY` | `tskey-auth-...` | Enables Tailscale. Reusable and ephemeral, see section 6. |
| `TS_HOSTNAME` | `llama-vast` | Already the default. Set only to change it. |
| `OPEN_BUTTON_PORT` | `10200` | Optional, points Vast's "Open" button at the server. |

Overridable, all with working defaults: `MODEL_REPO`, `MODEL_QUANT`, `MODEL_FILE`,
`MODEL_PATH`, `MODEL_DIR`, `MODEL_REVISION`, `LLAMA_PORT`, `LLAMA_CTX`, `LLAMA_NGL`,
`LLAMA_PARALLEL`, `LLAMA_ALIAS`, `LLAMA_CACHE_TYPE_K`, `LLAMA_CACHE_TYPE_V`,
`LLAMA_SPEC_TYPE`, `LLAMA_SPEC_DRAFT_N_MAX`, `LLAMA_EXTRA_ARGS`, `TMUX_SESSION`,
`LOG_DIR`, `HF_ENDPOINT`, `VERIFY_SHA256`, `TS_STATE_DIR`, `TS_SOCKET`,
`TS_SOCKS5_PORT`, `TS_EXTRA_ARGS`.

`LLAMA_SPEC_TYPE` defaults to `draft-mtp`, which turns on MTP speculative decoding using
the head baked into the model. Set it empty to disable, for instance if you point
`MODEL_REPO` at a model with no MTP head.

**Disk:** at least 40 GB. Image 6.2 GB compressed and larger unpacked, model ~19.5 GB.

**Reliability:** filter to 96% or above.

**On-start script** (optional):

```
start-llama.sh
```

Leave it empty the first time, since running it by hand is easier to debug.

Destroy instances, do not stop them. A stopped instance keeps billing for its disk.

## 5. Start the server

SSH in, then:

```bash
start-llama.sh
```

It is at `/usr/local/bin/start-llama.sh` and on `PATH`, so the bare name works. There
is no `/opt/start-llama.sh`.

That will:

0. Bring the node up on the tailnet as `llama-vast`, if `TS_AUTHKEY` is set. This runs
   before the download on purpose, so the box is reachable while ~19.5 GB pulls.
1. Check gated-repo access up front, so a missing or unapproved `HF_TOKEN` fails with a
   clear message instead of a bare 401 partway through the download.
2. Resolve the `Q5_K_M` GGUF in `orcarouter/Qwen3.8-27B-Uncensored-GGUF` through the
   Hugging Face API. Handles sharded files, resumes partial downloads, skips the
   download when the file is already complete. Today that resolves to a single file,
   `Qwen3.8-27B-Uncensored-Q5_K_M.gguf`, ~19.5 GB. The mmproj vision projector is
   filtered out; this is a text-only coding setup.
3. Launch `llama-server` in a detached tmux session named `llama`, with MTP
   speculative decoding on.
4. Wait for `/health`, then print the local URL, the tailnet URL and the exact
   `opencode.json` baseURL.

Options:

```bash
start-llama.sh --download     # fetch the model, do not start the server
start-llama.sh --foreground   # run in the foreground instead of tmux
```

Day to day:

```bash
tmux attach -t llama          # watch it, detach with Ctrl-b then d
tail -f /workspace/logs/llama-server.log
tmux kill-session -t llama    # stop it
nvidia-smi                    # confirm the 3090 and VRAM use
```

Check it from the instance:

```bash
curl -s http://127.0.0.1:10200/v1/models -H "Authorization: Bearer $LLAMA_API_KEY"
```

From Windows, use `curl.exe`. Bare `curl` in PowerShell is an alias for
`Invoke-WebRequest` and takes different arguments.

## 6. Tailscale, for a stable baseURL

Vast assigns the external port at rent time, so `ssh5.vast.ai:47237` becomes something
else on the next box and the client config goes stale every session. A tailnet name
does not move.

Create the key at [admin console → Keys](https://login.tailscale.com/admin/settings/keys):

| Option | Set to | Why |
|---|---|---|
| **Reusable** | on | One key covers every box. A single-use key authenticates once and then fails silently on the next instance. |
| **Ephemeral** | on | This is what keeps the hostname stable. Ephemeral nodes are removed shortly after going offline, so a destroyed instance frees the name `llama-vast`. |
| **Expiry** | set a date | Do not choose never. 90 days is the maximum. An expired key fails at `tailscale up` with a message that reads like a network fault. |

Paste it into `TS_AUTHKEY`. MagicDNS must be on for the name to resolve, which is the
Tailscale default.

`start-llama.sh` prints the address once the server answers:

```
[start-llama] tailnet name: llama-vast.tailnet-name.ts.net
[start-llama] reachable on the tailnet at: http://llama-vast.tailnet-name.ts.net:10200
[start-llama] opencode.json baseURL:       http://llama-vast.tailnet-name.ts.net:10200/v1
```

The tailnet IP (`100.x.y.z`) is printed too and works with MagicDNS off.

Traffic over the tailnet is WireGuard encrypted, but `LLAMA_API_KEY` still applies.
Tailscale controls who can reach the port, the API key controls who can use it.

### The one way this still breaks

Tailscale appends a numeric suffix when a name is taken. Rent a new box while the old
`llama-vast` node still exists and this one becomes `llama-vast-1`, moving the baseURL
again, which is the churn this was meant to remove.

`start-llama.sh` reads back the name it actually got and warns loudly when it has been
suffixed, so this shows up in the startup log rather than as a connection error hours
later. Prevent it by using an ephemeral key and destroying old instances. If it happens
anyway, delete the stale node in the admin console and rerun.

### Debugging

```bash
tailscale status                       # peers and this node's name
tailscale ip -4                        # 100.x.y.z address
tail -f /workspace/logs/tailscaled.log
```

`tailscaled` runs with `--tun=userspace-networking` because Vast containers have no
`/dev/net/tun` and no `NET_ADMIN`. Inbound tailnet connections are proxied to local
listeners, which is all this needs, since `llama-server` binds `0.0.0.0`. A SOCKS5
proxy sits on `localhost:1055` for reaching other tailnet nodes from inside.

## 7. Model access (Hugging Face gating)

The default model, `orcarouter/Qwen3.8-27B-Uncensored-GGUF`, is a gated repo. File
listing works without a token (which is how discovery finds the file), but the actual
download does not, so `HF_TOKEN` is required. `start-llama.sh` probes access before
downloading and stops with a clear message if it is missing, rather than dying with a
bare 401 partway through ~19.5 GB.

One-time setup:

1. Open [the model page](https://huggingface.co/orcarouter/Qwen3.8-27B-Uncensored-GGUF)
   while logged in and accept the conditions. Access is auto-granted, so this is instant.
2. Create a token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens).
   Read scope is enough.
3. Add it to the Vast template as `HF_TOKEN`, alongside `LLAMA_API_KEY` and `TS_AUTHKEY`.

Accepting the terms and creating the token are both browser steps and cannot be
automated. The token then works for every future rental.

---

## Server command and why each flag is there

```
llama-server -m <model.gguf> --host 0.0.0.0 --port 10200 -ngl 99 \
  --flash-attn on --jinja -c 130000 --cache-type-k q8_0 --cache-type-v q8_0 \
  --parallel 1 --alias qwen-local --api-key <LLAMA_API_KEY> \
  --spec-type draft-mtp --spec-draft-n-max 2
```

**`--flash-attn on`** takes a value now, not a bare flag. Flash attention must be on
for the q8_0 KV cache to work. Without it the KV cache falls back to F16 and doubles
in size.

**`--parallel 1`** matters more than it looks. The default is 4 slots sharing one
context pool. A single 29k token agentic turn starves the others and triggers KV cache
retry cascades (`failed to find a memory slot`). One slot gets the whole context.

**`--spec-type draft-mtp --spec-draft-n-max 2`** turns on MTP speculative decoding. This
model bakes a `nextn`/MTP head into every quant, so llama-server drafts up to 2 tokens
with that head and verifies them in a single forward pass, no separate draft model
needed. Confirm it is active in the load log: the model reports as 65 blocks (`n_layer`
64, `n_layer_all` 65). Disable with `LLAMA_SPEC_TYPE=` (empty).

**`-c 130000`** is a VRAM tradeoff, not a model limit. The model's trained context is
262144 (GGUF `context_length`). The constraint is the 24 GB card. Q5_K_M weights are
~19.5 GB, and this `qwen35` hybrid keeps only 16 of 64 layers as full-attention KV
(the rest are recurrent Gated DeltaNet), so KV is small: the Q4 build measured ~20.7 GB
total at 131072, meaning ~3.9 GB of KV plus overhead. On Q5 that puts 130000 near
~23.4 GB of 24.5, which is close to the edge. If it OOMs at load, drop to 110000
(~22.8 GB). Q4_K_M, if you ever switch to it, comfortably holds 155000.

**`--alias qwen-local`** gives a clean model id instead of the full file path.

The model's recommended sampling is `--temp 1.0 --top-p 0.95 --top-k 20`. opencode sets
sampling per request, so it is left to the client rather than forced server-side. To
pin it on the server anyway, add it via `LLAMA_EXTRA_ARGS`.

### Measured performance

These numbers are from the previous model (Blackfrost Q4_K_M, no MTP) and are kept as a
rough baseline. The current model is Q5_K_M with MTP speculative decoding, so generation
should be faster on acceptance-friendly output and needs re-measuring on a real box.

| | |
|---|---|
| Generation, fresh context | ~41 tok/s (Q4, no MTP) |
| Generation at 84k context | ~28 tok/s (Q4, no MTP) |
| Prompt processing | ~1100 to 1360 tok/s |

Generation slows as context fills. That is expected.

### If it runs out of VRAM

130000 on Q5_K_M is near the edge, around ~23.4 GB of 24.5, so an OOM at load is a real
possibility here and the first fix is simply to lower `LLAMA_CTX` to 110000 (~22.8 GB).
Before assuming the number is too high, rule out configuration: flash attention must be
on (without it the KV cache is F16 and roughly doubles), both `--cache-type-k` and
`--cache-type-v` must be `q8_0`, and nothing else should be holding VRAM (`nvidia-smi`).
Each 10k of context is roughly 300 to 390 MB of KV. To reclaim the most room, switch to
`MODEL_QUANT=Q4_K_M`, which frees ~2.7 GB of weights and comfortably holds 155000.

## Client setup

opencode talks to llama-server directly, with no LiteLLM translation layer, and uses a
~10k system prompt against Claude Code's ~29k.

`%USERPROFILE%\.config\opencode\opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "llamacpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama-server (3090)",
      "options": {
        "baseURL": "http://llama-vast.tailnet-name.ts.net:10200/v1",
        "apiKey": "<LLAMA_API_KEY>"
      },
      "models": {
        "qwen-local": {
          "name": "Qwen3.8 27B Uncensored",
          "supportsToolCalls": true,
          "limit": { "context": 130000, "output": 8192 }
        },
        "claude-haiku-4-5": {
          "name": "Qwen (small task model)",
          "supportsToolCalls": true,
          "limit": { "context": 130000, "output": 4096 }
        }
      }
    }
  },
  "model": "llamacpp/qwen-local"
}
```

`baseURL` must sit inside `options` or you get a URL parse error.

The `claude-haiku-4-5` entry is not a mistake. opencode picks a "small model" for title
generation from a hardcoded list containing that name, so mapping it to the same
endpoint stops it failing.

For context management, prefer an `AGENTS.md` in the project root over `/compact`.
opencode reads it at start. `/compact` makes Qwen summarise its own history and it
loses specifics.

### Claude Code fallback

Claude Code speaks the Anthropic Messages API, so it needs LiteLLM as a translation
layer: point `openai/qwen-local` at the server, run it on port 4000, then set
`ANTHROPIC_BASE_URL=http://127.0.0.1:4000`, `ANTHROPIC_AUTH_TOKEN=<litellm master key>`,
`ANTHROPIC_MODEL=qwen-local`, and `ANTHROPIC_API_KEY=` blank.

Use `127.0.0.1`, not `localhost`. On Windows the IPv6 resolution breaks it.

## What is in the image

The tarball has one top-level `bin/` holding executables and shared objects together.
There is no separate `lib/`, which is why `PATH` and `LD_LIBRARY_PATH` both point at
`/opt/llamacpp/bin`.

The build drops the ~45 `test-*` binaries and keeps `llama-server`, `llama-cli`,
`llama-bench`, `llama-perplexity`, `llama-quantize`, `llama-gguf-split`, the mtmd tools
and every `.so`. `llama-bench` and `llama-perplexity` are asserted present at build
time, since they are needed for benchmarking quants and quality.

`libggml-cuda.so` links `libcublas.so.12` and `libcudart.so.12`. The Dockerfile
installs the CUDA 12.6 runtime libraries only if the base image lacks them, avoiding
~700 MB for nothing, then an `ldd` gate fails the build on any unresolved library so a
missing dependency surfaces in CI instead of on a rented box. `libcuda.so.1` is
expected to be absent at build time. It comes from the host driver.

Tailscale is installed from version-pinned, checksum-verified static binaries rather
than piping `install.sh` into a shell.

No `ENTRYPOINT` or `CMD` is set. The shipped image inherits Vast's own
`/opt/instance-tools/bin/entrypoint.sh`, which is what starts SSH, Jupyter and the
portal. Overriding either would kill all three and leave no way in.

## Outstanding

- Confirm 130000 context actually loads on Q5_K_M without OOM. It is estimated near
  ~23.4 GB of 24.5. If it fails, drop `LLAMA_CTX` to 110000.
- Verify MTP is active in the load log (`n_layer_all` 65) and re-measure generation
  speed against the old Q4 no-MTP baseline.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `LLAMA_API_KEY is not set` | The script recovers it from `/proc/1/environ`, falling back to `/etc/environment`, because sshd does not inherit the container's environment. If this still fires, the variable genuinely is not set: check the template's CLI preview actually contains `-e LLAMA_API_KEY=...`. |
| `start-llama.sh: command not found` | Docker `ENV` does not reach SSH login shells. The image writes the paths to `/etc/profile.d/llamacpp.sh` and `/root/.bashrc`, and the script repairs `PATH` itself. If it still fires, run it as `/usr/local/bin/start-llama.sh` and tell me, because that means neither file is being read. |
| `bad interpreter: ...^M` | CRLF line endings on the script. `.gitattributes` prevents it and the Dockerfile strips them. Re-save as LF if edited outside git. |
| `libcublas.so.12` not found | Base image changed and lost cuBLAS. Rerun the build, the check installs it. |
| `no .gguf matching 'Q5_K_M'` | Repo renamed or resharded. List files at the repo tree and set `MODEL_FILE=<exact-name.gguf>`. |
| `is gated and no HF_TOKEN is set` | The default model repo is gated. Accept the terms at the repo page while logged in, create a read token, set it as `HF_TOKEN`. See section 7. |
| `returned 401 ... even with HF_TOKEN` | Token is valid but the account was never granted access. Open the repo page while logged in and accept the conditions. |
| `unknown argument: --spec-type` | The binaries predate MTP support. These do not, but if you swapped them, disable with `LLAMA_SPEC_TYPE=`. |
| Several matches, none sharded | Ambiguous quant string. The script stops instead of guessing. Set `MODEL_FILE`. |
| `failed to find a memory slot` | `--parallel` above 1. Slots are sharing the context pool. |
| Connection refused from outside | `-p 10200:10200` missing from Docker options, or the internal port used instead of the mapped external one. |
| Out of VRAM at load | Do not just lower the context. See "If it runs out of VRAM" above. |
| Registered as `llama-vast-1` | A stale node holds the name. Ephemeral key, destroy old instances, delete the stale node. |
| `'tailscale up' failed` | Expired key, single-use key reused, or ACLs. Check `/workspace/logs/tailscaled.log`. |
| Tailscale skipped entirely | `TS_AUTHKEY` not set. The script logs it and falls back to Vast's mapped port. |
| Tailnet name will not resolve | MagicDNS off, or client not connected. Use the `100.x.y.z` address. |
| Actions fails, `repository name must be lowercase` | `DOCKERHUB_USERNAME` has capitals. |
| Actions fails at `docker login` | Wrong username case, or the token was deleted before the secret was updated. |
| Actions fails, no space left | The disk cleanup step was removed, or the base image grew. |
| Download died partway | Rerun `start-llama.sh`. It resumes from where it stopped. |
