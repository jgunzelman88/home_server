
#!/bin/bash
kubectl create namespace n8n

helm upgrade --install n8n ./n8n \
  --namespace n8n \
  --set n8n.encryptionKey="$(openssl rand -hex 32)"