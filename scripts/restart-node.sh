#!/usr/bin/env bash

set -e

node_idx=$1
DEVENV_PATH="${2:-devnet-env}"

if [ ! $node_idx ]; then
  echo "Pass an index of the node you want to restart (starts from 1)"
  echo "E.g.: ./scripts/restart-node.sh 1"
fi

node_pid=$(cat "$DEVENV_PATH/logs/node$node_idx/node.pid")

echo "Stopping node$node_idx, pid: $node_pid"

node_cmd=$(ps -ww -o args= $node_pid)
node_cwd=$(lsof -a -p "$node_pid" -d cwd -Fn | sed -n 's/^n//p')

echo $node_cwd
echo $node_cmd

kill -INT $node_pid
while true; do
  stat=$(ps -o stat= -p "$node_pid" 2>/dev/null | tr -d ' ')
  if [ -z "$stat" ] || [[ "$stat" == Z* ]]; then
    break
  fi
  sleep 0.2
done

cd "$node_cwd"
eval "$node_cmd" >> "logs/node$node_idx/stdout.log" 2>> "logs/node$node_idx/stderr.log" &

new_pid=$(echo $!)
echo $new_pid > "logs/node$node_idx/node.pid"

