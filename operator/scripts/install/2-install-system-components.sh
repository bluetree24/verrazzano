#!/usr/bin/env bash
#
# Copyright (c) 2020, Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.
#
SCRIPT_DIR=$(cd $(dirname "$0"); pwd -P)
. $SCRIPT_DIR/common.sh
. $SCRIPT_DIR/config.sh

TMP_DIR=$(mktemp -d)
trap 'rc=$?; rm -rf ${TMP_DIR} || true; _logging_exit_handler $rc' EXIT

set -eu

function install_nginx_ingress_controller()
{
    # Create the namespace for nginx
    if ! kubectl get namespace ingress-nginx ; then
        kubectl create namespace ingress-nginx
    fi

    helm repo add stable https://charts.helm.sh/stable || return $?
    helm repo update || return $?

    local ingress_type=$(get_config_value ".ingress.type")

    # Handle any additional NGINX install args - since NGINX is for Verrazzano system Ingress,
    # these should be in .ingress.verrazzano.nginxInstallArgs[]
    local EXTRA_NGINX_ARGUMENTS=$(get_nginx_helm_args_from_config)

    if [ "$DNS_TYPE" == "oci" ]; then
      EXTRA_NGINX_ARGUMENTS="$EXTRA_NGINX_ARGUMENTS --set controller.service.annotations.'external-dns\.alpha\.kubernetes\.io/ttl'=60"
      local dns_zone=$(get_config_value ".dns.oci.dnsZoneName")
      EXTRA_NGINX_ARGUMENTS="$EXTRA_NGINX_ARGUMENTS --set controller.service.annotations.'external-dns\.alpha\.kubernetes\.io/hostname'=verrazzano-ingress.${NAME}.${dns_zone}"
    fi

    helm upgrade ingress-controller stable/nginx-ingress --install \
      --set controller.image.repository=$NGINX_INGRESS_CONTROLLER_IMAGE \
      --set controller.image.tag=$NGINX_INGRESS_CONTROLLER_TAG \
      --set controller.config.client-body-buffer-size=64k \
      --set defaultBackend.image.repository=$NGINX_DEFAULT_BACKEND_IMAGE \
      --set defaultBackend.image.tag=$NGINX_DEFAULT_BACKEND_TAG \
      --namespace ingress-nginx \
      --set controller.metrics.enabled=true \
      --set controller.podAnnotations.'prometheus\.io/port'=10254 \
      --set controller.podAnnotations.'prometheus\.io/scrape'=true \
      --set controller.podAnnotations.'system\.io/scrape'=true \
      --version $NGINX_INGRESS_CONTROLLER_VERSION \
      --set controller.service.type="${ingress_type}" \
      --set controller.publishService.enabled=true \
      --set controller.service.enableHttp=false \
      ${EXTRA_NGINX_ARGUMENTS} \
      --timeout 15m0s \
      --wait \
      || return $?

    # Handle any ports specified for Verrazzano Ingress - these must be patched after install
    local nginx_svc_patch_spec=$(get_verrazzano_ports_spec)
    if [ ! -z "${nginx_svc_patch_spec}" ]; then
      log "Patching NGINX service with: ${nginx_svc_patch_spec}"
      kubectl patch service -n ingress-nginx ingress-controller-nginx-ingress-controller -p "${nginx_svc_patch_spec}"
    fi
}

function setup_cert_manager_crd() {
  curl -L -o "$TMP_DIR/00-crds.yaml" \
    "https://raw.githubusercontent.com/jetstack/cert-manager/release-${CERT_MANAGER_RELEASE}/deploy/manifests/00-crds.yaml"
  if [ "$DNS_TYPE" == "oci" ]; then
    command -v patch >/dev/null 2>&1 || {
      fail "patch is required but cannot be found on the path. Aborting.";
    }
    patch "$TMP_DIR/00-crds.yaml" "$SCRIPT_DIR/config/00-crds.patch"
  fi
}

