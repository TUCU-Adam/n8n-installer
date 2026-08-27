#!/bin/bash
# Generates docker-compose.ollama-instances.yml with extra Ollama instances
# (ollama2 .. ollamaN) for multi-GPU hosts.
# Usage: OLLAMA_INSTANCE_COUNT=3 bash scripts/generate_ollama_instances.sh
#
# Instance 1 is the stock "ollama" container defined in docker-compose.yml and
# is never touched here, so a default install (count 1) behaves exactly as
# before: the output file is REMOVED rather than written empty, because a
# Compose overlay with a bare 'services:' key is a fatal parse error.
#
# This script is idempotent - the file is overwritten on each run.

set -euo pipefail

# Source the utilities file and initialize paths
source "$(dirname "$0")/utils.sh"
init_paths

OUTPUT_FILE="$PROJECT_ROOT/docker-compose.ollama-instances.yml"
OLLAMA_MAX_INSTANCES=8

# Load values from .env if not already set in the environment
if [[ -f "$ENV_FILE" ]]; then
    [[ -z "${OLLAMA_INSTANCE_COUNT:-}" ]] && OLLAMA_INSTANCE_COUNT=$(read_env_var "OLLAMA_INSTANCE_COUNT")
    [[ -z "${COMPOSE_PROFILES:-}" ]] && COMPOSE_PROFILES=$(read_env_var "COMPOSE_PROFILES")
fi
OLLAMA_INSTANCE_COUNT="${OLLAMA_INSTANCE_COUNT:-1}"
COMPOSE_PROFILES="${COMPOSE_PROFILES:-}"

# Validate the count
if ! [[ "$OLLAMA_INSTANCE_COUNT" =~ ^0*[1-9][0-9]*$ ]]; then
    log_error "OLLAMA_INSTANCE_COUNT must be a positive integer, got: '$OLLAMA_INSTANCE_COUNT'"
    exit 1
fi
OLLAMA_INSTANCE_COUNT=$((10#$OLLAMA_INSTANCE_COUNT))
if (( OLLAMA_INSTANCE_COUNT > OLLAMA_MAX_INSTANCES )); then
    log_warning "OLLAMA_INSTANCE_COUNT=$OLLAMA_INSTANCE_COUNT exceeds the supported maximum of $OLLAMA_MAX_INSTANCES; capping to $OLLAMA_MAX_INSTANCES."
    OLLAMA_INSTANCE_COUNT=$OLLAMA_MAX_INSTANCES
fi

# Match the active Ollama hardware profile (mutually exclusive, set by the wizard)
TEMPLATE="ollama-instance-template"
if is_profile_active "gpu-nvidia"; then
    HW_PROFILE="gpu-nvidia"
elif is_profile_active "gpu-amd"; then
    HW_PROFILE="gpu-amd"
    TEMPLATE="ollama-instance-template-amd"
elif is_profile_active "cpu"; then
    HW_PROFILE="cpu"
else
    HW_PROFILE=""
fi

# Nothing to generate: Ollama not deployed, or a single instance (the default).
# Removing the file is required - a stale one would resurrect instances after a
# downscale, or point them at the wrong hardware profile after a switch.
if [[ -z "$HW_PROFILE" ]] || (( OLLAMA_INSTANCE_COUNT <= 1 )); then
    if [[ -f "$OUTPUT_FILE" ]]; then
        log_info "Removing $OUTPUT_FILE (single Ollama instance)"
        rm -f "$OUTPUT_FILE"
    fi
    cleanup_stale_ollama_instances 1 "$OLLAMA_MAX_INSTANCES"
    exit 0
fi

log_info "Generating extra Ollama instances configuration..."
log_info "OLLAMA_INSTANCE_COUNT=$OLLAMA_INSTANCE_COUNT (hardware profile: $HW_PROFILE)"

cat > "$OUTPUT_FILE" << 'EOF'
# Auto-generated file for extra Ollama instances (ollama2, ollama3, ...)
# Regenerate with: bash scripts/generate_ollama_instances.sh
# DO NOT EDIT MANUALLY - this file is overwritten on each run
#
# Instance 1 is the stock "ollama" container defined in docker-compose.yml.
# All instances share the ollama_storage volume, so models are downloaded once.
# Extra instances are internal only (http://ollama2:11434) - no published ports.
#
# Tune an instance WITHOUT regenerating by setting OLLAMA<N>_* in .env, e.g.
#   OLLAMA2_GPU_DEVICES=2
#   OLLAMA2_KEEP_ALIVE=-1
#   OLLAMA2_MAX_LOADED_MODELS=1
# Each falls back to the global OLLAMA_* value, then to the stack default.

services:
EOF

for (( i = 2; i <= OLLAMA_INSTANCE_COUNT; i++ )); do
cat >> "$OUTPUT_FILE" << EOF
  ollama${i}:
    extends:
      file: docker-compose.yml
      service: ${TEMPLATE}
    container_name: ollama${i}
    profiles: ["${HW_PROFILE}"]
    restart: unless-stopped
    environment:
      OLLAMA_CONTEXT_LENGTH: "\${OLLAMA${i}_CONTEXT_LENGTH:-\${OLLAMA_CONTEXT_LENGTH:-8192}}"
      OLLAMA_FLASH_ATTENTION: 1
      OLLAMA_GPU_OVERHEAD: "\${OLLAMA${i}_GPU_OVERHEAD:-\${OLLAMA_GPU_OVERHEAD:-0}}"
      OLLAMA_KEEP_ALIVE: "\${OLLAMA${i}_KEEP_ALIVE:-\${OLLAMA_KEEP_ALIVE:-}}"
      OLLAMA_KV_CACHE_TYPE: "\${OLLAMA${i}_KV_CACHE_TYPE:-\${OLLAMA_KV_CACHE_TYPE:-q8_0}}"
      OLLAMA_MAX_LOADED_MODELS: "\${OLLAMA${i}_MAX_LOADED_MODELS:-\${OLLAMA_MAX_LOADED_MODELS:-2}}"
      OLLAMA_NUM_PARALLEL: "\${OLLAMA${i}_NUM_PARALLEL:-\${OLLAMA_NUM_PARALLEL:-}}"
      OLLAMA_SCHED_SPREAD: "\${OLLAMA${i}_SCHED_SPREAD:-\${OLLAMA_SCHED_SPREAD:-}}"
EOF

    case "$HW_PROFILE" in
        gpu-nvidia)
cat >> "$OUTPUT_FILE" << EOF
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ["\${OLLAMA${i}_GPU_DEVICES:-$((i - 1))}"]
              capabilities: [gpu]

EOF
            ;;
        gpu-amd)
            # ROCm passes all of /dev/kfd and /dev/dri to every container, so
            # pinning is done with HIP_VISIBLE_DEVICES, not deploy.resources.
cat >> "$OUTPUT_FILE" << EOF
      HIP_VISIBLE_DEVICES: "\${OLLAMA${i}_GPU_DEVICES:-$((i - 1))}"
      ROCR_VISIBLE_DEVICES: "\${OLLAMA${i}_GPU_DEVICES:-$((i - 1))}"

EOF
            ;;
        cpu)
            printf '\n' >> "$OUTPUT_FILE"
            ;;
    esac
done

log_success "Generated $OUTPUT_FILE with $((OLLAMA_INSTANCE_COUNT - 1)) extra Ollama instance(s)"

# Drop containers above the new count - a plain 'docker compose down' leaves
# them behind as orphans, still holding a GPU.
cleanup_stale_ollama_instances "$OLLAMA_INSTANCE_COUNT" "$OLLAMA_MAX_INSTANCES"
