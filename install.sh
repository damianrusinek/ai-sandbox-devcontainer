#!/bin/bash
set -euo pipefail

# Claude Code Devcontainer CLI Helper
# Provides the `devc` command for managing devcontainers

# Resolve symlinks to get actual script location
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
# Use real script filename (invocation may be via symlink, e.g. ./devc -> install.sh)
SCRIPT_NAME="$(basename "$SOURCE")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_usage() {
  cat <<EOF
Usage: devc <command> [options]

Commands:
    .                   Install devcontainer template to current directory and start
    up                  Start the devcontainer in current directory
    rebuild             Rebuild the devcontainer (preserves auth volumes)
    down                Stop the devcontainer
    shell               Open a shell in the running container
    self-install        Install 'devc' command to ~/.local/bin
    update              Update devc to the latest version
    upgrade-agents      Upgrade Claude Code and Codex CLI to latest
    mount <host> <cont> Add a mount to the devcontainer (recreates container)
    build-image         Build Docker image from template repo (my-ai-sandbox/devcontainer:local)
    help                Show this help message

Options:
    --custom            Use custom Dockerfile build instead of prebuilt image
                        (applies to: ., up, rebuild)

Examples:
    devc .                      # Install template and start container
    devc . --custom             # Install template with custom Dockerfile build (you will need to update the Dockerfile in the workspace)
    devc up                     # Start container in current directory
    devc rebuild                # Clean rebuild
    devc shell                  # Open interactive shell
    devc self-install           # Install devc to PATH
    devc update                 # Update to latest version
    devc upgrade-agents         # Upgrade Claude Code and Codex CLI
    devc mount ~/data /data     # Add mount to container
    devc build-image            # Build local devcontainer image
EOF
}

log_info() {
  echo -e "${BLUE}[devc]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[devc]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[devc]${NC} $1"
}

log_error() {
  echo -e "${RED}[devc]${NC} $1" >&2
}

check_devcontainer_cli() {
  if ! command -v devcontainer &>/dev/null; then
    log_error "devcontainer CLI not found."
    log_info "Install it with: npm install -g @devcontainers/cli"
    exit 1
  fi
}

get_workspace_folder() {
  echo "${1:-$(pwd)}"
}

# Extract custom mounts from devcontainer.json to a temp file
# Returns the temp file path, or empty string if no custom mounts
extract_mounts_to_file() {
  local devcontainer_json="$1"
  local temp_file

  [[ -f "$devcontainer_json" ]] || return 0

  temp_file=$(mktemp)

  # Filter out default mounts (template mounts we don't want to preserve)
  local custom_mounts
  custom_mounts=$(jq -c '
    .mounts // [] | map(
      select(
        (startswith("source=ai-sandbox-") | not) and
        (startswith("source=${localEnv:HOME}/.gitconfig,") | not)
      )
    ) | if length > 0 then . else empty end
  ' "$devcontainer_json" 2>/dev/null) || true

  if [[ -n "$custom_mounts" ]]; then
    echo "$custom_mounts" >"$temp_file"
    echo "$temp_file"
  fi
}

