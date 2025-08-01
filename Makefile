# Copyright 2021-2025 The k8gb Contributors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Generated by GoLic, for more details see: https://github.com/AbsaOSS/golic
###############################
#       DOTENV
###############################
ifneq ($(wildcard ./.env),)
	include .env
	export
endif

###############################
#		CONSTANTS
###############################
ARCH ?= $(shell uname -m)
ifeq ($(ARCH), x86_64)
	ARCH=amd64
endif
CLUSTERS_NUMBER ?= 2
CLUSTER_IDS = $(shell seq $(CLUSTERS_NUMBER))
CLUSTER_NAME ?= test-gslb
CLUSTER_GEO_TAGS ?= eu us cz af ru ap uk ca
CHART ?= k8gb/k8gb
CLUSTER_GSLB_NETWORK = k3d-action-bridge-network
CLUSTER_GSLB_GATEWAY = docker network inspect ${CLUSTER_GSLB_NETWORK} -f '{{ (index .IPAM.Config 0).Gateway }}'
FULL_LOCAL_SETUP_WITH_APPS ?= true
GSLB_DOMAIN ?= cloud.example.com
REPO := absaoss/k8gb
SHELL := bash
VALUES_YAML ?= ""
PODINFO_IMAGE_REPO ?= ghcr.io/stefanprodan/podinfo
HELM_ARGS ?=
K8GB_COREDNS_IP ?= kubectl get svc k8gb-coredns -n k8gb -o custom-columns='IP:spec.clusterIP' --no-headers
LOG_FORMAT ?= simple
LOG_LEVEL ?= debug
CONTROLLER_GEN_VERSION  ?= v0.16.5
GOLIC_VERSION  ?= v0.7.2
GOLANGCI_VERSION ?= v2.0.2
ISTIO_VERSION ?= v1.23.3
POD_NAMESPACE ?= k8gb
CLUSTER_GEO_TAG ?= eu
EXT_GSLB_CLUSTERS_GEO_TAGS ?= us
EDGE_DNS_SERVER ?= 1.1.1.1
EDGE_DNS_ZONE ?= example.com
DNS_ZONE ?= cloud.example.com
DEMO_URL ?= http://failover.cloud.example.com
DEMO_DEBUG ?=0
DEMO_DELAY ?=5
GSLB_CRD_YAML ?= chart/k8gb/crd/k8gb.absa.oss_gslbs.yaml

