FROM postgis/postgis:16-3.4

ARG PGVECTOR_VERSION=v0.8.0

# Build and install pgvector so both postgis and vector extensions are available.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      git \
      postgresql-server-dev-16 \
    && git clone --branch "${PGVECTOR_VERSION}" --depth 1 https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && make -C /tmp/pgvector \
    && make -C /tmp/pgvector install \
    && apt-get purge -y --auto-remove build-essential git postgresql-server-dev-16 \
    && rm -rf /tmp/pgvector /var/lib/apt/lists/*
