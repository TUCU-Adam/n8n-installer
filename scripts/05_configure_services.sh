#!/bin/bash

set -e

# Source the utilities file
source "$(dirname "$0")/utils.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

# Ensure .env exists
if [ ! -f "$ENV_FILE" ]; then
  touch "$ENV_FILE"
fi

# Helper: read value from .env (without surrounding quotes)
read_env_var() {
  local var_name="$1"
  if grep -q "^${var_name}=" "$ENV_FILE"; then
    grep "^${var_name}=" "$ENV_FILE" | cut -d'=' -f2- | sed 's/^"//' | sed 's/"$//'
  else
    echo ""
  fi
}

# Helper: upsert value into .env (quote the value)
write_env_var() {
  local var_name="$1"
  local var_value="$2"
  if grep -q "^${var_name}=" "$ENV_FILE"; then
    # use different delimiter to be safe
    sed -i.bak "\|^${var_name}=|d" "$ENV_FILE"
  fi
  echo "${var_name}=\"${var_value}\"" >> "$ENV_FILE"
}

log_info "Configuring service options in .env..."


# ----------------------------------------------------------------
# Prompt for OpenAI API key (optional) using .env value as source of truth
# ----------------------------------------------------------------
EXISTING_OPENAI_API_KEY="$(read_env_var OPENAI_API_KEY)"
OPENAI_API_KEY=""
if [[ -z "$EXISTING_OPENAI_API_KEY" ]]; then
    echo ""
    echo "OpenAI API Key (optional). This key will be used for:"
    echo "   - Supabase: AI services to help with writing SQL queries, statements, and policies"
    echo "   - Crawl4AI: Default LLM configuration for web crawling capabilities"
    echo "   You can skip this by leaving it empty."
    echo ""
    read -p "OpenAI API Key: " OPENAI_API_KEY
    if [[ -n "$OPENAI_API_KEY" ]]; then
        write_env_var "OPENAI_API_KEY" "$OPENAI_API_KEY"
    fi
else
    # Reuse existing value without prompting
    OPENAI_API_KEY="$EXISTING_OPENAI_API_KEY"
fi


# ----------------------------------------------------------------
# Logic for n8n workflow import (RUN_N8N_IMPORT)
# ----------------------------------------------------------------
final_run_n8n_import_decision="false"

echo ""
echo "Do you want to import 300 ready-made workflows for n8n? This process may take about 30 minutes to complete."
echo ""
read -p "Import workflows? (y/n): " import_workflow_choice

if [[ "$import_workflow_choice" =~ ^[Yy]$ ]]; then
    final_run_n8n_import_decision="true"
else
    final_run_n8n_import_decision="false"
fi

# Persist RUN_N8N_IMPORT to .env
write_env_var "RUN_N8N_IMPORT" "$final_run_n8n_import_decision"


# ----------------------------------------------------------------
# Prompt for number of n8n workers
# ----------------------------------------------------------------
echo "" # Add a newline for better formatting
log_info "Configuring n8n worker count..."
EXISTING_N8N_WORKER_COUNT="$(read_env_var N8N_WORKER_COUNT)"
if [[ -n "$EXISTING_N8N_WORKER_COUNT" ]]; then
    N8N_WORKER_COUNT_CURRENT="$EXISTING_N8N_WORKER_COUNT"
    echo ""
    read -p "Do you want to change the number of n8n workers? Current: $N8N_WORKER_COUNT_CURRENT. (Enter new number, or press Enter to keep current): " N8N_WORKER_COUNT_INPUT_RAW
    if [[ -z "$N8N_WORKER_COUNT_INPUT_RAW" ]]; then
        N8N_WORKER_COUNT="$N8N_WORKER_COUNT_CURRENT"
    else
        if [[ "$N8N_WORKER_COUNT_INPUT_RAW" =~ ^0*[1-9][0-9]*$ ]]; then
            N8N_WORKER_COUNT_TEMP="$((10#$N8N_WORKER_COUNT_INPUT_RAW))"
            if [[ "$N8N_WORKER_COUNT_TEMP" -ge 1 ]]; then
                 echo ""
                 read -p "Update n8n workers to $N8N_WORKER_COUNT_TEMP? (y/N): " confirm_change
                 if [[ "$confirm_change" =~ ^[Yy]$ ]]; then
                    N8N_WORKER_COUNT="$N8N_WORKER_COUNT_TEMP"
                 else
                    N8N_WORKER_COUNT="$N8N_WORKER_COUNT_CURRENT"
                    log_info "Change declined. Keeping N8N_WORKER_COUNT at $N8N_WORKER_COUNT."
                 fi
            else
                log_warning "Invalid input '$N8N_WORKER_COUNT_INPUT_RAW'. Number must be positive. Keeping $N8N_WORKER_COUNT_CURRENT."
                N8N_WORKER_COUNT="$N8N_WORKER_COUNT_CURRENT"
            fi
        else
            log_warning "Invalid input '$N8N_WORKER_COUNT_INPUT_RAW'. Please enter a positive integer. Keeping $N8N_WORKER_COUNT_CURRENT."
            N8N_WORKER_COUNT="$N8N_WORKER_COUNT_CURRENT"
        fi
    fi
