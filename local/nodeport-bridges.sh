#!/usr/bin/env bash
# Publish the etraffica NodePort services on the HOST for the kind-based Docker Desktop Kubernetes.
#
# Why this is needed: the new Docker Desktop Kubernetes runs its nodes as "kind" containers
# (desktop-control-plane / desktop-worker). Unlike the classic single-node Docker Desktop, it does
# NOT forward Service NodePorts to the host. These socat containers bridge host:<nodePort> into the
# kind network so the services are reachable at <host-ip>:<nodePort> (published on 0.0.0.0, so the
# LAN IP works too).
#
# Prereq: NodePort services applied -> kubectl apply -f k8/local/nodeports.yaml
# Usage:  bash k8/local/nodeport-bridges.sh           # start/refresh bridges
#         docker rm -f $(docker ps -aq --filter name=etraffica-np-)   # remove bridges
set -euo pipefail

# Control-plane node IP on the 'kind' docker network (NodePort is served on every node).
NODE_IP="$(docker inspect desktop-control-plane \
  --format '{{ (index .NetworkSettings.Networks "kind").IPAddress }}')"
echo "kind control-plane IP: ${NODE_IP}"

# service-name -> nodePort (must match k8/local/nodeports.yaml)
declare -A MAP=(
  [api-gateway]=30300
  [web]=30000
  [admin-web]=30080
  [violator-web]=30081
  [product-website]=30082
)

docker rm -f $(docker ps -aq --filter "name=etraffica-np-") >/dev/null 2>&1 || true

for name in "${!MAP[@]}"; do
  p="${MAP[$name]}"
  docker run -d --restart unless-stopped --name "etraffica-np-${name}" --network kind \
    -p "${p}:${p}" alpine/socat \
    "TCP-LISTEN:${p},fork,reuseaddr" "TCP:${NODE_IP}:${p}" >/dev/null
  echo "bridge up: ${name}  host:${p} -> ${NODE_IP}:${p}"
done

echo "Done. Reachable at <host-ip>:<nodePort> (e.g. http://localhost:30300/api/v1/health/ready)."
