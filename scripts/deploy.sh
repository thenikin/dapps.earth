#!/bin/bash -e

[ ! -z "$BASE_DOMAIN" ]

if [ ! -z "$DEBUG_KEY_NAME" ]; then
  # If it is local deployment, then just do ssh, forward docker socket
  # and run docker-compose
  ssh -M -S ctrl-socket -fnNT -o "ExitOnForwardFailure yes" \
    -i ~/.ssh/$DEBUG_KEY_NAME.pem \
    -L $(pwd)/docker.sock:/var/run/docker.sock ec2-user@$BASE_DOMAIN
  chmod 600 docker.sock
  chmod 600 ctrl-socket
  (
    trap "echo cleaning up tunnel; ssh -S ctrl-socket -O exit ec2-user@$BASE_DOMAIN; rm -f docker.sock ctrl-socket" EXIT
    export DOCKER_HOST=unix://$(pwd)/docker.sock

    docker-compose up -d --build --remove-orphans
    docker-compose logs -t
  )
else
  # When deployment is from travis, connect to all destinations with the keys
  # we have, and attempt to do deploy
  [ ! -z "$TRAVIS" ]
  [ ! -z "$ENV" ]
  KEYS=$(cd keys && echo *.key | sort)
  for KEY in $KEYS; do
    echo "Attempting to use key $KEY to deploy on $BASE_DOMAIN..."
    if \
      ssh -i ./keys/$KEY.key travis@$BASE_DOMAIN $(git rev-parse HEAD) $ENV; \
    then
      echo "Succeeded deploying with key $KEY"
    else
      echo "Failed deploying with key $KEY"
      break
    fi
  done
fi