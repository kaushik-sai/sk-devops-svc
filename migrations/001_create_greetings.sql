-- 001: a small example table so the migration flow has something real to apply.
-- Applied once by scripts/Invoke-Migrations.ps1 inside one transaction,
-- together with its row in schema_migrations. Do not add BEGIN/COMMIT here:
-- the runner already wraps the whole file in a transaction.

CREATE TABLE greetings (
    id         serial      PRIMARY KEY,
    message    text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
