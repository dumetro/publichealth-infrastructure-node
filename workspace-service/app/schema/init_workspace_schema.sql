CREATE SCHEMA IF NOT EXISTS workspace;

CREATE TABLE workspace.workspaces (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username      TEXT NOT NULL,
    project_name  TEXT NOT NULL,
    display_name  TEXT,
    description   TEXT,
    minio_prefix  TEXT NOT NULL,
    status        TEXT NOT NULL DEFAULT 'active',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (username, project_name)
);

CREATE TABLE workspace.minio_service_accounts (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username         TEXT NOT NULL UNIQUE,
    minio_access_key TEXT NOT NULL,
    iam_policy_name  TEXT NOT NULL,
    k8s_secret_name  TEXT NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE workspace.git_configurations (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id     UUID REFERENCES workspace.workspaces(id) ON DELETE CASCADE,
    username         TEXT NOT NULL,
    repo_url         TEXT NOT NULL,
    branch           TEXT NOT NULL DEFAULT 'main',
    credential_type  TEXT NOT NULL DEFAULT 'https_token',
    k8s_secret_name  TEXT,
    clone_path       TEXT,
    linked_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE workspace.bucket_access_grants (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID REFERENCES workspace.workspaces(id) ON DELETE CASCADE,
    username     TEXT NOT NULL,
    bucket_name  TEXT NOT NULL,
    path_prefix  TEXT,
    access_level TEXT NOT NULL DEFAULT 'read',
    status       TEXT NOT NULL DEFAULT 'pending',
    requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    reviewed_at  TIMESTAMPTZ,
    reviewed_by  TEXT,
    review_notes TEXT,
    UNIQUE (workspace_id, bucket_name, path_prefix)
);

CREATE TABLE workspace.notebook_dependencies (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id  UUID REFERENCES workspace.workspaces(id) ON DELETE CASCADE,
    notebook_path TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_ref  TEXT NOT NULL,
    recorded_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, notebook_path, resource_type, resource_ref)
);

CREATE TABLE workspace.admin_audit_log (
    id         BIGSERIAL PRIMARY KEY,
    actor      TEXT NOT NULL,
    action     TEXT NOT NULL,
    target_type TEXT,
    target_id  TEXT,
    detail     JSONB,
    acted_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ON workspace.workspaces (username);
CREATE INDEX ON workspace.bucket_access_grants (status);
CREATE INDEX ON workspace.bucket_access_grants (workspace_id);
CREATE INDEX ON workspace.notebook_dependencies (workspace_id);
