FROM python:3.13-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates caddy curl libcurl4 tini && \
    mkdir -p /etc/pki/tls/certs && \
    ln -sf /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 azquack && \
    useradd --uid 1000 --gid azquack --create-home azquack

WORKDIR /app

COPY pyproject.toml README.md ./
COPY src/ src/
COPY deploy/ deploy/
RUN pip install --no-cache-dir .

ENV CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
ENV CURL_CA_INFO=/etc/ssl/certs/ca-certificates.crt
ENV CURL_CA_PATH=/etc/ssl/certs
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV SSL_CERT_DIR=/etc/ssl/certs

EXPOSE 8080 8081 9494
USER azquack

ENTRYPOINT ["tini", "--", "azquack-entrypoint"]
