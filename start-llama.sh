#!/usr/bin/env bash
#
# Fetch the GGUF (if it isn't already on disk) and launch llama-server inside a
# detached tmux session.
#
#   start-llama.sh              download if needed, then start the server
#   start-llama.sh --download   download only, don't start the server
#   start-llama.sh --foreground run in the foreground instead of tmux
#
set -euo pipefail

MODEL_REPO="${MODEL_REPO:-Blackfrost-AI/Qwen3.8-27B-ABLITERATED-GGUF}"
MODEL_QUANT="${MODEL_QUANT:-Q4_K_M}"
MODEL_DIR="${MODEL_DIR:-/workspace/models}"
MODEL_FILE="${MODEL_FILE:-}"          # pin an exact filename to skip auto-discovery
MODEL_PATH="${MODEL_PATH:-}"          # or point straight at a local .gguf
MODEL_REVISION="${MODEL_REVISION:-main}"
HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"

LLAMA_HOST="${LLAMA_HOST:-0.0.0.0}"
LLAMA_PORT="${LLAMA_PORT:-10200}"
LLAMA_NGL="${LLAMA_NGL:-99}"
LLAMA_CTX="${LLAMA_CTX:-131072}"
LLAMA_PARALLEL="${LLAMA_PARALLEL:-1}"
LLAMA_ALIAS="${LLAMA_ALIAS:-qwen-local}"
LLAMA_CACHE_TYPE_K="${LLAMA_CACHE_TYPE_K:-q8_0}"
LLAMA_CACHE_TYPE_V="${LLAMA_CACHE_TYPE_V:-q8_0}"
LLAMA_EXTRA_ARGS="${LLAMA_EXTRA_ARGS:-}"

TMUX_SESSION="${TMUX_SESSION:-llama}"
LOG_DIR="${LOG_DIR:-/workspace/logs}"
LOG_FILE="$LOG_DIR/llama-server.log"
RUN_DIR="${RUN_DIR:-/run/llama}"

MODE="tmux"
case "${1:-}" in
    --download)   MODE="download" ;;
    --foreground) MODE="foreground" ;;
    "")           ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

