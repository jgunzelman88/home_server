# Pre-requisites
   * Install k8s
   * Install k9s
   
# Install

   1. Run init-keycloak.sh
   1. Run init-headlamp.sh (Kubernetes dashboard, logs into Keycloak for SSO)
   1. Run init-tls.sh (optional but recommended - stable cert for "bwing"
      instead of Traefik's ad-hoc default, so SSO logins don't break on a
      Traefik restart)