ifndef NO_COLOR
YELLOW=\033[0;33m
CYAN=\033[1;36m
RED=\033[31m
# no color
NC=\033[0m
endif

NO_VALUE ?= no_value

###############################
#		VARIABLES
###############################
PWD ?=  $(shell pwd)
ifndef VERSION
VERSION := $(shell git fetch --force --tags &> /dev/null ; git describe --tags --abbrev=0)
endif
COMMIT_HASH ?= $(shell git rev-parse --short HEAD)
SEMVER ?= $(VERSION)-$(COMMIT_HASH)
# image URL to use all building/pushing image targets
IMG ?= $(REPO):$(VERSION)
STABLE_VERSION := "stable"
# default bundle image tag
BUNDLE_IMG ?= controller-bundle:$(VERSION)

NGINX_INGRESS_VALUES_PATH ?= deploy/ingress/nginx-ingress-values.yaml
ISTIO_INGRESS_VALUES_PATH ?= deploy/ingress/istio-ingress-values.yaml

# options for 'bundle-build'
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# create GOBIN if not specified
ifndef GOBIN
GOBIN=$(shell go env GOPATH)/bin
endif

###############################
#		TARGETS
###############################

all: help

# check integrity
.PHONY: check
check: license lint test ## Check project integrity

.PHONY: clean-test-apps
clean-test-apps:
	kubectl delete --ignore-not-found -f deploy/test-apps
	helm -n test-gslb uninstall frontend

# see: https://dev4devs.com/2019/05/04/operator-framework-how-to-debug-golang-operator-projects/
.PHONY: debug-idea
debug-idea: export WATCH_NAMESPACE=test-gslb
debug-idea:
	$(call debug,debug --headless --listen=:2345 --api-version=2)

.PHONY: demo
demo: ## Execute end-to-end demo
	@$(call demo-host, $(DEMO_URL))

K8GB_LOCAL_VERSION ?= stable
# Spin-up local environment. Deploys stable released version by default
# Use `K8GB_LOCAL_VERSION=test make deploy-full-local-setup`
.PHONY: deploy-full-local-setup
deploy-full-local-setup: ensure-cluster-size ## Deploy full local multicluster setup (k3d >= 5.1.0)
	$(MAKE) create-local-clusters

	@if [ "$(K8GB_LOCAL_VERSION)" = test ]; then $(MAKE) release-images ; fi
	$(MAKE) deploy-$(K8GB_LOCAL_VERSION)-version DEPLOY_APPS=$(FULL_LOCAL_SETUP_WITH_APPS)

.PHONY: deploy-stable-version
deploy-stable-version:
	$(call deploy-edgedns)
	@for c in $(CLUSTER_IDS); do \
		$(MAKE) deploy-local-cluster CLUSTER_ID=$$c ;\
	done

.PHONY: deploy-test-version
deploy-test-version: ## Upgrade k8gb to the test version on existing clusters
	$(call deploy-edgedns)
	@echo -e "\n$(YELLOW)import k8gb docker image to all $(CLUSTERS_NUMBER) clusters$(NC)"

	@for c in $(CLUSTER_IDS); do \
		echo -e "\n$(CYAN)$(CLUSTER_NAME)$$c:$(NC)" ;\
		k3d image import $(REPO):$(SEMVER)-$(ARCH) -c $(CLUSTER_NAME)$$c ;\
	done

	@for c in $(CLUSTER_IDS); do \
		$(MAKE) deploy-local-cluster CLUSTER_ID=$$c VERSION=$(SEMVER)-$(ARCH) CHART='./chart/k8gb' ;\
	done

.PHONY: list-running-pods
list-running-pods:
	@for c in $(CLUSTER_IDS); do \
		echo -e "\n$(YELLOW)Local cluster $(CYAN)$(CLUSTER_NAME)$$c $(NC)" ;\
		kubectl get pods -A --context=k3d-$(CLUSTER_NAME)$$c ;\
	done

.PHONY: create-local-clusters
create-local-clusters:
	@echo -e "\n$(YELLOW)Creating $$(( $(CLUSTERS_NUMBER) + 1 )) k8s clusters$(NC)"
	$(MAKE) create-local-cluster CLUSTER_NAME=edge-dns
	@for c in $(CLUSTER_IDS); do \
		$(MAKE) create-local-cluster CLUSTER_NAME=$(CLUSTER_NAME)$$c ;\
	done

.PHONY: create-local-cluster
create-local-cluster:
	@echo -e "\n$(YELLOW)Create local cluster $(CYAN)$(CLUSTER_NAME) $(NC)"
	k3d cluster create -c k3d/$(CLUSTER_NAME).yaml

.PHONY: deploy-local-cluster
deploy-local-cluster:
	@if [ -z "$(CLUSTER_ID)" ]; then echo invalid CLUSTER_ID value && exit 1; fi
	@echo -e "\n$(YELLOW)Deploy local cluster $(CYAN)$(CLUSTER_NAME)$(CLUSTER_ID) $(NC)"
	kubectl config use-context k3d-$(CLUSTER_NAME)$(CLUSTER_ID)

	@echo -e "\n$(YELLOW)Create namespace $(NC)"
	kubectl create namespace k8gb --dry-run=client -o yaml | kubectl apply -f -

	@echo -e "\n$(YELLOW)Deploy Ingress $(NC)"
	helm repo add --force-update nginx-stable https://kubernetes.github.io/ingress-nginx
	helm repo update
	helm -n k8gb upgrade -i nginx-ingress nginx-stable/ingress-nginx \
		--version 4.0.15 -f $(NGINX_INGRESS_VALUES_PATH)

	@echo -e "\n$(YELLOW)Create coredns init-ingress $(NC)"
	kubectl apply -f ./deploy/crds/init-ingress.yaml
	@echo -e "\n$(YELLOW)Wait for ingress IP $(NC)"
	@while [ -z "$$(kubectl get ingress init-ingress -n k8gb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" ]; do \
		echo "Waiting for external IP..."; \
		sleep 5; \
	done
	@echo "Ingress is ready with IP: $$(kubectl get ingress init-ingress -n k8gb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

	@echo -e "\n$(YELLOW)Deploy GSLB operator from $(VERSION) $(NC)"
	$(MAKE) deploy-k8gb-with-helm

	@echo -e "\n$(YELLOW)Install Istio CRDs $(NC)"
	kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
	helm repo add --force-update istio https://istio-release.storage.googleapis.com/charts
	helm repo update
	helm upgrade -i istio-base istio/base -n istio-system --version "$(ISTIO_VERSION)"

	@echo -e "\n$(YELLOW)Install Istiod $(NC)"
	helm upgrade -i istiod istio/istiod -n istio-system --version "$(ISTIO_VERSION)" --wait

	@echo -e "\n$(YELLOW)Install Istio Ingress Gateway $(NC)"
	kubectl create namespace istio-ingress --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade -i istio-ingressgateway istio/gateway -n istio-ingress \
		--version "$(ISTIO_VERSION)" -f $(ISTIO_INGRESS_VALUES_PATH)

	@if [ "$(DEPLOY_APPS)" = true ]; then $(MAKE) deploy-test-apps ; fi

	@echo -e "\n$(YELLOW)Wait until Ingress controller is ready $(NC)"
	$(call wait-for-ingress)

	@echo -e "\n$(CYAN)$(CLUSTER_NAME)$(CLUSTER_ID) $(YELLOW)deployed! $(NC)"

.PHONY: deploy-test-apps
deploy-test-apps: ## Deploy Podinfo (example app) and Apply Gslb Custom Resources
	@echo -e "\n$(YELLOW)Deploy GSLB cr $(NC)"
	kubectl apply -f deploy/crds/test-namespace-ingress.yaml
	$(call apply-cr,deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr_roundrobin_ingress_ref.yaml)
	$(call apply-cr,deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr_failover_ingress_ref.yaml)

	kubectl apply -f deploy/crds/test-namespace-istio.yaml
	$(call apply-cr,deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr_roundrobin_istio.yaml)
	$(call apply-cr,deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr_failover_istio.yaml)
	$(call apply-cr,deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr_notfound_istio.yaml)
	$(call apply-cr,deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr_unhealthy_istio.yaml)

	@echo -e "\n$(YELLOW)Deploy podinfo $(NC)"
	kubectl apply -f deploy/test-apps
	helm repo add podinfo https://stefanprodan.github.io/podinfo
	helm upgrade --install frontend --namespace test-gslb -f deploy/test-apps/podinfo/podinfo-values.yaml \
		--set ui.message="`$(call get-cluster-geo-tag)`" \
		--set image.repository="$(PODINFO_IMAGE_REPO)" \
		podinfo/podinfo \
		--version 5.1.1
	helm upgrade --install frontend --namespace test-gslb-istio -f deploy/test-apps/podinfo/podinfo-values.yaml \
		--set ui.message="`$(call get-cluster-geo-tag)`" \
		--set image.repository="$(PODINFO_IMAGE_REPO)" \
		podinfo/podinfo \
		--version 5.1.1

.PHONY: deploy-kuar-app
deploy-kuar-app:
	./deploy/test-apps/kuar/deploy.sh $(CLUSTERS_NUMBER)

.PHONY: upgrade-candidate
upgrade-candidate: release-images deploy-test-version

.PHONY: deploy-k8gb-with-helm
deploy-k8gb-with-helm:
	@if [ -z "$(CLUSTER_ID)" ]; then echo invalid CLUSTER_ID value && exit 1; fi
	# create rfc2136 secret
	kubectl -n k8gb create secret generic rfc2136 --from-literal=secret=96Ah/a2g0/nLeFGK+d/0tzQcccf9hCEIy34PoXX2Qg8= || true
	helm repo add --force-update k8gb https://www.k8gb.io
	cd chart/k8gb && helm dependency update
	# Deletion of the coredns service is needed because of the bug below
	# The bug is triggered by the local setup change where we start exposing the port tcp/53 using a LoadBalancer service
	# Can be removed once we upgrade to k8gb v0.16.0
	# https://github.com/kubernetes/kubernetes/issues/105610
	kubectl -n k8gb delete svc k8gb-coredns --ignore-not-found
	helm -n k8gb upgrade -i k8gb $(CHART) --version=${VERSION} \
		-f $(call get-helm-values-file,$(CHART)) \
		-f $(VALUES_YAML) \
		$(call get-helm-args,$(CLUSTER_ID)) \
		$(call get-next-args,$(CHART),$(CLUSTER_ID)) \
		--set k8gb.imageTag=${VERSION:"stable"=""} \
		--wait --timeout=10m0s

.PHONY: deploy-gslb-operator
deploy-gslb-operator: ## Deploy k8gb operator
	kubectl create namespace k8gb --dry-run=client -o yaml | kubectl apply -f -
	cd chart/k8gb && helm dependency update
	helm -n k8gb upgrade -i k8gb chart/k8gb -f $(VALUES_YAML) $(HELM_ARGS) \
		--set k8gb.log.format=$(LOG_FORMAT)
		--set k8gb.log.level=$(LOG_LEVEL)

# destroy local test environment
.PHONY: destroy-full-local-setup
destroy-full-local-setup: ## Destroy full local multicluster setup
	k3d cluster delete edgedns
	@for c in $(CLUSTER_IDS); do \
		k3d cluster delete $(CLUSTER_NAME)$$c ;\
	done

.PHONY: deploy-prometheus
deploy-prometheus:
	@for c in $(CLUSTER_IDS); do \
		$(call deploy-prometheus,$(CLUSTER_NAME)$$c) ;\
	done

.PHONY: uninstall-prometheus
uninstall-prometheus:
	@for c in $(CLUSTER_IDS); do \
		$(call uninstall-prometheus,$(CLUSTER_NAME)$$c) ;\
	done

.PHONY: deploy-grafana
deploy-grafana:
	@echo -e "\n$(YELLOW)Local cluster $(CYAN)$(CLUSTER_NAME)1$(NC)"
	@echo -e "\n$(YELLOW)install grafana $(NC)"
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo update
	helm -n k8gb upgrade -i grafana grafana/grafana -f deploy/grafana/values.yaml \
		--wait --timeout=4m \
		--version=6.38.6 \
		--kube-context=k3d-$(CLUSTER_NAME)1
	kubectl --context k3d-$(CLUSTER_NAME)1 apply -f deploy/grafana/dashboard-cm.yaml -n k8gb
	mkdir grafana/dashboards/ || true
	cat grafana/controller-resources-metrics.json | sed 's/$${DS_PROMETHEUS}/Prometheus/g' > grafana/dashboards/controller-resources-metrics.json
	cat grafana/controller-runtime-metrics.json | sed 's/$${DS_PROMETHEUS}/Prometheus/g' > grafana/dashboards/controller-runtime-metrics.json
	cat grafana/custom-metrics/pretty-custom-metrics-dashboard.json | sed 's/$${DS_PROMETHEUS}/Prometheus/g' > grafana/dashboards/pretty-custom-metrics-dashboard.json
	kubectl --context k3d-$(CLUSTER_NAME)1 -n k8gb create cm -n k8gb k8gb-dashboards --from-file=./grafana/dashboards/ --dry-run=client -oyaml | kubectl apply --context k3d-$(CLUSTER_NAME)1 -f -
	kubectl --context k3d-$(CLUSTER_NAME)1 -n k8gb label cm k8gb-dashboards grafana_dashboard=true --overwrite
	rm -rf grafana/dashboards/
	@echo -e "\nGrafana is listening on http://localhost:3000\n"
	@echo -e "🖖 credentials are admin:admin\n"


.PHONY: uninstall-grafana
uninstall-grafana:
	@echo -e "\n$(YELLOW)Local cluster $(CYAN)$(CLUSTER_GSLB1)$(NC)"
	@echo -e "\n$(YELLOW)uninstall grafana $(NC)"
	kubectl --context k3d-$(CLUSTER_NAME)1 delete --ignore-not-found -f deploy/grafana/dashboard-cm.yaml -n k8gb
	kubectl --context k3d-$(CLUSTER_NAME)1 delete cm --ignore-not-found -n k8gb k8gb-dashboards
	helm uninstall grafana -n k8gb --kube-context=k3d-$(CLUSTER_NAME)1

.PHONY: dns-tools
dns-tools: ## Run temporary dnstools pod for debugging DNS issues
	@kubectl -n k8gb get svc k8gb-coredns
	@kubectl -n k8gb run -it --rm --restart=Never --image=infoblox/dnstools:latest dnstools

.PHONY: dns-smoke-test
dns-smoke-test:
	kubectl -n k8gb run -it --rm --restart=Never --image=infoblox/dnstools:latest dnstools --command -- /usr/bin/dig @k8gb-coredns roundrobin.cloud.example.com

# create and push docker manifest
.PHONY: docker-manifest
docker-manifest:
	docker manifest create ${IMG} \
		${IMG}-amd64 \
		${IMG}-arm64
	docker manifest annotate ${IMG} ${IMG}-arm64 \
		--os linux --arch arm64
	docker manifest push ${IMG}

.PHONY: ensure-cluster-size
ensure-cluster-size:
	@if [ "$(CLUSTERS_NUMBER)" -gt 8 ] ; then \
		echo -e "$(RED)$(CLUSTERS_NUMBER) clusters is probably way too many$(NC)" ;\
		echo -e "$(RED)you will probably hit resource limits or port collisions, gook luck you are on your own$(NC)" ;\
	fi
	@if [ "$(CLUSTERS_NUMBER)" -gt 3 ] ; then \
		./k3d/generate-yaml.sh $(CLUSTERS_NUMBER) ;\
	fi

.PHONY: goreleaser
goreleaser:
	command -v goreleaser &> /dev/null || go install github.com/goreleaser/goreleaser@v1.7.0

.PHONY: release-images
release-images: goreleaser
	goreleaser release --snapshot --skip-validate --skip-publish --rm-dist --skip-sbom --skip-sign

# build the docker image
.PHONY: docker-build
docker-build: test release-images

# build and push the docker image exclusively for testing using commit hash
.PHONY: docker-test-build-push
docker-push: test
	docker push ${IMG}-$(COMMIT_HASH)-amd64

.PHONY: init-failover
init-failover:
	$(call init-test-strategy, "deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr_failover_ingress_ref.yaml")

.PHONY: init-round-robin
init-round-robin:
	$(call init-test-strategy, "deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr_roundrobin_ingress_ref.yaml")

# creates infoblox secret in current cluster
.PHONY: infoblox-secret
infoblox-secret:
	kubectl -n k8gb create secret generic infoblox \
		--from-literal=INFOBLOX_WAPI_USERNAME=$${WAPI_USERNAME} \
		--from-literal=INFOBLOX_WAPI_PASSWORD=$${WAPI_PASSWORD}

# updates source code with license headers
.PHONY: license
license:
	@echo -e "\n$(YELLOW)Injecting the license$(NC)"
	$(call golic,-t apache2)

# creates ns1 secret in current cluster
.PHONY: ns1-secret
ns1-secret:
	kubectl -n k8gb create secret generic ns1 \
		--from-literal=apiKey=$${NS1_APIKEY}


# runs golangci-lint aggregated linter; see .golangci.yaml for linter list
# https://golangci-lint.run/welcome/install/#binaries
.PHONY: lint
lint:
	@echo -e "\n$(YELLOW)Running the linters$(NC)"
	@go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_VERSION)
	$(GOBIN)/golangci-lint run -c ./.golangci.yaml

# retrieves all targets
.PHONY: list
list:
	@$(MAKE) -pRrq -f $(lastword $(MAKEFILE_LIST)) : 2>/dev/null | awk -v RS= -F: '/^# File/,/^# Finished Make data base/ {if ($$1 !~ "^[#.]") {print $$1}}' | sort | egrep -v -e '^[^[:alnum:]]' -e '^$@$$'

# build k8gb binary
.PHONY: k8gb
k8gb: lint
	$(call generate)
	go build -o bin/k8gb main.go

.PHONY: mocks
mocks:
	go install go.uber.org/mock/mockgen@v0.4.0
	mockgen -package=mocks -destination=controllers/mocks/assistant_mock.go -source=controllers/providers/assistant/assistant.go Assistant
	mockgen -package=mocks -destination=controllers/mocks/infoblox-client_mock.go -source=controllers/providers/dns/infoblox-client.go InfobloxClient
	mockgen -package=mocks -destination=controllers/mocks/infoblox-object-manager_mock.go github.com/infobloxopen/infoblox-go-client/v2 IBObjectManager
	mockgen -package=mocks -destination=controllers/mocks/infoblox-connection_mock.go github.com/infobloxopen/infoblox-go-client IBConnector
	mockgen -package=mocks -destination=controllers/mocks/manager_mock.go sigs.k8s.io/controller-runtime/pkg/manager Manager
	mockgen -package=mocks -destination=controllers/mocks/client_mock.go sigs.k8s.io/controller-runtime/pkg/client Client
	mockgen -package=mocks -destination=controllers/mocks/resolver_mock.go -source=controllers/resolver/resolver.go GslbResolver
	mockgen -package=mocks -destination=controllers/mocks/dns_query_service_mock.go -source=controllers/utils/dns_query_service.go DNSQueryService
	mockgen -package=mocks -destination=controllers/mocks/refresolver_mock.go -source=controllers/refresolver/refresolver.go GslbRefResolver
	mockgen -package=mocks -destination=controllers/mocks/provider_mock.go -source=controllers/providers/dns/dns.go Provider
	mockgen -package=mocks -destination=controllers/mocks/geotags_mock.go -source=controllers/geotags/geotags.go GeoTags
	$(call golic)

# remove clusters and redeploy
.PHONY: reset
reset:	destroy-full-local-setup deploy-full-local-setup

# run against the configured Kubernetes cluster in ~/.kube/config
.PHONY: run
run: lint
	$(call generate)
	$(call crd-manifest)
	@echo -e "\n$(YELLOW)Running k8gb locally against the current k8s cluster$(NC)"
	LOG_FORMAT=$(LOG_FORMAT) \
	LOG_LEVEL=$(LOG_LEVEL) \
	POD_NAMESPACE=$(POD_NAMESPACE) \
	CLUSTER_GEO_TAG=$(CLUSTER_GEO_TAG) \
	EXT_GSLB_CLUSTERS_GEO_TAGS=$(EXT_GSLB_CLUSTERS_GEO_TAGS) \
	EDGE_DNS_SERVERS=$(EDGE_DNS_SERVER) \
	EDGE_DNS_ZONE=$(EDGE_DNS_ZONE) \
	DNS_ZONE=$(DNS_ZONE) \
	go run ./main.go

.PHONY: stop-test-app
stop-test-app:
	$(call testapp-set-replicas,0)

.PHONY: start-test-app
start-test-app:
	$(call testapp-set-replicas,2)

# run tests
.PHONY: test
test:
	$(call generate)
	$(call crd-manifest)
	@echo -e "\n$(YELLOW)Running the unit tests$(NC)"
	env -u LOG_FORMAT -u LOG_LEVEL -u EXT_GSLB_CLUSTERS_GEO_TAGS -u EDGE_DNS_SERVER go test ./... -coverprofile cover.out

.PHONY: test-round-robin
test-round-robin:
	@$(call hit-testapp-host, "roundrobin.cloud.example.com")

.PHONY: test-failover
test-failover:
	@$(call hit-testapp-host, "failover.cloud.example.com")

# executes terratests
.PHONY: terratest
terratest: # Run terratest suite
	@$(eval RUNNING_CLUSTERS := $(shell k3d cluster list --no-headers | grep $(CLUSTER_NAME) -c))
	@$(eval TEST_TAGS := $(shell [ $(RUNNING_CLUSTERS) == 2 ] && echo all || echo rr_multicluster))
	@if [ "$(RUNNING_CLUSTERS)" -lt 2 ] ; then \
		echo -e "$(RED)Make sure you run the tests against at least two running clusters$(NC)" ;\
		exit 1;\
	fi
	cd terratest/test/ && go mod download && CLUSTERS_NUMBER=$(RUNNING_CLUSTERS) go test -v -timeout 25m -parallel=12 --tags=$(TEST_TAGS)

# executes chainsaw e2e tests
.PHONY: chainsaw
chainsaw:
	mkdir -p chainsaw/kubeconfig
	k3d kubeconfig get test-gslb1 > chainsaw/kubeconfig/eu.config
	k3d kubeconfig get test-gslb2 > chainsaw/kubeconfig/us.config
	@$(eval RUNNING_CLUSTERS := $(shell k3d cluster list --no-headers | grep $(CLUSTER_NAME) -c))
	@if [ "$(RUNNING_CLUSTERS)" -lt 2 ] ; then \
		echo -e "$(RED)Make sure you run the tests against at least two running clusters$(NC)" ;\
		exit 1;\
	fi
	cd chainsaw && CLUSTERS_NUMBER=$(RUNNING_CLUSTERS) chainsaw test --config ./config.yaml --values ./values.yaml
	rm -r chainsaw/kubeconfig

.PHONY: website
website:
	@if [ "$(CI)" = "true" ]; then\
		git config remote.origin.url || git remote add -f -t gh-pages origin https://github.com/k8gb-io/k8gb ;\
		git fetch origin gh-pages:gh-pages ;\
		git checkout gh-pages ;\
		git checkout - README.md CONTRIBUTING.md CHANGELOG.md docs/ ;\
		$(MAKE) website ;\
	fi

.PHONY: version
version:
	@echo $(VERSION)

.PHONY: help
help: ## Show this help
	@egrep -h '\s##\s' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

###############################
#		FUNCTIONS
###############################

define deploy-edgedns
	@echo -e "\n$(YELLOW)Deploying EdgeDNS $(NC)"
	kubectl --context k3d-edgedns apply -f deploy/edge/
endef

define apply-cr
	sed 's/cloud\.example\.com/$(GSLB_DOMAIN)/g' "$1" > "$1-cr"
	-kubectl apply -f "$1-cr"
	-rm "$1-cr"
endef

define get-cluster-geo-tag
	kubectl -n k8gb describe deploy k8gb |  awk '/CLUSTER_GEO_TAG/ { printf $$2 }'
endef

nth-geo-tag = $(subst $1_,,$(filter $1_%, $(join $(addsuffix _,$(CLUSTER_IDS)),$(CLUSTER_GEO_TAGS))))

define get-ext-tags
$(shell echo $(foreach cl,$(filter-out $1,$(shell seq $(CLUSTERS_NUMBER))),$(call nth-geo-tag,$(cl)))
	| sed 's/ /\\,/g')
endef

define hit-testapp-host
	kubectl run -it --rm busybox --restart=Never --image=busybox --command \
	--overrides "{\"spec\":{\"dnsConfig\":{\"nameservers\":[\"$(shell $(K8GB_COREDNS_IP))\"]},\"dnsPolicy\":\"None\"}}" \
	-- wget -qO - $1
endef

define init-test-strategy
 	kubectl config use-context k3d-test-gslb2
 	kubectl apply -f $1
 	kubectl config use-context k3d-test-gslb1
 	kubectl apply -f $1
	$(MAKE) start-test-app

endef

define testapp-set-replicas
	kubectl scale deployment frontend-podinfo -n test-gslb --replicas=$1
endef

define demo-host
	kubectl run -it --rm k8gb-demo --restart=Never --image=absaoss/k8gb-demo-curl --env="DELAY=$(DEMO_DELAY)" --env="DEBUG=$(DEMO_DEBUG)" \
	"`$(K8GB_COREDNS_IP)`" $1
endef

# waits for NGINX, GSLB are ready
define wait-for-ingress
	kubectl -n k8gb wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx --timeout=600s
endef

define generate
	$(call install-controller-gen)
	@echo -e "\n$(YELLOW)Generating the API code$(NC)"
	$(GOBIN)/controller-gen object:headerFile="hack/boilerplate.go.txt" paths="./..."
endef

define crd-manifest
	$(call install-controller-gen)
	@echo -e "\n$(YELLOW)Generating the CRD manifests$(NC)"
	$(GOBIN)/controller-gen crd:crdVersions=v1 paths="./..." output:crd:stdout > $(GSLB_CRD_YAML)
endef

define install-controller-gen
	@go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_GEN_VERSION)
endef

define golic
	@go install github.com/AbsaOSS/golic@$(GOLIC_VERSION)
	$(GOBIN)/golic inject $1
endef

define debug
	$(call manifest)
	kubectl apply -f deploy/crds/test-namespace-ingress.yaml
	kubectl apply -f ./chart/k8gb/templates/k8gb.absa.oss_gslbs.yaml
	kubectl apply -f ./deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr_roundrobin_ingress.yaml
	dlv $1
endef

define annotate-for-scraping
	kubectl annotate pods -n k8gb -l $1 --overwrite prometheus.io/scrape="true" --overwrite prometheus.io/port="$2" --context=k3d-$3
endef

define stop-scraping
	kubectl annotate pods -n k8gb -l $1 prometheus.io/scrape- prometheus.io/port- --context=k3d-$2
endef

define deploy-prometheus
	echo -e "\n$(YELLOW)Local cluster $(CYAN)$1$(NC)" ;\
	echo -e "\n$(YELLOW)Set annotations on pods that will be scraped by prometheus$(NC)" ;\
	$(call annotate-for-scraping,"name=k8gb",8080,$1) ;\
	$(call annotate-for-scraping,"app=external-dns",7979,$1) ;\
	$(call annotate-for-scraping,"app.kubernetes.io/name=coredns",9153,$1) ;\
	echo -e "\n$(YELLOW)install prometheus $(NC)" ;\
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts ;\
	helm repo update ;\
	helm -n k8gb upgrade -i prometheus prometheus-community/prometheus -f deploy/prometheus/values.yaml \
		--version 15.14.0 \
		--wait --timeout=2m0s \
		--kube-context=k3d-$1
endef

define uninstall-prometheus
	echo -e "\n$(YELLOW)Local cluster $(CYAN)$1$(NC)" ;\
	echo -e "\n$(YELLOW)uninstall prometheus $(NC)" ;\
	helm uninstall prometheus -n k8gb --kube-context=k3d-$1 ;\
	$(call stop-scraping,"name=k8gb",$1) ;\
	$(call stop-scraping,"app=external-dns",$1) ;\
	$(call stop-scraping,"app.kubernetes.io/name=coredns",$1)
endef

define get-helm-args
--set k8gb.clusterGeoTag='$(call nth-geo-tag,$1)' --set k8gb.extGslbClustersGeoTags='$(call get-ext-tags,$1)' --set k8gb.edgeDNSServers[0]=$(shell $(CLUSTER_GSLB_GATEWAY)):1053
endef

define get-helm-values-file
$(if $(filter k8gb/k8gb,$(1)),./deploy/helm/stable.yaml,./deploy/helm/next.yaml)
endef

# values here are only available in the not released (next) version.
# by releases the content would be moved into get-helm-args
define get-next-args
$(if $(filter ./chart/k8gb,$(1)),--set extdns.txtPrefix='k8gb-$(call nth-geo-tag,$2)-' --set extdns.txtOwnerId='k8gb-$(call nth-geo-tag,$2)')
endef
