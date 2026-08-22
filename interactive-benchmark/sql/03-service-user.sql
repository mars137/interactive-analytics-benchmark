-- =============================================================================
-- WI-22 Interactive Analytics Benchmark -- 03: dedicated service user
-- =============================================================================
-- A TYPE = SERVICE user with key-pair auth, so no long-lived secret is written to
-- .env and no human credential is reused by the harness.
--
-- TYPE = SERVICE users cannot have a password and are exempt from MFA enrollment
-- policies, which is exactly what a benchmark harness needs.
--
-- Private key: ~/.snowflake/keys/ia_bench_svc.p8 (chmod 600, outside the repo)
-- Public key registered below.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

CREATE USER IF NOT EXISTS IA_BENCH_SVC
    TYPE = SERVICE
    DEFAULT_ROLE = FLAKEBENCH_ROLE
    DEFAULT_WAREHOUSE = COMPUTE_WH
    COMMENT = 'WI-22: FlakeBench interactive-analytics benchmark harness';

-- Set/rotate the public key (idempotent, safe to re-run)
ALTER USER IA_BENCH_SVC SET RSA_PUBLIC_KEY = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoer4+TM/itBWfvO22A4yw8ISf3nuj+aHI5UplCvJ5WtYufHv6eKFMUM4GqoB07MMDXgAScsAUVPwqrJTYqEFJhQZggjUBu5LIWNYPR9voN2EX9hM0HmctNqfYS4XwIZYvzrW+JmljMPbEPPxXwiiDyFHA1qyUPBrFbGThr+1v3to3FBWAoAjZ9hvS2xHzmsFtDstFKdk9nXtM8mBg40g+PYYefwIm+e4LwheC14dJ6sSQ8C0EhyQdJaCObPH87XY+w+fay45nurVOddPUJ0Vx2oKZ4nPlZYZMLSLLAJF0IBWPJD/n950PfUwcgt4H/ntcDOj8bDkmytwux9ybDTRRwIDAQAB';

GRANT ROLE FLAKEBENCH_ROLE TO USER IA_BENCH_SVC;

-- Verify
DESC USER IA_BENCH_SVC;
SHOW GRANTS TO USER IA_BENCH_SVC;
