#!/usr/bin/env bash
# Usage: ./deploy.sh <network> <Script> [extra forge args]
#   ./deploy.sh arc-testnet DeployLendingVault
#   ./deploy.sh arc DeploySunToken --verify
#
# Loads .env.<network> and runs script/<Script>.s.sol against its RPC_URL.
# Without --broadcast forge only simulates; pass it explicitly to send transactions.
set -euo pipefail

network="${1:?usage: ./deploy.sh <network> <Script> [forge args]}"
name="${2:?usage: ./deploy.sh <network> <Script> [forge args]}"
shift 2

cd "$(dirname "$0")"

env_file=".env.${network}"
[[ -f "$env_file" ]] || { echo "missing $env_file (copy from ${env_file}.example)" >&2; exit 1; }

set -a
source "$env_file"
set +a

forge script "script/${name}.s.sol:${name}" --rpc-url "$RPC_URL" "$@"
