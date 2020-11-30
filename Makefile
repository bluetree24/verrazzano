# Copyright (C) 2020, Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.

NAME:=verrazzano-platform-operator
REPO_NAME:=verrazzano-platform-operator


DOCKER_IMAGE_NAME ?= ${NAME}-dev
DOCKER_IMAGE_TAG ?= local-$(shell git rev-parse --short HEAD)

CREATE_LATEST_TAG=0

CRD_OPTIONS ?= "crd:trivialVersions=true"

ifeq ($(MAKECMDGOALS),$(filter $(MAKECMDGOALS),docker-push push-tag))
ifndef DOCKER_REPO
    $(error DOCKER_REPO must be defined as the name of the docker repository where image will be pushed)
endif
ifndef DOCKER_NAMESPACE
    $(error DOCKER_NAMESPACE must be defined as the name of the docker namespace where image will be pushed)
endif
DOCKER_IMAGE_FULLNAME = ${DOCKER_REPO}/${DOCKER_NAMESPACE}/${DOCKER_IMAGE_NAME}
endif

OPERATOR_VERSION = ${DOCKER_IMAGE_TAG}
ifdef RELEASE_VERSION
	OPERATOR_VERSION = ${RELEASE_VERSION}
endif
ifndef RELEASE_BRANCH
	RELEASE_BRANCH=$(shell git rev-parse --abbrev-ref HEAD)
endif

DIST_DIR:=dist
K8S_NAMESPACE:=default
WATCH_NAMESPACE:=
EXTRA_PARAMS=
INTEG_RUN_ID=
ENV_NAME=verrazzano-platform-operator
GO ?= GO111MODULE=on GOPRIVATE=github.com/verrazzano go
CRD_PATH=config/crd/bases

.PHONY: build
build: generate
	go build -o bin/verrazzano-platform-operator main.go

# Run against the configured Kubernetes cluster in ~/.kube/config
.PHONY: run
run:
	$(GO) run main.go --kubeconfig=${KUBECONFIG} --zap-log-level=debug

# Install CRDs into a cluster
.PHONY: install-crds
install-crds: manifests
	kustomize build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
.PHONY: uninstall-crds
uninstall-crds: manifests
	kustomize build config/crd | kubectl delete -f -

.PHONY: check
check: go-fmt go-vet go-ineffassign go-lint

#
# Go build related tasks
#
.PHONY: go-install
go-install: go-mod
	$(GO) install

.PHONY: go-fmt
go-fmt:
	gofmt -s -e -d $(shell find . -name "*.go" | grep -v /vendor/ | grep -v /pkg/assets/) > error.txt
	if [ -s error.txt ]; then\
		cat error.txt;\
		rm error.txt;\
		exit 1;\
	fi
	rm error.txt

.PHONY: go-vet
go-vet:
	$(GO) vet $(shell go list ./... | grep -v github.com/verrazzano/verrazzano/pkg/assets)

.PHONY: go-lint
go-lint:
	$(GO) get -u golang.org/x/lint/golint
	golint -set_exit_status $(shell go list ./... | grep -v github.com/verrazzano/verrazzano/pkg/assets)

.PHONY: go-ineffassign
go-ineffassign:
	$(GO) get -u github.com/gordonklaus/ineffassign
	ineffassign $(shell find . -name "*.go" | grep -v /vendor/ | grep -v /pkg/assets/)

.PHONY: go-mod
go-mod:
	$(GO) mod tidy
	$(GO) mod vendor

# Generate manifests e.g. CRD, RBAC etc.
.PHONY: manifests
manifests: controller-gen
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases
	# Add copyright headers to the kubebuildr generated CRDs
	./hack/add-crd-header.sh

	# Re-generate operator.yaml
	cp config/deploy/verrazzano-platform-operator.yaml deploy/operator.yaml
	cat config/crd/bases/install.verrazzano.io_verrazzanos.yaml >> deploy/operator.yaml

# Generate code
.PHONY: generate
generate: controller-gen
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

