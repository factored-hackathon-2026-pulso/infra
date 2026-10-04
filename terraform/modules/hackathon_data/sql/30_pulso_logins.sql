-- Run as the RDS master on database "pulso", AFTER the engine's db/sql/001..090 (they create schemas raw, augmented,
-- product, pulso and the roles pulso_raw_ro, pulso_augmented_ro, pulso_product_ro, pulso_loader, pulso_app as NOLOGIN).
-- Enables login with passwords from the environment. The three *_ro roles keep default_transaction_read_only=on.
\set ON_ERROR_STOP on
\getenv pulso_app_pw DB_PASSWORD_PULSO_APP
\getenv pulso_loader_pw DB_PASSWORD_PULSO_LOADER
\getenv pulso_raw_ro_pw DB_PASSWORD_PULSO_RAW_RO
\getenv pulso_augmented_ro_pw DB_PASSWORD_PULSO_AUGMENTED_RO
\getenv pulso_product_ro_pw DB_PASSWORD_PULSO_PRODUCT_RO

SELECT format('ALTER ROLE pulso_app LOGIN PASSWORD %L', :'pulso_app_pw') \gexec
SELECT format('ALTER ROLE pulso_loader LOGIN PASSWORD %L', :'pulso_loader_pw') \gexec
SELECT format('ALTER ROLE pulso_raw_ro LOGIN PASSWORD %L', :'pulso_raw_ro_pw') \gexec
SELECT format('ALTER ROLE pulso_augmented_ro LOGIN PASSWORD %L', :'pulso_augmented_ro_pw') \gexec
SELECT format('ALTER ROLE pulso_product_ro LOGIN PASSWORD %L', :'pulso_product_ro_pw') \gexec

GRANT CONNECT ON DATABASE pulso TO pulso_app, pulso_loader, pulso_raw_ro, pulso_augmented_ro, pulso_product_ro;
-- pulso_app owns the engine-written schema (migrations/ run as the master or pulso_app).
GRANT USAGE, CREATE ON SCHEMA pulso TO pulso_app;
