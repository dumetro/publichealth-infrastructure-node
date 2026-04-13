FROM postgis/postgis:16-3.4

# Install pgvector from the PGDG apt repo (already configured in the base image).
# Using the apt package avoids a full build-tools chain and is more reliable in CI/bootstrap.
RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-16-pgvector \
    && rm -rf /var/lib/apt/lists/*
