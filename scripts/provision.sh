#!/bin/bash -e

# Launch a new instance on AWS, attach existing or new elastic IP to it

set -o pipefail

[ ! -z "$SECURITY_GROUP" ]
[ ! -z "$DEPLOY_ENV" ]
[ ! -z "$AWS_PROFILE" ]

export DEPLOY_BRANCH=$(. $DEPLOY_ENV && echo $BRANCH)

[ ! -z "$DEPLOY_BRANCH" ]

AMI_AMAZON_LINUX=ami-0130c3a072f3832ff
USER_DATA="$(mktemp)"

instance_id=$(
  trap "rm -f $USER_DATA" EXIT

  # Mind that source will be injected inside double quotes
  BASE64_SOURCE="echo '$(gzip -c9 ./scripts/initialize-instance.sh | base64 -w0)' | base64 -d | gunzip"
  GITHUB_SOURCE="curl --silent --fail 'https://raw.githubusercontent.com/burdakovd/dapps.earth/$(git rev-parse HEAD)/scripts/initialize-instance.sh'"

  if cmp -s <(bash -o pipefail -c "$BASE64_SOURCE") <(bash -o pipefail -c "$GITHUB_SOURCE"); then
    SOURCE="$GITHUB_SOURCE"
    echo "Using init script from Github, as there are no local changes" >&2
  else
    SOURCE="$BASE64_SOURCE"
    echo "Using local init script." >&2
    echo "This should not be used for prod deployments" >&2
    if [ -z "$DEBUG_KEY_NAME" ]; then
      echo "Are you using prod deployment with modified init script?" >&2
      echo "Please do not, as this makes it harder to verify integrity of prod" >&2
      echo "If this is for development, then define DEBUG_KEY_NAME variable" >&2
      false
    fi
  fi

  (
    echo '#!/bin/bash -xe'
    echo "export INIT_SCRIPT_SOURCE=\"$SOURCE\""
    echo "bash -o pipefail -c \"\$INIT_SCRIPT_SOURCE\" > /root/dapps.earth-init.sh"
    echo "chmod +x /root/dapps.earth-init.sh"
    echo "mkdir -p /var/log/dapps.earth-integrity"
    echo "date"
    echo "echo ''"
    if [ ! -z "$MAINTAINER_KEY" ]; then
      echo "export MAINTAINER_KEY='$MAINTAINER_KEY'"
      echo "(
        echo \"This machine has monitoring key <\$MAINTAINER_KEY> attached\"
        echo \"Holder of that key has unprivileged access to the machine\"
        echo \"The key allows basic read-only commands, \"
        echo \"such as df -h, free, top -s, etc.\"
        echo ''
      ) >> /var/log/dapps.earth-integrity/provision.txt"
    fi
    echo "export DEPLOY_BRANCH='$DEPLOY_BRANCH'"
    echo "export DEPLOY_ENV='$DEPLOY_ENV'"
    echo "(
      echo \"This machine will accept deployments from Travis for:\"
      echo \"  - branch: $DEPLOY_BRANCH\"
      echo \"  - env: $DEPLOY_ENV\"
      echo ''
    ) >> /var/log/dapps.earth-integrity/provision.txt"
    if [ ! -z "$DEBUG_KEY_NAME" ]; then
      echo "(
        echo \"This machine has debug key <$DEBUG_KEY_NAME> attached\"
        echo \"Holder of that key has ROOT access to the machine\"
      ) >> /var/log/dapps.earth-integrity/provision.txt"
      echo "export HAS_DEBUG_KEY=1"
    else
      echo "(
        echo \"This machine has no debug key attached\"
        echo \"Access is restricted to only for Travis deploys\"
      ) >> /var/log/dapps.earth-integrity/provision.txt"
      echo "export HAS_DEBUG_KEY=0"
    fi
    echo "echo '' >> /var/log/dapps.earth-integrity/provision.txt"
    echo "(
      echo \"Source of init script:\"
      echo \"  \$INIT_SCRIPT_SOURCE\"
    ) >> /var/log/dapps.earth-integrity/provision.txt"
    echo "cp /root/dapps.earth-init.sh /var/log/dapps.earth-integrity/init.script.txt"
    echo "time /root/dapps.earth-init.sh > \
      >(tee /var/log/dapps.earth-integrity/init.stdout.txt) \
      2> >(tee /var/log/dapps.earth-integrity/init.stderr.txt >&2) \
    "
    echo "echo \"Exit code of init script: \$?\" \
      >> /var/log/dapps.earth-integrity/provision.txt \
    "
  ) > "$USER_DATA"

  echo "Script source size: ${#SOURCE}" >&2
  echo "Script size: $(bash -o pipefail -c "$SOURCE" | wc -c)" >&2
  echo "User data size: $(wc -c < $USER_DATA)" >&2

  instance_id=$(aws ec2 run-instances \
    --image-id $AMI_AMAZON_LINUX \
    --security-group-ids "$SECURITY_GROUP" \
    --count 1 \
    --iam-instance-profile Name="logger" \
    --instance-type c1.medium \
    --query 'Instances[0].InstanceId' \
    --user-data file://$USER_DATA \
    $(if [ ! -z "$DEBUG_KEY_NAME" ]; then \
      echo "--key-name $DEBUG_KEY_NAME"; \
      echo "Provisioning machine with debug access using key pair $DEBUG_KEY_NAME" >&2;
    else \
      true; \
    fi) \
    --output text \
  )

  mkdir aws_metadata/instances/$instance_id
  cp $USER_DATA aws_metadata/instances/$instance_id/provision-user-data.sh

  echo $instance_id
)

[ ! -z "$instance_id" ]

echo "Launched instance $instance_id"

if [ -z "$ELASTIC_IP" ]; then
  export ELASTIC_IP=$(aws ec2 allocate-address --output=json | jq -r ".PublicIp")
  echo "Allocated elastic IP $ELASTIC_IP" >&2
fi

[ ! -z "$ELASTIC_IP" ]

mkdir -p aws_metadata/addresses/$ELASTIC_IP

(
  echo '{'
  ./scripts/aws_query.py $instance_id $ELASTIC_IP \
    "$(aws configure get aws_access_key_id --profile "$AWS_PROFILE")" \
    "$(aws configure get aws_secret_access_key --profile "$AWS_PROFILE")" | \
    sed "s/'/\"/g"
  echo '"description": "links to query the state of this instance"'
  echo '}'
) | jq . | tee >(cat >&2) | \
  tee >(jq 'del(.DA)' > aws_metadata/instances/$instance_id/urls.json) | \
  jq '{DA}' > aws_metadata/addresses/$ELASTIC_IP/urls.json

echo "Waiting for $instance_id to start..."

aws ec2 wait instance-running --instance-ids $instance_id

echo "Instance $instance_id is up and running"

if [ ! -z "$ELASTIC_IP" ]; then
  echo "Assigning $ELASTIC_IP to $instance_id"
  aws ec2 associate-address \
    --instance-id "$instance_id" \
    --public-ip "$ELASTIC_IP" \
    --allow-reassociation
  ssh-keygen -R "$ELASTIC_IP"
  . $DEPLOY_ENV && ssh-keygen -R "$BASE_DOMAIN"
fi

ip=$(aws ec2 describe-instances \
  --instance-ids "$instance_id" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
)

echo "IP address of the instance is $ip"

echo success