log()  { echo "[start-llama] $*"; }
die()  { echo "[start-llama] ERROR: $*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------

if [ "$MODE" != "download" ] && [ -z "${LLAMA_API_KEY:-}" ]; then
    die "LLAMA_API_KEY is not set. Set it in the Vast template's environment
       variables (or 'export LLAMA_API_KEY=...' before running this script).
       The key is never baked into the image."
fi

command -v llama-server >/dev/null 2>&1 || die "llama-server not on PATH (expected /opt/llamacpp/bin)"
command -v curl         >/dev/null 2>&1 || die "curl not installed"
command -v jq           >/dev/null 2>&1 || die "jq not installed"

mkdir -p "$MODEL_DIR" "$LOG_DIR"

# Hugging Face auth is optional: only needed for gated repos or to dodge
# anonymous rate limits.
CURL_AUTH=()
if [ -n "${HF_TOKEN:-}" ]; then
    CURL_AUTH=(-H "Authorization: Bearer ${HF_TOKEN}")
    log "using HF_TOKEN for Hugging Face requests"
fi
curl_hf() { curl "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" "$@"; }

# --- work out which file(s) we need ----------------------------------------

# Files matching the quant, newest API listing, mmproj/vision projectors excluded.
discover_files() {
    local json
    json="$(curl_hf -fsSL --retry 3 --retry-delay 2 \
        "${HF_ENDPOINT}/api/models/${MODEL_REPO}/revision/${MODEL_REVISION}")" \
        || die "could not query the Hugging Face API for ${MODEL_REPO}.
       Check the repo name, or set HF_TOKEN if it is gated."

    printf '%s' "$json" | jq -r --arg q "$MODEL_QUANT" '
        (.siblings // [])[].rfilename
        | select(test("\\.gguf$"; "i"))
        | select(test($q; "i"))
        | select(test("mmproj|vision|projector"; "i") | not)
    ' | sort
}

# Multi-part GGUFs are named ...-00001-of-00003.gguf; llama-server only needs to
# be pointed at part 1, but every part has to be on disk.
primary_shard() {
    local first
    first="$(printf '%s\n' "$@" | grep -E -- '-0*1-of-[0-9]+\.gguf$' | head -n1 || true)"
    [ -n "$first" ] && { printf '%s' "$first"; return 0; }
    printf '%s' "$1"
}

# HF answers with a 302 to a CDN, so the *last* content-length is the real one.
# tolower() rather than gawk's IGNORECASE, because Ubuntu's awk is mawk.
# A failed HEAD must not kill the script -- 0 means "unknown", handled below.
remote_size() {
    local url="$1"
    { curl_hf -fsIL --retry 3 --retry-delay 2 "$url" 2>/dev/null || true; } \
        | awk 'tolower($0) ~ /^content-length:/ {gsub(/\r/,""); n=$2} END {print n+0}'
}

local_size() { [ -f "$1" ] && stat -c %s "$1" || echo 0; }

download_one() {
    local rfile="$1"
    local dest="$MODEL_DIR/$(basename "$rfile")"
    local url="${HF_ENDPOINT}/${MODEL_REPO}/resolve/${MODEL_REVISION}/${rfile}?download=true"
    local remote local_bytes
    remote="$(remote_size "$url")"

    local_bytes="$(local_size "$dest")"
    if [ "$remote" -gt 0 ] && [ "$local_bytes" -eq "$remote" ]; then
        log "already complete: $(basename "$rfile") ($(numfmt --to=iec "$local_bytes" 2>/dev/null || echo "$local_bytes B"))"
        return 0
    fi
    if [ "$local_bytes" -gt 0 ] && [ "$remote" -gt 0 ] && [ "$local_bytes" -gt "$remote" ]; then
        log "local file larger than remote -- discarding and re-downloading"
        rm -f "$dest"
        local_bytes=0
    fi
    # HEAD failed but we already hold bytes: resuming would ask for a range past
    # EOF and come back as a confusing 416 on a file that is probably fine.
    if [ "$remote" -eq 0 ] && [ "$local_bytes" -gt 0 ]; then
        log "WARNING: could not read the remote size for $(basename "$rfile");
       keeping the existing local file ($local_bytes bytes) unverified.
       Delete it and rerun if the server fails to load the model."
        return 0
    fi

    if [ "$local_bytes" -gt 0 ]; then
        log "resuming $(basename "$rfile") at $(numfmt --to=iec "$local_bytes" 2>/dev/null || echo "$local_bytes")"
    else
        log "downloading $(basename "$rfile") ($(numfmt --to=iec "$remote" 2>/dev/null || echo "$remote B"))"
    fi

    # A progress bar is helpful over SSH and pure noise in an on-start log.
    local progress=--progress-bar
    [ -t 2 ] || progress=--no-progress-meter

    curl_hf -fL --retry 5 --retry-delay 5 --retry-connrefused \
        -C - "$progress" -o "$dest" "$url" \
        || die "download failed for $rfile"

    if [ "$remote" -gt 0 ] && [ "$(local_size "$dest")" -ne "$remote" ]; then
        die "size mismatch after downloading $rfile -- rerun to resume"
    fi
}

# Optional integrity check against the repo's SHA256SUMS.txt. Off by default:
# hashing 17 GB adds a few minutes to every start, and curl already verifies the
# byte count. Turn on with VERIFY_SHA256=1 after a download you don't trust.
verify_sha256() {
    local sums
    sums="$(curl_hf -fsSL --max-time 60 \
        "${HF_ENDPOINT}/${MODEL_REPO}/resolve/${MODEL_REVISION}/SHA256SUMS.txt" 2>/dev/null || true)"
    if [ -z "$sums" ]; then
        log "repo publishes no SHA256SUMS.txt -- skipping checksum verification"
        return 0
    fi
    local f base expected actual
    for f in "$@"; do
        base="$(basename "$f")"
        expected="$(printf '%s\n' "$sums" \
            | awk -v b="$base" '$2 == b || $2 == "*" b {print $1; exit}')"
        if [ -z "$expected" ]; then
            log "no checksum listed for $base -- skipping"
            continue
        fi
        log "verifying sha256 of $base (several minutes) ..."
        actual="$(sha256sum "$MODEL_DIR/$base" | awk '{print $1}')"
        [ "$actual" = "$expected" ] || die "checksum mismatch for $base
       expected $expected
       actual   $actual
       Delete $MODEL_DIR/$base and rerun to re-download."
        log "checksum OK: $base"
    done
}

if [ -n "$MODEL_PATH" ]; then
    [ -f "$MODEL_PATH" ] || die "MODEL_PATH is set to $MODEL_PATH but that file does not exist"
    log "using MODEL_PATH=$MODEL_PATH (skipping download)"
else
    if [ -n "$MODEL_FILE" ]; then
        files=("$MODEL_FILE")
        log "MODEL_FILE pinned: $MODEL_FILE"
    else
        log "looking up ${MODEL_QUANT} files in ${MODEL_REPO} ..."
        # Deliberately not `mapfile < <(discover_files)`: die() inside a process
        # substitution only kills the subshell, so a failed API call would look
        # like "no matches" instead of the real error.
        discovered="$(discover_files)"
        [ -n "$discovered" ] || die "no .gguf matching '${MODEL_QUANT}' found in ${MODEL_REPO}.
       List the repo's files at ${HF_ENDPOINT}/${MODEL_REPO}/tree/${MODEL_REVISION}
       and pin one with MODEL_FILE=<name.gguf>."
        mapfile -t files <<< "$discovered"

        # Several distinct (non-sharded) matches means the quant string is
        # ambiguous -- better to stop than to download 17 GB of the wrong thing.
        if [ "${#files[@]}" -gt 1 ] && ! printf '%s\n' "${files[@]}" | grep -qE -- '-[0-9]+-of-[0-9]+\.gguf$'; then
            printf '[start-llama] ERROR: %s matches, none of them shards:\n' "${#files[@]}" >&2
            printf '  %s\n' "${files[@]}" >&2
            die "pick one and set MODEL_FILE=<name.gguf>"
        fi
        log "matched ${#files[@]} file(s): ${files[*]}"
    fi

    for f in "${files[@]}"; do
        download_one "$f"
    done

    if [ "${VERIFY_SHA256:-0}" = "1" ]; then
        verify_sha256 "${files[@]}"
    fi

    MODEL_PATH="$MODEL_DIR/$(basename "$(primary_shard "${files[@]}")")"
fi

[ -s "$MODEL_PATH" ] || die "model file is missing or empty: $MODEL_PATH"
log "model ready: $MODEL_PATH"

if [ "$MODE" = "download" ]; then
    log "--download given, not starting the server"
    exit 0
fi

# --- launch ----------------------------------------------------------------

# The API key is passed through a 0600 env file rather than being interpolated
# into the tmux command line, which also sidesteps tmux's habit of inheriting
# the *server's* environment instead of the client's for pre-existing sessions.
mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR"
ENV_FILE="$RUN_DIR/llama.env"
umask 077
cat > "$ENV_FILE" <<EOF
MODEL_PATH=$MODEL_PATH
LLAMA_HOST=$LLAMA_HOST
LLAMA_PORT=$LLAMA_PORT
LLAMA_NGL=$LLAMA_NGL
LLAMA_CTX=$LLAMA_CTX
LLAMA_PARALLEL=$LLAMA_PARALLEL
LLAMA_ALIAS=$LLAMA_ALIAS
LLAMA_CACHE_TYPE_K=$LLAMA_CACHE_TYPE_K
LLAMA_CACHE_TYPE_V=$LLAMA_CACHE_TYPE_V
LLAMA_EXTRA_ARGS=$LLAMA_EXTRA_ARGS
LLAMA_API_KEY=$LLAMA_API_KEY
LOG_FILE=$LOG_FILE
LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-/opt/llamacpp/bin}
PATH=$PATH
EOF
chmod 600 "$ENV_FILE"

RUNNER="$RUN_DIR/launch-llama.sh"
cat > "$RUNNER" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
set -a; . /run/llama/llama.env; set +a
echo "=== llama-server starting $(date -Is) ===" | tee -a "$LOG_FILE"
llama-server \
    -m "$MODEL_PATH" \
    --host "$LLAMA_HOST" \
    --port "$LLAMA_PORT" \
    -ngl "$LLAMA_NGL" \
    --flash-attn on \
    --jinja \
    -c "$LLAMA_CTX" \
    --cache-type-k "$LLAMA_CACHE_TYPE_K" \
    --cache-type-v "$LLAMA_CACHE_TYPE_V" \
    --parallel "$LLAMA_PARALLEL" \
    --alias "$LLAMA_ALIAS" \
    --api-key "$LLAMA_API_KEY" \
    $LLAMA_EXTRA_ARGS 2>&1 | tee -a "$LOG_FILE"
status=${PIPESTATUS[0]}
echo "=== llama-server exited with status $status at $(date -Is) ===" | tee -a "$LOG_FILE"
# Keep the pane alive so the failure is readable after the fact.
echo "(pane held open -- press Ctrl-C or 'exit' to close)"
sleep infinity
EOF
chmod 700 "$RUNNER"

if [ "$MODE" = "foreground" ]; then
    log "running in the foreground"
    exec "$RUNNER"
fi

command -v tmux >/dev/null 2>&1 || die "tmux not installed"
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    die "tmux session '$TMUX_SESSION' already exists.
       Attach:  tmux attach -t $TMUX_SESSION
       Replace: tmux kill-session -t $TMUX_SESSION && start-llama.sh"
fi

tmux new-session -d -s "$TMUX_SESSION" "$RUNNER"
log "started llama-server in tmux session '$TMUX_SESSION'"
log "  attach:  tmux attach -t $TMUX_SESSION   (detach with Ctrl-b then d)"
log "  logs:    tail -f $LOG_FILE"

# A 27B model at 128k context takes a while to load; poll rather than guess.
log "waiting for the server to answer on port $LLAMA_PORT ..."
for i in $(seq 1 180); do
    if curl -fsS -o /dev/null "http://127.0.0.1:${LLAMA_PORT}/health" 2>/dev/null; then
        log "server is up: http://127.0.0.1:${LLAMA_PORT} (alias: $LLAMA_ALIAS)"
        exit 0
    fi
    if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        die "tmux session died during startup -- see $LOG_FILE"
    fi
    sleep 5
done
log "still not answering after 15 minutes; check $LOG_FILE"
exit 1
