#/etc/sh
export POCKETBASE_VERSION="0.13.4"
docker build --build-arg $POCKETBASE_VERSION -t pocketbase:$POCKETBASE_VERSION -t pocketbase:latest .