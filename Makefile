oc-docker:
	docker build --no-cache -f opencode/opencode.Dockerfile --secret id=external_ca,src=/usr/local/share/ca-certificates/combined-ca-bundle.crt -t ai-agent-box-opencode:1.18.30 .
	docker build --no-cache -f java/java-21.Dockerfile --secret id=external_ca,src=/usr/local/share/ca-certificates/combined-ca-bundle.crt --build-arg BASE_USER=opencode --build-arg BASE_IMAGE=ai-agent-box-opencode:1.18.30 -t ai-agent-box-opencode-java:21 .
	docker build --no-cache -f java/java-25.Dockerfile --secret id=external_ca,src=/usr/local/share/ca-certificates/combined-ca-bundle.crt --build-arg BASE_USER=opencode --build-arg BASE_IMAGE=ai-agent-box-opencode:1.18.30 -t ai-agent-box-opencode-java:25 .
	docker build --no-cache -f java/graalvm-25.Dockerfile --secret id=external_ca,src=/usr/local/share/ca-certificates/combined-ca-bundle.crt --build-arg BASE_USER=opencode --build-arg BASE_IMAGE=ai-agent-box-opencode:1.18.30 -t ai-agent-box-opencode-graalvm:25 .

omp-docker:
	docker build --no-cache -f omp/omp.Dockerfile --secret id=external_ca,src=/usr/local/share/ca-certificates/combined-ca-bundle.crt -t ai-agent-box-omp:18.1.21 .
	docker build --no-cache -f java/java-25.Dockerfile --secret id=external_ca,src=/usr/local/share/ca-certificates/combined-ca-bundle.crt --build-arg BASE_USER=omp --build-arg BASE_IMAGE=ai-agent-box-omp:18.1.21 -t ai-agent-box-omp-java:21 .
	docker build --no-cache -f java/java-25.Dockerfile --secret id=external_ca,src=/usr/local/share/ca-certificates/combined-ca-bundle.crt --build-arg BASE_USER=omp --build-arg BASE_IMAGE=ai-agent-box-omp:18.1.21 -t ai-agent-box-omp-java:25 .
	docker build --no-cache -f java/graalvm-25.Dockerfile --secret id=external_ca,src=/usr/local/share/ca-certificates/combined-ca-bundle.crt --build-arg BASE_USER=omp --build-arg BASE_IMAGE=ai-agent-box-omp:18.1.21 -t ai-agent-box-omp-graalvm:25 .