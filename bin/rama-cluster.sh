#!/usr/bin/env bash
set -euo pipefail

usage () {
  echo "Usage: rama-cluster.sh <deploy|destroy|plan> <cluster-name> [optional terraform apply args]"
  exit 2
}

[[ $# -ge 2 ]] || usage

DIR=$(realpath "$(dirname "$0")")
CWD=$(pwd)

OP_NAME=$1
CLUSTER_NAME=$2
WORKSPACE_NAME=${CLUSTER_NAME}

ROOT_DIR="$(realpath "${DIR}/..")"
TF_ROOT_DIR="${ROOT_DIR}"/rama-cluster
HOME_CLUSTER_DIR="${HOME}/.rama/${CLUSTER_NAME}"

if [[ $CLUSTER_NAME == "default" ]]; then
    echo "Cluster name may not be \"default\""
    exit 2
fi

echo "Performing ${OP_NAME} ${CLUSTER_NAME}"

find_rama_tfvars_rec () {
  if test -f "./rama.tfvars"; then
    realpath "./rama.tfvars"
  else
    if [ "$(pwd)" = "/" ]; then
      echo "[ERROR] Could not find rama.tfvars file" >&2
      exit 1
    else
      pushd ..
      find_rama_tfvars_rec
      popd
    fi
  fi
}

find_rama_tfvars () {
  cd "$CWD"
  tfvars="$(find_rama_tfvars_rec)"
  echo "$tfvars"
}

get_tfvars_value () {
  # get line
  line=$(grep $2 $1)
  # get the value, then trim leading/trailing whitespace
  echo "${line#*=}" | xargs
}

run_destroy () {
  cd ${TF_ROOT_DIR}
  tfvars="$(find_rama_tfvars)"
  terraform workspace select "${WORKSPACE_NAME}"
  terraform destroy -auto-approve \
    -parallelism=50 \
    -var-file "$tfvars" \
    -var-file ~/.rama/auth.tfvars \
    -var="cluster_name=$CLUSTER_NAME"
  terraform workspace select default
  terraform workspace delete "${WORKSPACE_NAME}"

  rm -f ~/.rama/rama-"${CLUSTER_NAME}"
  rm -rf ~/.rama/"${CLUSTER_NAME}"
  echo "Rama cluster destroyed."
  # ensure zero exit code
  return 0
}

# allow passing in of extra args to `terraform apply`
all_args=("$@")
rest_args=("${all_args[@]:2}")
rest_args_set=${rest_args:-}
if [ ! -z ${rest_args_set} ]; then
  tf_apply_args="${rest_args[@]}"
else
  tf_apply_args=""
fi

run_deploy () {

  cd ${TF_ROOT_DIR}
  tfvars="$(find_rama_tfvars)"
  terraform workspace select "${WORKSPACE_NAME}" &> /dev/null || terraform workspace new "${WORKSPACE_NAME}"
  terraform init
  terraform apply \
    -auto-approve \
    -parallelism=30 \
    -var-file "$tfvars" \
    -var-file ~/.rama/auth.tfvars \
    -var="cluster_name=${CLUSTER_NAME}" \
    $tf_apply_args

  # "Install" rama and your cluster config in your home directory so that you
  # can deploy modules with `rama-$CLUSTER_NAME deploy $MODULE_NAME`
  rm -rf ${HOME_CLUSTER_DIR}
  mkdir -p ${HOME_CLUSTER_DIR}

  # Save the outputs to the cluster directory
  terraform output -json > ${HOME_CLUSTER_DIR}/outputs.json

  rama_source_path="$(get_tfvars_value $tfvars rama_source_path)"
  (
      cp ${rama_source_path} ${HOME_CLUSTER_DIR}
      cp ${tfvars} ${HOME_CLUSTER_DIR}
  )
  (
      cd ${HOME_CLUSTER_DIR}
      unzip rama.zip &> /dev/null
      rm rama.yaml
      rm rama.zip
  )

  ## Copy the deployment's rama.yaml because it has entries for the conductor
  cp /tmp/deployment.yaml ~/.rama/${CLUSTER_NAME}/rama.yaml
  ln -fs ~/.rama/${CLUSTER_NAME}/rama ~/.rama/rama-${CLUSTER_NAME}
  echo "Rama cluster deployed, have fun."
  # ensure zero exit code
  return 0
}

run_plan () {
  cd ${TF_ROOT_DIR}
  tfvars="$(find_rama_tfvars)"
  terraform workspace select "${WORKSPACE_NAME}" &> /dev/null || terraform workspace new "${WORKSPACE_NAME}"
  terraform init
  terraform plan \
    -var-file "$tfvars" \
    -var-file ~/.rama/auth.tfvars \
    -var="cluster_name=${CLUSTER_NAME}" \
    $tf_apply_args
}

case "${OP_NAME}" in
  deploy)
    run_deploy
    ;;
  destroy)
    run_destroy
    ;;
  plan)
    run_plan
    ;;
  *)
    usage
    ;;
esac
