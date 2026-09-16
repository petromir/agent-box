# Optional path to a CA bundle for builds behind a TLS-intersecting proxy,
# fed to the Dockerfiles as build secret `external_ca` (see README
# "Building behind a TLS-intersecting proxy"). Unset by default; set it in
# the environment (EXTERNAL_CA=... make oc-docker) or an exported variable.
EXTERNAL_CA ?=

# Expands to the --secret flag only when a CA bundle path is set; the
# Dockerfiles' external_ca mounts are required=false, so builds succeed
# without it.
ifneq ($(strip $(EXTERNAL_CA)),)
CA_SECRET = --secret id=external_ca,src=$(EXTERNAL_CA)
else
CA_SECRET =
endif

oc-docker:
	docker build --no-cache -f opencode/opencode.Dockerfile $(CA_SECRET) -t ai-agent-box-opencode:1.18.30 .
	docker build --no-cache -f java/java-21.Dockerfile $(CA_SECRET) --build-arg BASE_USER=opencode --build-arg BASE_IMAGE=ai-agent-box-opencode:1.18.30 -t ai-agent-box-opencode-java:21 .
	docker build --no-cache -f java/java-25.Dockerfile $(CA_SECRET) --build-arg BASE_USER=opencode --build-arg BASE_IMAGE=ai-agent-box-opencode:1.18.30 -t ai-agent-box-opencode-java:25 .
	docker build --no-cache -f java/graalvm-25.Dockerfile $(CA_SECRET) --build-arg BASE_USER=opencode --build-arg BASE_IMAGE=ai-agent-box-opencode:1.18.30 -t ai-agent-box-opencode-graalvm:25 .

omp-docker:
	docker build --no-cache -f omp/omp.Dockerfile $(CA_SECRET) -t ai-agent-box-omp:18.1.21 .
	docker build --no-cache -f java/java-25.Dockerfile $(CA_SECRET) --build-arg BASE_USER=omp --build-arg BASE_IMAGE=ai-agent-box-omp:18.1.21 -t ai-agent-box-omp-java:21 .
	docker build --no-cache -f java/java-25.Dockerfile $(CA_SECRET) --build-arg BASE_USER=omp --build-arg BASE_IMAGE=ai-agent-box-omp:18.1.21 -t ai-agent-box-omp-java:25 .
	docker build --no-cache -f java/graalvm-25.Dockerfile $(CA_SECRET) --build-arg BASE_USER=omp --build-arg BASE_IMAGE=ai-agent-box-omp:18.1.21 -t ai-agent-box-omp-graalvm:25 .
