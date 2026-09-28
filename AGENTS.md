## Home server IAC

This repo is a infrastructure as code repo for my home server. It is a single node k3s instance with traefik ingress controller and keycloak IdAM

Rules for building:
 1. Any new deployements will always deploy to whatever endpoint is prompted at the bwing tldm. for example keycloaks ui is deployed at https://bwing/keycloak
 2. Secrets are always stored in k8s secret manager never in the repo or the values file. if an init script needs to be created to ensure secrets are availble before deployment this is key
 3. Default passwords for components must be disabled. Unless it is required for initialization.
 4. If a component supports OIDC then register as a client under the master relm. If its a paid feature then do not enable it.