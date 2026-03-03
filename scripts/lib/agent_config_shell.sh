#!/bin/bash

_AGENT_CONFIG_CLI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_agent_config_cli.py"

agent_get_command() {
  local config_path="$1"
  local role="$2"
  python3 "$_AGENT_CONFIG_CLI" --config "$config_path" --role "$role" --field command
}

agent_get_mode() {
  local config_path="$1"
  local role="$2"
  python3 "$_AGENT_CONFIG_CLI" --config "$config_path" --role "$role" --field mode
}

agent_get_initial_message() {
  local config_path="$1"
  local role="$2"
  local prompt_path="$3"
  local role_label="$4"
  python3 "$_AGENT_CONFIG_CLI" \
    --config "$config_path" \
    --role "$role" \
    --field initial_message \
    --prompt-path "$prompt_path" \
    --role-label "$role_label"
}

agent_get_worker_count() {
  local config_path="$1"
  python3 "$_AGENT_CONFIG_CLI" --config "$config_path" --field worker_count
}

agent_get_cli_binary() {
  local config_path="$1"
  local role="$2"
  python3 "$_AGENT_CONFIG_CLI" --config "$config_path" --role "$role" --field cli_binary
}
