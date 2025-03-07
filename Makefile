RUN_NAMESPACE = metal3
GO_TEST_FLAGS = $(TEST_FLAGS)
DEBUG = --debug
COVER_PROFILE = cover.out

# CRD Generation Options
#
# allowDangerousTypes=true lets use the float64 field for clock speeds
# crdVersions=v1 generates the v1 version of the CRD type
#
# NOTE: Assumes the default is preserveUnknownFields=false with
#       crdVersions=v1, so that the API server discards "extra" data
#       instead of storing it
#
#
BIN_DIR := bin

CRD_OPTIONS ?= "crd:allowDangerousTypes=true,crdVersions=v1"
KUSTOMIZE = tools/bin/kustomize
CONTROLLER_GEN = tools/bin/controller-gen

# See pkg/version.go for details
SOURCE_GIT_COMMIT ?= $(shell git rev-parse --short HEAD)
BUILD_VERSION ?= $(shell git describe --always --abbrev=40 --dirty)
VERSION_URI = "github.com/metal3-io/baremetal-operator/pkg/version"
export LDFLAGS="-X $(VERSION_URI).Raw=${BUILD_VERSION} \
                -X $(VERSION_URI).Commit=${SOURCE_GIT_COMMIT} \
                -X $(VERSION_URI).BuildTime=$(shell date +%Y-%m-%dT%H:%M:%S%z)"

# Set some variables the operator expects to have in order to work
# Those need to be the same as in config/default/ironic.env
export OPERATOR_NAME=baremetal-operator
export DEPLOY_KERNEL_URL=http://172.22.0.1:6180/images/ironic-python-agent.kernel
export DEPLOY_RAMDISK_URL=http://172.22.0.1:6180/images/ironic-python-agent.initramfs
export IRONIC_ENDPOINT=http://localhost:6385/v1/
export IRONIC_INSPECTOR_ENDPOINT=http://localhost:5050/v1/
export GO111MODULE=on
export GOFLAGS=

.PHONY: help
help:  ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
	@echo
	@echo "Variables:"
	@echo "  TEST_NAMESPACE   -- project name to use ($(TEST_NAMESPACE))"
	@echo "  SETUP            -- controls the --no-setup flag ($(SETUP))"
	@echo "  GO_TEST_FLAGS    -- flags to pass to --go-test-flags ($(GO_TEST_FLAGS))"
	@echo "  DEBUG            -- debug flag, if any ($(DEBUG))"

# Image URL to use all building/pushing image targets
IMG_NAME ?= baremetal-operator
IMG_TAG ?= latest
IMG ?= $(IMG_NAME):$(IMG_TAG)

## --------------------------------------
## Test Targets
## --------------------------------------

# Run tests
.PHONY: test
test: generate lint manifests unit ## Run common developer tests

.PHONY: unit
unit: ## Run unit tests
	go test ./... $(GO_TEST_FLAGS) -coverprofile $(COVER_PROFILE)
	cd apis/ && go test ./... $(GO_TEST_FLAGS) -coverprofile $(COVER_PROFILE)
	cd pkg/hardwareutils && go test ./... $(GO_TEST_FLAGS) -coverprofile $(COVER_PROFILE)

.PHONY: unit-cover
unit-cover: ## Run unit tests with code coverage
	go test -coverprofile=$(COVER_PROFILE) $(GO_TEST_FLAGS) ./...
	go tool cover -func=$(COVER_PROFILE)
	cd apis/ && go test -coverprofile=$(COVER_PROFILE) $(GO_TEST_FLAGS) ./...
	cd apis/ && go tool cover -func=$(COVER_PROFILE)
	cd pkg/hardwareutils/ && go test -coverprofile=$(COVER_PROFILE) $(GO_TEST_FLAGS) ./...
	cd pkg/hardwareutils/ && go tool cover -func=$(COVER_PROFILE)

.PHONY: unit-verbose
unit-verbose: ## Run unit tests with verbose output
	TEST_FLAGS=-v make unit

## --------------------------------------
## Linter Targets
## --------------------------------------

.PHONY: linters
linters: lint generate-check fmt-check

tools/bin/golangci-lint: hack/tools/go.mod
	cd hack/tools; go build -o $(abspath $@) github.com/golangci/golangci-lint/cmd/golangci-lint

