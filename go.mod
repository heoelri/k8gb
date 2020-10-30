module github.com/AbsaOSS/k8gb

go 1.13

require (
	github.com/ghodss/yaml v1.0.0
	github.com/go-logr/logr v0.1.0
	github.com/infobloxopen/infoblox-go-client v1.1.0
	github.com/lixiangzhong/dnsutil v0.0.0-20191203032812-75ad39d2945a
	github.com/miekg/dns v1.1.30
	github.com/onsi/ginkgo v1.12.1
	github.com/onsi/gomega v1.10.1
	github.com/prometheus/client_golang v1.7.1
	github.com/stretchr/testify v1.5.1
	k8s.io/api v0.18.8
	k8s.io/apimachinery v0.18.8
	k8s.io/client-go v0.18.8
	sigs.k8s.io/controller-runtime v0.6.2
	sigs.k8s.io/external-dns v0.7.4
)