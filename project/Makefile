.PHONY: ingress app monitoring logging all clean

ingress:
	./scripts/01_install_ingress.sh

app:
	./scripts/02_deploy_app.sh

monitoring:
	./scripts/03_install_monitoring.sh

logging:
	./scripts/04_install_logging.sh

all: ingress app monitoring logging

clean:
	./scripts/90_cleanup.sh