else
    while true; do
        echo ""
        read -p "Enter the number of n8n workers to run (e.g., 1, 2, 3; default is 1): " N8N_WORKER_COUNT_INPUT_RAW
        N8N_WORKER_COUNT_CANDIDATE="${N8N_WORKER_COUNT_INPUT_RAW:-1}"

        if [[ "$N8N_WORKER_COUNT_CANDIDATE" =~ ^0*[1-9][0-9]*$ ]]; then
            N8N_WORKER_COUNT_VALIDATED="$((10#$N8N_WORKER_COUNT_CANDIDATE))"
            if [[ "$N8N_WORKER_COUNT_VALIDATED" -ge 1 ]]; then
                echo ""
                read -p "Run $N8N_WORKER_COUNT_VALIDATED n8n worker(s)? (y/N): " confirm_workers
                if [[ "$confirm_workers" =~ ^[Yy]$ ]]; then
                    N8N_WORKER_COUNT="$N8N_WORKER_COUNT_VALIDATED"
                    break
                else
                    log_info "Please try entering the number of workers again."
                fi
            else
                log_error "Number of workers must be a positive integer." >&2
            fi
        else
            log_error "Invalid input '$N8N_WORKER_COUNT_CANDIDATE'. Please enter a positive integer (e.g., 1, 2)." >&2
        fi
    done
fi
# Ensure N8N_WORKER_COUNT is definitely set (should be by logic above)
N8N_WORKER_COUNT="${N8N_WORKER_COUNT:-1}"

# Persist N8N_WORKER_COUNT to .env
write_env_var "N8N_WORKER_COUNT" "$N8N_WORKER_COUNT"

# Resource Allocation Section
echo
log_info "====== Hardware Resource Allocation (Optional) ======"
echo
echo "Would you like to (re)configure resource limits for containers?"
echo "This helps prevent services from consuming all system resources."
echo "We will (re)calculate weighted values based on your VPS size and your"
echo "selected containers, ensuring that 15% is reserved for the host system"
read -p "Configure resource limits? (y/N): " configure_resources

if [[ "$configure_resources" =~ ^[Yy]$ ]]; then
    # Get hardware specs
    read -p "How many CPU cores does your system have? (e.g., 4): " TOTAL_CORES
    read -p "How much RAM (in GB) does your system have? (e.g., 16): " TOTAL_RAM_GB
    
    # Validate inputs
    if ! [[ "$TOTAL_CORES" =~ ^[0-9]+$ ]] || ! [[ "$TOTAL_RAM_GB" =~ ^[0-9]+$ ]]; then
        log_error "Invalid input. Skipping resource configuration."
    else
        # Calculate available resources (leaving 15% for host)
        AVAILABLE_CORES=$(echo "$TOTAL_CORES * 0.85" | bc -l | xargs printf "%.1f")
        AVAILABLE_RAM_GB=$(echo "$TOTAL_RAM_GB * 0.85" | bc -l | xargs printf "%.0f")
        
        log_info "Allocating $AVAILABLE_CORES cores and ${AVAILABLE_RAM_GB}GB RAM to containers..."
        
        # Generate resource allocation script
        python3 scripts/generate_resource_limits.py \
            --cores "$AVAILABLE_CORES" \
            --ram "$AVAILABLE_RAM_GB" \
            --profiles "$COMPOSE_PROFILES" \
            --output docker-compose.override.yml
        
        if [ $? -eq 0 ]; then
            log_success "Resource limits configured in docker-compose.override.yml"
        else
            log_warning "Failed to generate resource limits. Continuing without them."
        fi
    fi
fi

# ----------------------------------------------------------------
# Cloudflare Tunnel Token (if cloudflare-tunnel profile is active)
# ----------------------------------------------------------------
# If Cloudflare Tunnel is selected (based on COMPOSE_PROFILES), prompt for the token and write to .env
COMPOSE_PROFILES_VALUE="$(read_env_var COMPOSE_PROFILES)"
cloudflare_selected=0
if [[ "$COMPOSE_PROFILES_VALUE" == *"cloudflare-tunnel"* ]]; then
    cloudflare_selected=1
fi

if [ $cloudflare_selected -eq 1 ]; then
    existing_cf_token=""
    if grep -q "^CLOUDFLARE_TUNNEL_TOKEN=" "$ENV_FILE"; then
        existing_cf_token=$(grep "^CLOUDFLARE_TUNNEL_TOKEN=" "$ENV_FILE" | cut -d'=' -f2- | sed 's/^\"//' | sed 's/\"$//')
    fi

    if [ -n "$existing_cf_token" ]; then
        log_info "Cloudflare Tunnel token found in .env; reusing it."
        # Do not prompt; keep existing token as-is
    else
        log_info "Cloudflare Tunnel selected. Please provide your Cloudflare Tunnel token."
        echo ""
        read -p "Cloudflare Tunnel Token: " input_cf_token
        token_to_write="$input_cf_token"

        # Update the .env with the token (may be empty if user skipped)
        if grep -q "^CLOUDFLARE_TUNNEL_TOKEN=" "$ENV_FILE"; then
            sed -i.bak "/^CLOUDFLARE_TUNNEL_TOKEN=/d" "$ENV_FILE"
        fi
        echo "CLOUDFLARE_TUNNEL_TOKEN=\"$token_to_write\"" >> "$ENV_FILE"

        if [ -n "$token_to_write" ]; then
            log_success "Cloudflare Tunnel token saved to .env."
            echo ""
            echo "🔒 After confirming the tunnel works, consider closing ports 80, 443, and 7687 in your firewall."
        else
            log_warning "Cloudflare Tunnel token was left empty. You can set it later in .env."
        fi
    fi
fi


# ----------------------------------------------------------------
# Ensure Supabase Analytics targets the correct Postgres service name used by Supabase docker compose
# ----------------------------------------------------------------
write_env_var "POSTGRES_HOST" "db"
# ----------------------------------------------------------------

log_success "Service configuration complete. .env updated at $ENV_FILE"

exit 0