.PHONY: lint
lint: tools/bin/golangci-lint
	$< run

.PHONY: manifest-lint
manifest-lint: ## Run manifest validation
	./hack/manifestlint.sh

## --------------------------------------
## Build/Run Targets
## --------------------------------------

.PHONY: build
build: generate manifests manager tools ## Build everything

.PHONY: manager
manager: generate lint ## Build manager binary
	go build -ldflags $(LDFLAGS) -o bin/$(OPERATOR_NAME) main.go

.PHONY: run
run: generate lint manifests ## Run against the configured Kubernetes cluster in ~/.kube/config
	go run -ldflags $(LDFLAGS) ./main.go -namespace=$(RUN_NAMESPACE) -dev -webhook-port=0 $(RUN_FLAGS)

.PHONY: demo
demo: generate lint manifests ## Run in demo mode
	go run -ldflags $(LDFLAGS) ./main.go -namespace=$(RUN_NAMESPACE) -dev -demo-mode -webhook-port=0 $(RUN_FLAGS)

.PHONY: run-test-mode
run-test-mode: generate fmt-check lint manifests ## Run against the configured Kubernetes cluster in ~/.kube/config
	go run -ldflags $(LDFLAGS) ./main.go -namespace=$(RUN_NAMESPACE) -dev -test-mode -webhook-port=0 $(RUN_FLAGS)

.PHONY: install
install: $(KUSTOMIZE) manifests ## Install CRDs into a cluster
	$< build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: $(KUSTOMIZE) manifests ## Uninstall CRDs from a cluster
	$< build config/crd | kubectl delete -f -

.PHONY: deploy
deploy: $(KUSTOMIZE) manifests  ## Deploy controller in the configured Kubernetes cluster in ~/.kube/config
	make set-manifest-image-bmo MANIFEST_IMG=$(IMG_NAME) MANIFEST_TAG=$(IMG_TAG)
	$< build config/default | kubectl apply -f -

$(CONTROLLER_GEN): hack/tools/go.mod
	cd hack/tools; go build -o $(abspath $@) sigs.k8s.io/controller-tools/cmd/controller-gen

$(KUSTOMIZE): hack/tools/go.mod
	cd hack/tools; go build -o $(abspath $@) sigs.k8s.io/kustomize/kustomize/v4

.PHONY: manifests
manifests: manifests-generate manifests-kustomize ## Generate manifests e.g. CRD, RBAC etc.

.PHONY: manifests-generate
manifests-generate: $(CONTROLLER_GEN)
	cd apis; $(abspath $<) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:webhook:dir=../config/webhook/ output:crd:artifacts:config=../config/crd/bases
	$< rbac:roleName=manager-role paths="./..." output:rbac:artifacts:config=config/rbac

.PHONY: manifests-kustomize
manifests-kustomize: $(KUSTOMIZE)
	$< build config/default > config/render/capm3.yaml

.PHONY: set-manifest-image-bmo
set-manifest-image-bmo: $(KUSTOMIZE) manifests
	$(info Updating container image for BMO to use ${MANIFEST_IMG}:${MANIFEST_TAG})
	cd config/default && $(abspath $(KUSTOMIZE)) edit set image quay.io/metal3-io/baremetal-operator=${MANIFEST_IMG}:${MANIFEST_TAG}

.PHONY: set-manifest-image-ironic
set-manifest-image-ironic: $(KUSTOMIZE) manifests
	$(info Updating container image for Ironic to use ${MANIFEST_IMG}:${MANIFEST_TAG})
	cd ironic-deployment/base && $(abspath $(KUSTOMIZE)) edit set image quay.io/metal3-io/ironic=${MANIFEST_IMG}:${MANIFEST_TAG}

.PHONY: set-manifest-image-mariadb
set-manifest-image-mariadb: $(KUSTOMIZE) manifests
	$(info Updating container image for Mariadb to use ${MANIFEST_IMG}:${MANIFEST_TAG})
	cd ironic-deployment/components/mariadb && $(abspath $(KUSTOMIZE)) edit set image quay.io/metal3-io/mariadb=${MANIFEST_IMG}:${MANIFEST_TAG}

