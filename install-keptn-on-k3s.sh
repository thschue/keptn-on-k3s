#!/usr/bin/env bash

BINDIR="/usr/local/bin"
KEPTNVERSION="master"
KEPTN_API_TOKEN="$(head -c 16 /dev/urandom | base64)"
MY_IP=${1-}
K3SKUBECTLCMD="${BINDIR}/k3s"
K3SKUBECTLOPT="kubectl"
PREFIX="http"

function get_ip {
  if [[ -z "${MY_IP}" ]]; then
    if hostname -I > /dev/null 2>&1; then
      MY_IP="$(hostname -I | awk '{print $1}')"
    else
      echo "Could not determine ip, please specify manually"
      exit 1
    fi
  fi

  case "${MY_IP}" in
    gcp)
      MY_IP="$(curl -Ls -H "Metadata-Flavor: Google" http://metadata/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)"
      ;;
  esac

  if [[ ${MY_IP} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Detected IP: ${MY_IP}"
  else
    echo "${MY_IP} is not a valid ip address"
    exit 1
  fi
}

function apply_manifest {
  if [[ ! -z $1 ]]; then
    "${K3SKUBECTLCMD}" "${K3SKUBECTLOPT}" apply -f "${1}"
    if [[ $? != 0 ]]; then
      echo "Error applying manifest $1"
      exit 1
    fi
  fi
}

function get_k3s {
  curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable INSTALL_K3S_SYMLINK="skip" K3S_KUBECONFIG_MODE="644" sh -
}

function check_k8s {
  started=false
  while [[ ! "${started}" ]]; do
    sleep 5
    if "${K3SKUBECTLCMD}" "${K3SKUBECTLOPT}" get nodes; then
      started=true
    fi
  done
}

function generate_certificate {
  openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "/C=US/O=keptn/CN=*.{MY_IP}.xip.io" -keyout /tmp/certificate.key -out /tmp/certificate.crt
  "${K3SKUBECTLCMD}" "${K3SKUBECTLOPT}" create secret tls keptn-tls -n keptn --cert /tmp/certificate.crt --key /tmp/certificate.key
  rm /tmp/certificate.crt /tmp/certificate.key
}

function install_keptn {
  use_cert=false
  # Keptn Quality Gate installation based on https://keptn.sh/docs/develop/operate/manifest_installation/
  apply_manifest "https://raw.githubusercontent.com/keptn/keptn/${KEPTNVERSION}/installer/manifests/keptn/namespace.yaml"
  apply_manifest "https://raw.githubusercontent.com/keptn/keptn/${KEPTNVERSION}/installer/manifests/installer/rbac.yaml"
  apply_manifest "https://raw.githubusercontent.com/keptn/keptn/${KEPTNVERSION}/installer/manifests/nats/nats-operator-prereqs.yaml"
  apply_manifest "https://raw.githubusercontent.com/keptn/keptn/${KEPTNVERSION}/installer/manifests/nats/nats-operator-deploy.yaml"
  sleep 20
  "${K3SKUBECTLCMD}" "${K3SKUBECTLOPT}" wait --namespace=keptn -l name=nats-operator  --for=condition=Ready pods --timeout=300s --all

  "${K3SKUBECTLCMD}" "${K3SKUBECTLOPT}" create role get-keptn-domain --verb=get --resource=configmap --resource-name=keptn-domain -n keptn
  "${K3SKUBECTLCMD}" "${K3SKUBECTLOPT}" create rolebinding --serviceaccount=keptn:default --role=get-keptn-domain -n keptn keptn-get-domain
  "${K3SKUBECTLCMD}" "${K3SKUBECTLOPT}" create role keptn-create-lighthouse-config --verb=create,update --resource=configmap -n keptn
  "${K3SKUBECTLCMD}" "${K3SKUBECTLOPT}" create rolebinding --serviceaccount=keptn:default --role=keptn-create-lighthouse-config -n keptn keptn-create-lighthouse-config

  apply_manifest "https://raw.githubusercontent.com/keptn/keptn/${KEPTNVERSION}/installer/manifests/nats/nats-cluster.yaml"
  apply_manifest "https://raw.githubusercontent.com/keptn/keptn/${KEPTNVERSION}/installer/manifests/logging/namespace.yaml"
  apply_manifest "https://raw.githubusercontent.com/keptn/keptn/${KEPTNVERSION}/installer/manifests/logging/mongodb/pvc.yaml"
  apply_manifest "https://raw.githubusercontent.com/keptn/keptn/${KEPTNVERSION}/installer/manifests/logging/mongodb/deployment.yaml"
  apply_manifest "https://raw.githubusercontent.com/keptn/keptn/${KEPTNVERSION}/installer/manifests/logging/mongodb/svc.yaml"
  apply_manifest "https://raw.githubusercontent.com/thschue/keptn-on-k3s/master/mongodb-datastore.yaml"
  apply_manifest "https://raw.githubusercontent.com/keptn/keptn/${KEPTNVERSION}/installer/manifests/logging/mongodb-datastore/mongodb-datastore-distributor.yaml"
  "${K3SKUBECTLCMD}" "${K3SKUBECTLOPT}" wait --namespace=keptn-datastore --for=condition=Ready pods --timeout=300s --all

  "${K3SKUBECTLCMD}" "${K3SKUBECTLOPT}" create secret generic -n keptn keptn-api-token --from-literal=keptn-api-token="$KEPTN_API_TOKEN"

  apply_manifest "https://raw.githubusercontent.com/thschue/keptn-on-k3s/master/keptn-core.yaml"
  apply_manifest "https://raw.githubusercontent.com/keptn/keptn/${KEPTNVERSION}/installer/manifests/keptn/keptn-domain-configmap.yaml"
  apply_manifest "https://raw.githubusercontent.com/keptn/keptn/${KEPTNVERSION}/installer/manifests/keptn/api-gateway-nginx.yaml"
  apply_manifest "https://raw.githubusercontent.com/keptn/keptn/${KEPTNVERSION}/installer/manifests/keptn/quality-gates.yaml"

  cat << EOF | "${K3SKUBECTLCMD}" "${K3SKUBECTLOPT}" apply -n keptn -f -
apiVersion: v1
data:
  app_domain: ${MY_IP}.xip.io
kind: ConfigMap
metadata:
  creationTimestamp: null
  name: keptn-domain
  namespace: keptn
EOF

  if openssl version > /dev/null 2>&1; then
    PREFIX="https"
    generate_certificate
  fi

  if  [[ ${PREFIX} == "https" ]]; then
    cat << EOF |  "${K3SKUBECTLCMD}" "${K3SKUBECTLOPT}" apply -n keptn -f -
apiVersion: networking.k8s.io/v1beta1
kind: Ingress
metadata:
  name: keptn-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  tls:
  - secretName: keptn-tls
  rules:
    - host: api.keptn.${MY_IP}.xip.io
      http:
        paths:
          - path: /
            backend:
              serviceName: api-gateway-nginx
              servicePort: 80
    - host: api.keptn
      http:
        paths:
          - path: /
            backend:
              serviceName: api-gateway-nginx
              servicePort: 80
    - host: bridge.keptn.${MY_IP}.xip.io
      http:
        paths:
          - path: /
            backend:
              serviceName: bridge
              servicePort: 8080
EOF
  else
  cat << EOF |  "${K3SKUBECTLCMD}" "${K3SKUBECTLOPT}" apply -n keptn -f -
apiVersion: networking.k8s.io/v1beta1
kind: Ingress
metadata:
  name: keptn-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
    - host: api.keptn.${MY_IP}.xip.io
      http:
        paths:
          - path: /
            backend:
              serviceName: api-gateway-nginx
              servicePort: 80
    - host: api.keptn
      http:
        paths:
          - path: /
            backend:
              serviceName: api-gateway-nginx
              servicePort: 80
    - host: bridge.keptn.${MY_IP}.xip.io
      http:
        paths:
          - path: /
            backend:
              serviceName: bridge
              servicePort: 8080
EOF

  "${K3SKUBECTLCMD}" "${K3SKUBECTLOPT}" wait --namespace=keptn --for=condition=Ready pods --timeout=300s --all
  fi
}

function print_config {
  echo "API URL   :   ${PREFIX}://api.keptn.$MY_IP.xip.io"
  echo "Bridge URL:   ${PREFIX}://bridge.keptn.$MY_IP.xip.io"
  echo "API Token :   $KEPTN_API_TOKEN"

  cat << EOF
To use keptn:
- Install the keptn CLI: curl -sL https://get.keptn.sh | sudo -E bash
- Authenticate: keptn auth  --api-token "${KEPTN_API_TOKEN}" --endpoint "${PREFIX}://api.keptn.$MY_IP.xip.io"
- API-Secret: kubectl create secret generic keptn-api --from-literal=API_TOKEN="${KEPTN_API_TOKEN}" --from-literal=API_URL="${PREFIX}://api.keptn.$MY_IP.xip.io"
EOF
}

function main {
  get_ip
  get_k3s
  check_k8s
  install_keptn
  print_config
}

main "${@}"
