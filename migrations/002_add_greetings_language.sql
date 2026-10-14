-- 002: add a column to the example table.
-- Backward compatible ("expand" step): the column has a default, so the
-- previous app version, which does not know about it, keeps working.
-- That matters because a rollback redeploys the old image but does not
-- undo migrations.

ALTER TABLE greetings
    ADD COLUMN language text NOT NULL DEFAULT 'en';