.PHONY: set-manifest-image-keepalived
set-manifest-image-keepalived: $(KUSTOMIZE) manifests
	$(info Updating container image for keepalived to use ${MANIFEST_IMG}:${MANIFEST_TAG})
	cd ironic-deployment/components/keepalived && $(abspath $(KUSTOMIZE)) edit set image quay.io/metal3-io/keepalived=${MANIFEST_IMG}:${MANIFEST_TAG}

.PHONY: set-manifest-image-ipa-downloader
set-manifest-image-ipa-downloader: $(KUSTOMIZE) manifests
	$(info Updating container image for IPA downloader to use ${MANIFEST_IMG}:${MANIFEST_TAG})
	cd ironic-deployment/base && $(abspath $(KUSTOMIZE)) edit set image quay.io/metal3-io/ironic-ipa-downloader=${MANIFEST_IMG}:${MANIFEST_TAG}

.PHONY: generate
generate: $(CONTROLLER_GEN) ## Generate code
	cd apis; $(abspath $<) object:headerFile="../hack/boilerplate.go.txt" paths="./..."
	$< object:headerFile="hack/boilerplate.go.txt" paths="./..."

## --------------------------------------
## Docker Targets
## --------------------------------------

.PHONY: docker
docker: generate manifests ## Build the docker image
	docker build . -t ${IMG} --build-arg http_proxy=$(http_proxy) --build-arg https_proxy=$(https_proxy)

# Push the docker image
.PHONY: docker-push
docker-push:
	docker push ${IMG}

## --------------------------------------
## CI Targets
## --------------------------------------

.PHONY: generate-check
generate-check:
	./hack/generate.sh

.PHONY: generate-check-local
generate-check-local:
	IS_CONTAINER=local ./hack/generate.sh

.PHONY: fmt-check
fmt-check: ## Run gofmt and report an error if any changes are made
	./hack/gofmt.sh

.PHONY: fmt
fmt: ## Run gofmt and fix files with formatting issues
	gofmt -s -w .

## --------------------------------------
## Documentation
## --------------------------------------

.PHONY: docs
docs: $(patsubst %.dot,%.png,$(wildcard docs/*.dot))

%.png: %.dot
	dot -Tpng $< >$@

## --------------------------------------
## Tool apps
## --------------------------------------

.PHONY: tools
tools:
	go build -o bin/get-hardware-details cmd/get-hardware-details/main.go
	go build -o bin/make-bm-worker cmd/make-bm-worker/main.go
	go build -o bin/make-virt-host cmd/make-virt-host/main.go

## --------------------------------------
## Tilt / Kind
## --------------------------------------

.PHONY: kind-create
kind-create: ## create bmo kind cluster if needed
	./hack/kind_with_registry.sh

.PHONY: tilt-up
tilt-up: $(KUSTOMIZE) kind-create ## start tilt and build kind cluster if needed
	tilt up

.PHONY: kind-reset
kind-reset: ## Destroys the "bmo" kind cluster.
	kind delete cluster --name=bmo || true

## --------------------------------------
## Go module Targets
## --------------------------------------

.PHONY:
mod: ## Clean up go module settings
	go mod tidy
	go mod verify
	cd apis; go mod tidy
	cd apis; go mod verify
	cd pkg/hardwareutils; go mod tidy
	cd pkg/hardwareutils; go mod verify
	cd hack/tools; go mod tidy
	cd hack/tools; go mod verify

## --------------------------------------
## Release
## --------------------------------------
RELEASE_TAG ?= $(shell git describe --abbrev=0 2>/dev/null)
PREVIOUS_TAG ?= $(shell git tag -l | grep -B 1 $(RELEASE_TAG) | head -n 1)
RELEASE_NOTES_DIR := releasenotes

$(RELEASE_NOTES_DIR):
	mkdir -p $(RELEASE_NOTES_DIR)/

.PHONY: release-notes
release-notes: $(RELEASE_NOTES_DIR)
	go run ./hack/tools/release_notes.go --from=$(PREVIOUS_TAG) > $(RELEASE_NOTES_DIR)/releasenotes.md

## --------------------------------------
## Clean
## --------------------------------------

.PHONY: clean
clean: ## Remove all temporary files and folders
	rm -rf ironic-deployment/overlays/temp
