.PHONY: deploy test destroy

deploy:
	./scripts/deploy.sh

test:
	./scripts/smoke-test.sh

destroy:
	./scripts/destroy.sh
