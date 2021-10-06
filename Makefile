VERSION ?= "$(shell grep -v '\#' versions.txt | grep operator | awk -F= '{print $$2}')"
VERSION_DATE ?= $(shell date -u +'%Y-%m-%dT%H:%M:%SZ')
VERSION_PKG ?= "github.com/signalfx/splunk-otel-operator/internal/version"
OTELCOL_VERSION ?= "$(shell grep -v '\#' versions.txt | grep splunk-otel-collector | awk -F= '{print $$2}')"
LD_FLAGS ?= "-X ${VERSION_PKG}.version=${VERSION} -X ${VERSION_PKG}.buildDate=${VERSION_DATE} -X ${VERSION_PKG}.otelCol=${OTELCOL_VERSION}"

# Image URL to use all building/pushing image targets
QUAY_USER ?= signalfx
IMG_PREFIX ?= quay.io/${QUAY_USER}
IMG_REPO ?= splunk-otel-operator
IMG ?= ${IMG_PREFIX}/${IMG_REPO}:$(addprefix v,${VERSION})
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true,preserveUnknownFields=false"

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

OPERATOR_SDK=$(shell which operator-sdk)
KUTTL=$(shell which kubectl-kuttl)

KUBE_VERSION ?= 1.21
KIND_CONFIG ?= kind-$(KUBE_VERSION).yaml

all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases

generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

fmt: ## Run go fmt against code.
	go fmt ./...

vet: ## Run go vet against code.
	go vet ./...

ENVTEST_ASSETS_DIR=$(shell pwd)/testbin
#test: manifests generate fmt vet ## Run tests.
test:
	mkdir -p ${ENVTEST_ASSETS_DIR}
	test -f ${ENVTEST_ASSETS_DIR}/setup-envtest.sh || curl -sSLo ${ENVTEST_ASSETS_DIR}/setup-envtest.sh https://raw.githubusercontent.com/kubernetes-sigs/controller-runtime/v0.8.3/hack/setup-envtest.sh
	source ${ENVTEST_ASSETS_DIR}/setup-envtest.sh; fetch_envtest_tools $(ENVTEST_ASSETS_DIR); setup_envtest_env $(ENVTEST_ASSETS_DIR); go test ./controllers/o11y/... -coverprofile cover.out
#source ${ENVTEST_ASSETS_DIR}/setup-envtest.sh; fetch_envtest_tools $(ENVTEST_ASSETS_DIR); setup_envtest_env $(ENVTEST_ASSETS_DIR); go test ./... -coverprofile cover.out

##@ Build

build: generate fmt vet ## Build manager binary.
	go build -o bin/manager main.go

run: manifests generate fmt vet ## Run a controller from your host.
	go run ./main.go

docker-build: ## Build docker image with the manager.
	docker build -t ${IMG} .

docker-push: ## Push docker image with the manager.
	docker push ${IMG}

##@ Deployment

install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

undeploy: ## Undeploy controller from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/default | kubectl delete -f -


CONTROLLER_GEN = $(shell pwd)/bin/controller-gen
controller-gen: ## Download controller-gen locally if necessary.
	$(call go-get-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@v0.4.1)

KUSTOMIZE = $(shell pwd)/bin/kustomize
kustomize: ## Download kustomize locally if necessary.
	$(call go-get-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v3@v3.8.7)

# go-get-tool will 'go get' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-get-tool
@[ -f $(1) ] || { \
set -e ;\
TMP_DIR=$$(mktemp -d) ;\
cd $$TMP_DIR ;\
go mod init tmp ;\
echo "Downloading $(2)" ;\
GOBIN=$(PROJECT_DIR)/bin go get $(2) ;\
rm -rf $$TMP_DIR ;\
}
endef

# Set the controller image parameters
set-image-controller: manifests kustomize
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}

# Generate bundle manifests and metadata, then validate generated files.
bundle: manifests
	$(OPERATOR_SDK) generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG) 
	$(KUSTOMIZE) build config/manifests | $(OPERATOR_SDK) generate bundle -q --overwrite --manifests --metadata --version $(VERSION)
	$(OPERATOR_SDK) bundle validate ./bundle

# dirty hack for now
.PHONY: bundle-openshift
bundle-openshift: bundle
	rm -rf bundle-openshift
	cp -r bundle bundle-openshift
	cat config/openshift/*.yaml >> bundle-openshift/manifests/splunk-otel-operator-role_rbac.authorization.k8s.io_v1_clusterrole.yaml

# Generates the released manifests
release-artifacts: set-image-controller
	mkdir -p dist
	$(KUSTOMIZE) build config/default -o dist/splunk-otel-operator.yaml
	# dirty hack for now
	cp dist/splunk-otel-operator.yaml dist/splunk-otel-operator-openshift.yaml
	cat config/openshift/*.yaml >> dist/splunk-otel-operator-openshift.yaml

# end-to-tests
e2e:
	$(KUTTL) test
	
#prepare-e2e: set-test-image-vars set-image-controller docker-build start-kind
prepare-e2e: set-test-image-vars set-image-controller start-kind
	mkdir -p tests/_build/crds tests/_build/manifests
	$(KUSTOMIZE) build config/default -o tests/_build/manifests/01-splunk-otel-operator.yaml
	$(KUSTOMIZE) build config/crd -o tests/_build/crds/

set-test-image-vars:
	$(eval IMG=local/splunk-otel-operator:e2e)

start-kind: 
	kind create cluster --config $(KIND_CONFIG)
	kind load docker-image local/splunk-otel-operator:e2e

cert-manager:
	kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.5.2/cert-manager.yaml
	kubectl wait --timeout=5m --for=condition=available deployment cert-manager -n cert-manager
	kubectl wait --timeout=5m --for=condition=available deployment cert-manager-cainjector -n cert-manager
	kubectl wait --timeout=5m --for=condition=available deployment cert-manager-webhook -n cert-manager