function setup_cluster_issuer() {
  if [ "$CERT_ISSUER_TYPE" == "acme" ]; then
    local OCI_DNS_CONFIG_SECRET=$(get_config_value ".dns.oci.ociConfigSecret")
    local EMAIL_ADDRESS=$(get_config_value ".certificates.acme.emailAddress")
    local OCI_DNS_ZONE_OCID=$(get_config_value ".dns.oci.dnsZoneOcid")
    local OCI_DNS_ZONE_NAME=$(get_config_value ".dns.oci.dnsZoneName")

    if ! kubectl get secret $OCI_DNS_CONFIG_SECRET ; then
        fail "The OCI Configuration Secret $OCI_DNS_CONFIG_SECRET does not exist"
    fi

    kubectl apply -f <(echo "
apiVersion: cert-manager.io/v1alpha2
kind: ClusterIssuer
metadata:
  name: verrazzano-cluster-issuer
spec:
  acme:
    email: $EMAIL_ADDRESS
    server: "https://acme-v02.api.letsencrypt.org/directory"
    privateKeySecretRef:
      name: verrazzano-cert-acme-secret
    solvers:
      - dns01:
          ocidns:
            useInstancePrincipals: false
            serviceAccountSecretRef:
              name: $OCI_DNS_CONFIG_SECRET
              key: "oci.yaml"
            ocizonename: $DNS_SUFFIX
")
  elif [ "$CERT_ISSUER_TYPE" == "ca" ]; then
    kubectl apply -f <(echo "
apiVersion: cert-manager.io/v1alpha2
kind: ClusterIssuer
metadata:
  name: verrazzano-cluster-issuer
spec:
  ca:
    secretName: $(get_config_value ".certificates.ca.secretName")
")
  else
    fail "certificates issuerType $CERT_ISSUER_TYPE is not supported.";
  fi
}

function install_cert_manager()
{
    # Create the namespace for cert-manager
    if ! kubectl get namespace cert-manager ; then
        kubectl create namespace cert-manager
    fi

    helm repo add jetstack https://charts.jetstack.io || return $?
    helm repo update || return $?

    setup_cert_manager_crd
    kubectl apply -f "$TMP_DIR/00-crds.yaml" --validate=false

    local EXTRA_CERT_MANAGER_ARGUMENTS=""
    if [ "$CERT_ISSUER_TYPE" == "ca" ]; then
      EXTRA_CERT_MANAGER_ARGUMENTS="--set clusterResourceNamespace=$(get_config_value ".certificates.ca.clusterResourceNamespace")"
    fi

    helm upgrade cert-manager jetstack/cert-manager \
        --install \
        --namespace cert-manager \
        --version $CERT_MANAGER_HELM_CHART_VERSION \
        --set image.repository=$CERT_MANAGER_IMAGE \
        --set image.tag=$CERT_MANAGER_TAG \
        --set extraArgs[0]=--acme-http01-solver-image=$CERT_MANAGER_SOLVER_IMAGE:$CERT_MANAGER_SOLVER_TAG \
        --set cainjector.enabled=false \
        --set webhook.enabled=false \
        --set webhook.injectAPIServerCA=false \
        --set ingressShim.defaultIssuerName=verrazzano-cluster-issuer \
        --set ingressShim.defaultIssuerKind=ClusterIssuer \
        ${EXTRA_CERT_MANAGER_ARGUMENTS} \
        --wait \
        || return $?

    setup_cluster_issuer

    kubectl -n cert-manager rollout status -w deploy/cert-manager
}

function install_external_dns()
{
  if [ "$DNS_TYPE" == "oci" ]; then
    if ! kubectl get secret $OCI_DNS_CONFIG_SECRET -n cert-manager ; then
      # secret does not exist, so copy the configured oci config secret from default namespace.
      # Operator has already checked for existence of secret in default namespace
      # The DNS zone compartment will get appended to secret generated for cert external dns
      local dns_compartment=$(get_config_value ".dns.oci.dnsZoneCompartmentOcid")
      kubectl get secret ${OCI_DNS_CONFIG_SECRET} -o go-template='{{range $k,$v := .data}}{{if not $v}}{{$v}}{{else}}{{$v | base64decode}}{{end}}{{"\n"}}{{end}}' \
          | sed '/^$/d' > $TMP_DIR/oci.yaml
      echo "compartment: $dns_compartment" >> $TMP_DIR/oci.yaml
      kubectl create secret generic $OCI_DNS_CONFIG_SECRET --from-file=$TMP_DIR/oci.yaml -n cert-manager
    fi

    helm upgrade external-dns stable/external-dns \
        --install \
        --namespace cert-manager \
        --version $EXTERNAL_DNS_VERSION \
        --set image.registry=$EXTERNAL_DNS_REGISTRY \
        --set image.repository=$EXTERNAL_DNS_REPO \
        --set image.tag=$EXTERNAL_DNS_TAG \
        --set provider=oci \
        --set logLevel=debug \
        --set registry=txt \
        --set sources[0]=ingress \
        --set sources[1]=service \
        --set domainFilters[0]=${DNS_SUFFIX} \
        --set zoneIdFilters[0]=$(get_config_value ".dns.oci.dnsZoneOcid") \
        --set txtOwnerId=v8o-local-${NAME} \
        --set txtPrefix=_v8o-local-${NAME}_ \
        --set policy=sync \
        --set interval=24h \
        --set triggerLoopOnEvent=true \
        --set extraVolumes[0].name=config \
        --set extraVolumes[0].secret.secretName=$OCI_DNS_CONFIG_SECRET \
        --set extraVolumeMounts[0].name=config \
        --set extraVolumeMounts[0].mountPath=/etc/kubernetes/ \
        --wait \
        || return $?
  fi
}

function install_rancher()
{
    log "Create Rancher namespace (if required)"
    if ! kubectl get namespace cattle-system > /dev/null 2>&1; then
        kubectl create namespace cattle-system
    fi

    log "Add Rancher helm repository location"
    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable || return $?

    log "Update helm repositoriess"
    helm repo update || return $?

    local INGRESS_TLS_SOURCE=""
    local EXTRA_RANCHER_ARGUMENTS=""
    local RANCHER_PATCH_DATA=""
    if [ "$CERT_ISSUER_TYPE" == "acme" ]; then
      INGRESS_TLS_SOURCE="letsEncrypt"
      EXTRA_RANCHER_ARGUMENTS="--set letsEncrypt.ingress.class=rancher --set letsEncrypt.email=$(get_config_value ".certificates.acme.emailAddress") --set letsEncrypt.environment=$(get_acme_environment)"
      RANCHER_PATCH_DATA="{\"metadata\":{\"annotations\":{\"kubernetes.io/tls-acme\":\"true\",\"nginx.ingress.kubernetes.io/auth-realm\":\"${DNS_SUFFIX} auth\",\"external-dns.alpha.kubernetes.io/target\":\"verrazzano-ingress.${NAME}.${DNS_SUFFIX}\",\"cert-manager.io/issuer\":null,\"external-dns.alpha.kubernetes.io/ttl\":\"60\"}}}"
    elif [ "$CERT_ISSUER_TYPE" == "ca" ]; then
      INGRESS_TLS_SOURCE="rancher"
      RANCHER_PATCH_DATA="{\"metadata\":{\"annotations\":{\"kubernetes.io/tls-acme\":\"true\",\"nginx.ingress.kubernetes.io/auth-realm\":\"${NAME}.${DNS_SUFFIX} auth\",\"cert-manager.io/issuer\":\"rancher\",\"cert-manager.io/issuer-kind\":\"Issuer\"}}}"
    else
      fail "certificates issuerType $CERT_ISSUER_TYPE is not supported.";
    fi

    log "Install Rancher"
    # Do not add --wait since helm install will not fully work in OLCNE until MKNOD is added in the next command
    helm upgrade rancher rancher-stable/rancher \
      --install --namespace cattle-system \
      --version $RANCHER_VERSION  \
      --set systemDefaultRegistry=ghcr.io/verrazzano \
      --set rancherImage=$RANCHER_IMAGE \
      --set rancherImageTag=$RANCHER_TAG \
      --set hostname=rancher.${NAME}.${DNS_SUFFIX} \
      --set ingress.tls.source=${INGRESS_TLS_SOURCE} \
      ${EXTRA_RANCHER_ARGUMENTS}

    # CRI-O does not deliver MKNOD by default, until https://github.com/rancher/rancher/pull/27582 is merged we must add the capability
    # OLCNE uses CRI-O and needs this change, and it doesn't hurt other cases
    kubectl patch deployments -n cattle-system rancher -p '{"spec":{"template":{"spec":{"containers":[{"name":"rancher","securityContext":{"capabilities":{"add":["MKNOD"]}}}]}}}}'

    log "Patch Rancher ingress"
    kubectl patch ingress rancher -n cattle-system -p "$RANCHER_PATCH_DATA" --type=merge

    log "Rollout Rancher"
    kubectl -n cattle-system rollout status -w deploy/rancher || return $?

    log "Create Rancher secrets"
    RANCHER_DATA=$(kubectl --kubeconfig $KUBECONFIG -n cattle-system exec $(kubectl --kubeconfig $KUBECONFIG -n cattle-system get pods -l app=rancher | grep '1/1' | head -1 | awk '{ print $1 }') -- reset-password 2>/dev/null)
    ADMIN_PW=`echo $RANCHER_DATA | awk '{ print $NF }'`

    if [ -z "$ADMIN_PW" ] ; then
      error "ERROR: Failed to reset Rancher password"
      return 1
    fi

    kubectl -n cattle-system create secret generic rancher-admin-secret --from-literal=password="$ADMIN_PW"
}

OCI_DNS_CONFIG_SECRET=$(get_config_value ".dns.oci.ociConfigSecret")
NAME=$(get_config_value ".environmentName")
DNS_TYPE=$(get_config_value ".dns.type")
CERT_ISSUER_TYPE=$(get_config_value ".certificates.issuerType")

action "Installing Nginx Ingress Controller" install_nginx_ingress_controller || exit 1

# We can only know the ingress IP after installing nginx ingress controller
INGRESS_IP=$(get_verrazzano_ingress_ip)

# DNS_SUFFIX is only used by install_rancher
DNS_SUFFIX=$(get_dns_suffix ${INGRESS_IP})

action "Installing cert manager" install_cert_manager || exit 1
action "Installing external DNS" install_external_dns || exit 1
action "Installing Rancher" install_rancher || exit 1
