FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ARG BINARY=deadly-pool-server
COPY export/${BINARY}.x86_64 ./deadly-pool-server.x86_64
COPY export/${BINARY}.pck ./deadly-pool-server.pck
RUN chmod +x deadly-pool-server.x86_64

EXPOSE 9876/tcp
EXPOSE 8081/tcp

CMD ["./deadly-pool-server.x86_64", "--headless", "--server"]
