include Makefile.build.mk
CURRENT_USER := $(shell id -u -n)
MINIO_TAG ?= RELEASE.2023-09-23T03-47-50Z
MC_TAG ?= RELEASE.2023-09-22T05-07-46Z
RQLITE_TAG ?= 7.21.4
DEX_TAG ?= v2.37.0
LVP_TAG ?= v0.5.4

define sendMetrics
@if [ -z "${PROJECT_NAME}" ]; then \
    echo "PROJECT_NAME not defined"; \
    exit 1; \
fi
@curl -X POST "https://api.datadoghq.com/api/v1/series" \
-H "Content-Type: text/json" \
-H "DD-API-KEY: ${DD_API_KEY}" \
-d "{\"series\": [{\"metric\": \"build.time\",\"points\": [[$$(date +%s), $$(expr $$(date +%s) - $$(cat start-time))]],\"tags\": [\"service:${PROJECT_NAME}\"]}]}"
endef

.PHONY: capture-start-time
capture-start-time:
	@echo $$(date +%s) > start-time

.PHONY: report-metric
report-metric:
	@$(if ${DD_API_KEY}, $(call sendMetrics))
	@rm start-time

.PHONY: test
test:
	if [ -n "$(RUN)" ]; then \
		go test $(TEST_BUILDFLAGS) ./pkg/... ./cmd/... -coverprofile cover.out -run $(RUN); \
	else \
		go test $(TEST_BUILDFLAGS) ./pkg/... ./cmd/... -coverprofile cover.out; \
	fi

.PHONY: e2e
e2e:
	${MAKE} -C e2e

.PHONY: integration-cli
integration-cli:
	go build ${LDFLAGS} -o bin/kots-integration ./integration

.PHONY: ci-test
ci-test:
	go test $(TEST_BUILDFLAGS) ./pkg/... ./cmd/... ./integration/... -coverprofile cover.out

.PHONY: kots
kots: PROJECT_NAME = kots
kots: capture-start-time kots-real report-metric

.PHONY: kots-real
kots-real:
	go build ${LDFLAGS} -o bin/kots $(BUILDFLAGS) github.com/replicatedhq/kots/cmd/kots

.PHONY: fmt
fmt:
	go fmt ./pkg/... ./cmd/...

.PHONY: vet
vet:
	go vet $(BUILDFLAGS) ./pkg/... ./cmd/...

.PHONY: gosec
gosec:
	go get github.com/securego/gosec/cmd/gosec
	$(GOPATH)/bin/gosec ./...

.PHONY: mock
mock:
	go get github.com/golang/mock/mockgen@v1.6.0
	mockgen -source=pkg/store/store_interface.go -destination=pkg/store/mock/mock.go
	mockgen -source=pkg/handlers/interface.go -destination=pkg/handlers/mock/mock.go
	mockgen -source=pkg/operator/client/client_interface.go -destination=pkg/operator/client/mock/mock.go

.PHONY: build
build: PROJECT_NAME = kotsadm
build: capture-start-time build-real report-metric

.PHONY: build-real
build-real:
	mkdir -p web/dist
	touch web/dist/THIS_IS_OKTETO  # we need this for go:embed, but it's not actually used in dev
	go build ${LDFLAGS} ${GCFLAGS} -v -o bin/kotsadm $(BUILDFLAGS) ./cmd/kotsadm

.PHONY: run
run:
	./bin/kotsadm api

.PHONY: okteto-dev
okteto-dev:
    ## We download all go modules, instead of putting them in the container. This will
    ## use the PVC that everyone has, and will build a cache.
    ##
    ## We also run `make build` here because the initial compilation is slow and
    ## this enabled `okteto up` to do all of the long-running stuff and give the user
    ## a pretty good env right after
	@go mod download -x
	@make build
	@printf "\n\n To build and run api, run: \n\n   # make build run\n\n"

# Debugging
.PHONY: debug-build
debug-build:
	go build ${LDFLAGS} ${GCFLAGS} $(BUILDFLAGS) -v -o ./bin/kotsadm-debug ./cmd/kotsadm

.PHONY: debug
debug: debug-build
	LOG_LEVEL=$(LOG_LEVEL) dlv --listen=:2345 --headless=true --api-version=2 exec ./bin/kotsadm-debug api

.PHONY: build-ttl.sh
build-ttl.sh: build
	source .image.env && ${MAKE} -C web build-kotsadm
	docker build -f deploy/Dockerfile -t ttl.sh/${CURRENT_USER}/kotsadm:24h .
	docker push ttl.sh/${CURRENT_USER}/kotsadm:24h