# find or download controller-gen
# download controller-gen if necessary
.PHONY: controller-gen
controller-gen:
ifeq (, $(shell which controller-gen))
	@{ \
	set -e ;\
	CONTROLLER_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$CONTROLLER_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go get sigs.k8s.io/controller-tools/cmd/controller-gen@v0.2.5 ;\
	rm -rf $$CONTROLLER_GEN_TMP_DIR ;\
	}
CONTROLLER_GEN=$(GOBIN)/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif

#
# Docker-related tasks
#
.PHONY: docker-clean
docker-clean:
	rm -rf ${DIST_DIR}

.PHONY: docker-build
docker-build: manifests generate go-mod
	docker build --pull \
		-t ${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG} .

.PHONY: docker-push
docker-push: docker-build
	docker tag ${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG} ${DOCKER_IMAGE_FULLNAME}:${DOCKER_IMAGE_TAG}
	docker push ${DOCKER_IMAGE_FULLNAME}:${DOCKER_IMAGE_TAG}

	if [ "${CREATE_LATEST_TAG}" == "1" ]; then \
		docker tag ${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG} ${DOCKER_IMAGE_FULLNAME}:latest; \
		docker push ${DOCKER_IMAGE_FULLNAME}:latest; \
	fi

#
# Test-related tasks
#
.PHONY: unit-test
unit-test: go-install
	$(GO) test -v  ./internal/... ./controllers/...

.PHONY: coverage
coverage: unit-test
	./build/scripts/coverage.sh html

#
# Test-related tasks
#
CLUSTER_NAME = verrazzano
VERRAZZANO_NS = verrazzano-install
BUILD-DEPLOY = build/deploy
DEPLOY = deploy
OPERATOR_SETUP = test/operatorsetup

.PHONY: integ-test
integ-test: create-cluster
	echo 'Load docker image for the verrazzano-platform-operator...'
	kind load docker-image --name ${CLUSTER_NAME} ${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}

	echo 'Deploy verrazzano platform operator ...'
	mkdir -p build/deploy
	cat deploy/operator.yaml | sed -e "s|IMAGE_NAME|${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}|g" > ${BUILD-DEPLOY}/operator.yaml
	kubectl apply -f ${BUILD-DEPLOY}/operator.yaml

	echo 'Run tests...'
	ginkgo -v --keepGoing -cover test/integ/... || IGNORE=FAILURE

.PHONY: create-cluster
create-cluster:
ifdef JENKINS_URL
	./build/scripts/cleanup.sh ${CLUSTER_NAME}
endif
	echo 'Create cluster...'
	HTTP_PROXY="" HTTPS_PROXY="" http_proxy="" https_proxy="" time kind create cluster \
		--name ${CLUSTER_NAME} \
		--wait 5m \
		--config=test/kind-config.yaml
	kubectl config set-context kind-${CLUSTER_NAME}
ifdef JENKINS_URL
	# Get the ip address of the container running the kube apiserver
	# and update the kubeconfig file to point to that address, instead of localhost
	sed -i -e "s|127.0.0.1.*|`docker inspect ${CLUSTER_NAME}-control-plane | jq '.[].NetworkSettings.IPAddress' | sed 's/"//g'`:6443|g" ${HOME}/.kube/config
	cat ${HOME}/.kube/config | grep server
endif

.PHONY: delete-cluster
delete-cluster:
	kind delete cluster --name ${CLUSTER_NAME}

.PHONY: push-tag
push-tag:
	PUBLISH_TAG="${DOCKER_IMAGE_TAG}"; \
	echo "Tagging and pushing image ${DOCKER_IMAGE_FULLNAME}:$$PUBLISH_TAG"; \
	docker pull "${DOCKER_IMAGE_FULLNAME}:${DOCKER_IMAGE_TAG}"; \
	docker tag "${DOCKER_IMAGE_FULLNAME}:${DOCKER_IMAGE_TAG}" "${DOCKER_IMAGE_FULLNAME}:$$PUBLISH_TAG"; \
	docker push "${DOCKER_IMAGE_FULLNAME}:$$PUBLISH_TAG"