# Merge preserved mounts back into devcontainer.json
merge_mounts_from_file() {
  local devcontainer_json="$1"
  local mounts_file="$2"

  [[ -f "$mounts_file" ]] || return 0
  [[ -s "$mounts_file" ]] || return 0

  local custom_mounts
  custom_mounts=$(cat "$mounts_file")

  local updated
  updated=$(jq --argjson custom "$custom_mounts" '
    .mounts = ((.mounts // []) + $custom | unique)
  ' "$devcontainer_json")

  echo "$updated" >"$devcontainer_json"
}

# Convert devcontainer.json from image-based to build-based configuration
convert_to_build_config() {
  local devcontainer_json="$1"

  local updated
  updated=$(jq 'del(.image) | .build = {
    "dockerfile": "Dockerfile",
    "args": {
      "TZ": "${localEnv:TZ:UTC}",
      "GIT_DELTA_VERSION": "0.18.2",
      "ZSH_IN_DOCKER_VERSION": "1.2.1"
    }
  }' "$devcontainer_json")

  echo "$updated" >"$devcontainer_json"
}

# Add or update a mount in devcontainer.json
update_devcontainer_mounts() {
  local devcontainer_json="$1"
  local host_path="$2"
  local container_path="$3"
  local readonly="${4:-false}"

  local mount_str="source=${host_path},target=${container_path},type=bind"
  [[ "$readonly" == "true" ]] && mount_str="${mount_str},readonly"

  local updated
  updated=$(jq --arg target "$container_path" --arg mount "$mount_str" '
    .mounts = (
      ((.mounts // []) | map(select(contains("target=" + $target + ",") or endswith("target=" + $target) | not)))
      + [$mount]
    )
  ' "$devcontainer_json")

  echo "$updated" >"$devcontainer_json"
}

cmd_template() {
  local target_dir="${1:-.}"
  local use_custom="${2:-false}"

  target_dir="$(cd "$target_dir" 2>/dev/null && pwd)" || {
    log_error "Directory does not exist: $1"
    exit 1
  }

  # Check if base image exists when using custom Dockerfile mode
  if [[ "$use_custom" == "true" ]]; then
    if ! docker image inspect my-ai-sandbox/devcontainer:local &>/dev/null; then
      log_warn "Base image 'my-ai-sandbox/devcontainer:local' not found."
      read -p "Build it now? [y/N] " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        cmd_build_image
      else
        log_error "Cannot use --custom without the base image."
        log_info "Build it first with: devc build-image"
        exit 1
      fi
    fi
  fi

  local devcontainer_dir="$target_dir/.devcontainer"
  local devcontainer_json="$devcontainer_dir/devcontainer.json"
  local preserved_mounts=""

  if [[ -d "$devcontainer_dir" ]]; then
    log_warn "Devcontainer already exists at $devcontainer_dir"
    read -p "Overwrite? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      exit 0
    fi

    # Preserve custom mounts before overwriting
    preserved_mounts=$(extract_mounts_to_file "$devcontainer_json")
    if [[ -n "$preserved_mounts" ]]; then
      log_info "Preserving custom mounts..."
    fi
  fi

  mkdir -p "$devcontainer_dir"

  # Copy template files
  cp "$SCRIPT_DIR/devcontainer.json" "$devcontainer_dir/"
  cp "$SCRIPT_DIR/post_install.py" "$devcontainer_dir/"
  cp "$SCRIPT_DIR/.zshrc" "$devcontainer_dir/"

  # Handle custom Dockerfile build mode
  if [[ "$use_custom" == "true" ]]; then
    cp "$SCRIPT_DIR/Dockerfile-custom" "$devcontainer_dir/Dockerfile"
    convert_to_build_config "$devcontainer_json"
    log_info "Using custom Dockerfile build mode"
  fi

  # Restore preserved mounts
  if [[ -n "$preserved_mounts" ]]; then
    merge_mounts_from_file "$devcontainer_json" "$preserved_mounts"
    rm -f "$preserved_mounts"
    log_info "Custom mounts restored"
  fi

  log_success "Template installed to $devcontainer_dir"
}

cmd_up() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  check_devcontainer_cli
  log_info "Starting devcontainer in $workspace_folder..."

  devcontainer up --workspace-folder "$workspace_folder"
  log_success "Devcontainer started"
}

cmd_rebuild() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  check_devcontainer_cli
  log_info "Rebuilding devcontainer in $workspace_folder..."

  devcontainer up --workspace-folder "$workspace_folder" --remove-existing-container
  log_success "Devcontainer rebuilt"
}

cmd_build_image() {
  local dockerfile="$SCRIPT_DIR/Dockerfile-base"

  if [[ ! -f "$dockerfile" ]]; then
    log_error "Dockerfile not found: $dockerfile"
    exit 1
  fi

  log_info "Building my-ai-sandbox/devcontainer:local (Dockerfile & context: $SCRIPT_DIR)..."
  docker buildx build -f "$dockerfile" -t my-ai-sandbox/devcontainer:local "$SCRIPT_DIR"
  log_success "Image built: my-ai-sandbox/devcontainer:local"
}

cmd_down() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  check_devcontainer_cli
  log_info "Stopping devcontainer..."

  # Get container ID and stop it
  local container_id
  container_id=$(docker ps -q --filter "label=devcontainer.local_folder=$workspace_folder" 2>/dev/null || true)

  if [[ -n "$container_id" ]]; then
    docker stop "$container_id"
    log_success "Devcontainer stopped"
  else
    log_warn "No running devcontainer found for $workspace_folder"
  fi
}

cmd_shell() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  check_devcontainer_cli
  log_info "Opening shell in devcontainer..."

  devcontainer exec --workspace-folder "$workspace_folder" zsh
}

cmd_upgrade_agents() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  check_devcontainer_cli
  log_info "Upgrading Claude Code and Codex CLI..."

  devcontainer exec --workspace-folder "$workspace_folder" zsh -lc 'claude update && npm install -g @openai/codex@latest'

  log_success "Claude Code and Codex CLI upgraded"
}

cmd_mount() {
  local host_path="${1:-}"
  local container_path="${2:-}"
  local readonly="false"

  if [[ -z "$host_path" ]] || [[ -z "$container_path" ]]; then
    log_error "Usage: devc mount <host_path> <container_path> [--readonly]"
    exit 1
  fi

  [[ "${3:-}" == "--readonly" ]] && readonly="true"

  # Expand and validate host path
  host_path="$(cd "$host_path" 2>/dev/null && pwd)" || {
    log_error "Host path does not exist: $1"
    exit 1
  }

  local workspace_folder
  workspace_folder="$(get_workspace_folder)"
  local devcontainer_json="$workspace_folder/.devcontainer/devcontainer.json"

  if [[ ! -f "$devcontainer_json" ]]; then
    log_error "No devcontainer.json found. Run 'devc .' first."
    exit 1
  fi

  check_devcontainer_cli

  log_info "Adding mount: $host_path → $container_path"
  update_devcontainer_mounts "$devcontainer_json" "$host_path" "$container_path" "$readonly"

  log_info "Recreating container with new mount..."
  devcontainer up --workspace-folder "$workspace_folder" --remove-existing-container

  log_success "Mount added: $host_path → $container_path"
}

cmd_self_install() {
  local install_dir="$HOME/.local/bin"
  local install_path="$install_dir/devc"

  mkdir -p "$install_dir"

  ln -sf "$SCRIPT_DIR/$SCRIPT_NAME" "$install_path"

  log_success "Installed 'devc' to $install_path"

  # Check if in PATH
  if [[ ":$PATH:" != *":$install_dir:"* ]]; then
    log_warn "$install_dir is not in your PATH"
    log_info "Add this to your shell profile:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
}

cmd_update() {
  log_info "Updating devc..."

  if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
    log_error "Not a git repository: $SCRIPT_DIR"
    log_info "Re-clone with: rm -rf ~/.ai-sandbox-devcontainer && git clone https://github.com/damianrusinek/ai-sandbox-devcontainer ~/.ai-sandbox-devcontainer"
    exit 1
  fi

  local before_sha after_sha
  before_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

  if ! git -C "$SCRIPT_DIR" pull --ff-only; then
    log_error "Update failed. Try: cd $SCRIPT_DIR && git pull"
    exit 1
  fi

  after_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

  if [[ "$before_sha" == "$after_sha" ]]; then
    log_success "Already up to date"
  else
    log_success "Updated from ${before_sha:0:7} to ${after_sha:0:7}"
  fi
}

cmd_dot() {
  local use_custom="${1:-false}"
  # Install template and start container in one command
  cmd_template "." "$use_custom"
  cmd_up "."
}

# Parse --custom flag from arguments
# Returns "true" if --custom is present, "false" otherwise
# Also removes --custom from the argument list via a global variable
parse_custom_flag() {
  USE_CUSTOM="false"
  REMAINING_ARGS=()
  for arg in "$@"; do
    if [[ "$arg" == "--custom" ]]; then
      USE_CUSTOM="true"
    else
      REMAINING_ARGS+=("$arg")
    fi
  done
}

# Main command dispatcher
main() {
  if [[ $# -eq 0 ]]; then
    print_usage
    exit 1
  fi

  local command="$1"
  shift

  # Parse --custom flag for commands that support it
  parse_custom_flag "$@"

  case "$command" in
  .)
    cmd_dot "$USE_CUSTOM"
    ;;
  up)
    cmd_up "${REMAINING_ARGS[@]:-}"
    ;;
  rebuild)
    cmd_rebuild "${REMAINING_ARGS[@]:-}"
    ;;
  build-image)
    cmd_build_image
    ;;
  down)
    cmd_down "${REMAINING_ARGS[@]:-}"
    ;;
  shell)
    cmd_shell
    ;;
  upgrade-agents)
    cmd_upgrade_agents
    ;;
  mount)
    cmd_mount "${REMAINING_ARGS[@]:-}"
    ;;
  self-install)
    cmd_self_install
    ;;
  update)
    cmd_update
    ;;
  help | --help | -h)
    print_usage
    ;;
  *)
    log_error "Unknown command: $command"
    print_usage
    exit 1
    ;;
  esac
}

main "$@"