.PHONY: all-ttl.sh
all-ttl.sh: build-ttl.sh
	source .image.env && IMAGE=ttl.sh/${CURRENT_USER}/kotsadm-migrations:24h make -C migrations build_schema

	docker pull minio/minio:${MINIO_TAG}
	docker tag minio/minio:${MINIO_TAG} ttl.sh/${CURRENT_USER}/minio:${MINIO_TAG}
	docker push ttl.sh/${CURRENT_USER}/minio:${MINIO_TAG}

	docker pull minio/mc:${MC_TAG}
	docker tag minio/mc:${MC_TAG} ttl.sh/${CURRENT_USER}/mc:${MC_TAG}
	docker push ttl.sh/${CURRENT_USER}/mc:${MC_TAG}

	docker pull rqlite/rqlite:${RQLITE_TAG}
	docker tag rqlite/rqlite:${RQLITE_TAG} ttl.sh/${CURRENT_USER}/rqlite:${RQLITE_TAG}
	docker push ttl.sh/${CURRENT_USER}/rqlite:${RQLITE_TAG}

.PHONY: build-alpha
build-alpha:
	docker build --pull -f deploy/Dockerfile --build-arg version=${GIT_TAG} -t kotsadm/kotsadm:alpha .
	docker push kotsadm/kotsadm:alpha

.PHONY: build-release
build-release:
	docker build --pull -f deploy/Dockerfile --build-arg version=${GIT_TAG} -t kotsadm/kotsadm:${GIT_TAG} .
	docker push kotsadm/kotsadm:${GIT_TAG}
	mkdir -p bin/docker-archive/kotsadm
	skopeo copy docker-daemon:kotsadm/kotsadm:${GIT_TAG} docker-archive:bin/docker-archive/kotsadm/${GIT_TAG}

	docker tag kotsadm/kotsadm:${GIT_TAG} kotsadm/kotsadm:v0.0.0-nightly
	docker push kotsadm/kotsadm:v0.0.0-nightly

	docker build --pull -f deploy/dex.Dockerfile -t kotsadm/dex:${DEX_TAG} --build-arg TAG=${DEX_TAG} .
	docker push kotsadm/dex:${DEX_TAG}
	mkdir -p bin/docker-archive/dex
	skopeo copy docker://kotsadm/dex:${DEX_TAG} docker-archive:bin/docker-archive/dex/${DEX_TAG}

	mkdir -p bin/docker-archive/minio
	skopeo copy docker://minio/minio:${MINIO_TAG} docker-archive:bin/docker-archive/minio/${MINIO_TAG}

	mkdir -p bin/docker-archive/mc
	skopeo copy docker://minio/mc:${MC_TAG} docker-archive:bin/docker-archive/mc/${MC_TAG}

	mkdir -p bin/docker-archive/local-volume-provider
	skopeo copy docker://replicated/local-volume-provider:${LVP_TAG} docker-archive:bin/docker-archive/local-volume-provider/${LVP_TAG}

.PHONY: cache
cache:
	docker build -f hack/dev/skaffoldcache.Dockerfile . -t kotsadm:cache

.PHONY: init-sbom
init-sbom:
	mkdir -p sbom/spdx

.PHONY: install-spdx-sbom-generator
install-spdx-sbom-generator: init-sbom
ifeq (,$(shell command -v spdx-sbom-generator))
	./scripts/install-sbom-generator.sh
SPDX_GENERATOR=./sbom/spdx-sbom-generator
else
SPDX_GENERATOR=$(shell command -v spdx-sbom-generator)
endif

sbom/spdx/bom-go-mod.spdx: install-spdx-sbom-generator
	$(SPDX_GENERATOR) -o ./sbom/spdx

sbom/kots-sbom.tgz: sbom/spdx/bom-go-mod.spdx
	tar -czf sbom/kots-sbom.tgz sbom/spdx/*.spdx

sbom: sbom/kots-sbom.tgz
	cosign sign-blob -key ./cosign.key sbom/kots-sbom.tgz > ./sbom/kots-sbom.tgz.sig
	cosign public-key -key ./cosign.key -outfile ./sbom/key.pub

# npm packages scans are ignored(only go modules are scanned)
.PHONY: scan
scan: 
	trivy fs \
		--scanners vuln \
		--exit-code=1 \
		--severity="CRITICAL,HIGH,MEDIUM" \
		--ignore-unfixed \
		--skip-dirs .github \
		--skip-files actions/version-tag/package-lock.json \
		--skip-files web/yarn.lock \
		--skip-dirs web/node_modules \
		--ignorefile .trivyignore \
		./

.PHONY: generate-kubectl-versions
generate-kubectl-versions: 
	node .github/actions/kubectl-versions/dist/index.js
