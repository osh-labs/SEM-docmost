# Review 3: dependency audit and test run

Target: `bbik52/docmost-mcp-remote` at a5e3624 ("Release 1.2.3"), version 1.2.3 per pyproject.toml.
Working copy: `<scratch>/audit/docmost-mcp-remote` (copied with `cp -r` from the clone; the working tree is unchanged after the run, `git status` clean).
Date: 2026-11-09. Interpreter: CPython 3.13.18 (project requires >=3.12). uv 0.11.32. pip-audit 2.10.1.

## Summary

- Lockfile is consistent (`--locked` export and sync both succeeded). 84 runtime packages, 115 including dev.
- pip-audit: no known vulnerabilities, for both the PyPI advisory service and OSV, for runtime deps and for runtime+dev deps.
- Unit tests: 363 passed, 0 failed, 0 skipped with a local Postgres 16. Without Postgres: 159 passed, 204 skipped.
- Integration tests (29 collected): not run; Docker daemon unavailable.
- ruff check: clean. ruff format --check: clean. mypy (strict) on src: clean; on src+tests: clean.
- Import footprint of `docmost_mcp_remote.server`: about 113 MiB max RSS, about 1.6 s wall, 1267 modules loaded.
- No blockers to adoption came out of this step.

## Commands run

All from the working copy unless noted.

```
cp -r scratchpad/ext/bbik52_docmost-mcp-remote scratchpad/audit/docmost-mcp-remote
uv export --locked --no-dev --no-emit-project --format requirements-txt -o ../reqs-runtime.txt
uv export --locked --no-emit-project --format requirements-txt -o ../reqs-all.txt
python3 -m venv ../auditvenv && ../auditvenv/bin/pip install pip-audit
../auditvenv/bin/pip-audit -r ../reqs-runtime.txt --disable-pip --require-hashes            # PyPI service
../auditvenv/bin/pip-audit -r ../reqs-runtime.txt --disable-pip --require-hashes -s osv     # OSV
../auditvenv/bin/pip-audit -r ../reqs-all.txt     --disable-pip --require-hashes -s osv     # runtime + dev
uv sync --locked                                   # includes dev group
pg_ctlcluster 16 main start; psql: CREATE USER test ... SUPERUSER; CREATE DATABASE test OWNER test
DATABASE_TEST_URL=postgresql://test:test@localhost:5432/test uv run pytest -q tests --ignore=tests/integration
uv run pytest -q tests --ignore=tests/integration          # without DB, for skip count
uv run pytest --collect-only -q tests/integration
docker info
uv run ruff check; uv run ruff format --check
uv run mypy src; uv run mypy
python3 -I -c '<subprocess.run([".venv/bin/python","-c","import docmost_mcp_remote.server"]) + getrusage(RUSAGE_CHILDREN)>'
pg_ctlcluster 16 main stop
```

Notes on commands:
- The first export (as given in the task, without `--no-emit-project`) includes the project itself as an editable `-e .` line; pip-audit then refuses it under hash mode ("editable requirement ... cannot be installed when requiring hashes"). Re-exported with `--no-emit-project`, and used `--disable-pip --require-hashes` since the export is fully pinned and hashed.
- The first `uv sync --locked` in the foreground hit a 500 s timeout while downloading through the proxy; a re-run in the background completed with rc=0. No TLS or 403 errors.
- `/usr/bin/time` is not installed and `apt-get install time` failed (apt not reachable in the time allowed), so max RSS was measured with `resource.getrusage(RUSAGE_CHILDREN).ru_maxrss` from a parent Python process. This reports the same quantity as `time -v` "Maximum resident set size".
- Postgres 16 was already installed (cluster down); started it, ran the tests, stopped it again.

## Locked versions (from uv.lock)

| Package | Locked version | pyproject constraint |
|---|---|---|
| fastmcp | 4.1.3 | >=4.1.3,<5 |
| mcp | 2.3.0 | transitive (via fastmcp) |
| starlette | 1.10.0 | transitive |
| uvicorn | 0.54.0 | uvicorn[standard]>=0.54,<1 |
| httpx | 0.28.1 | >=0.28,<1 |
| cryptography | 50.0.2 | >=50,<51 |
| jinja2 | 3.1.6 | >=3.1.6,<4 |
| sqlalchemy | 2.1.6 | sqlalchemy[asyncio]>=2.1,<2.2 |
| asyncpg | 0.32.0 | >=0.32,<1 |
| python-multipart | 0.0.32 | >=0.0.32,<1 |
| itsdangerous | 2.2.0 | >=2.2,<3 |

Other direct deps: alembic 1.20.1, pydantic-settings 2.16.1. Notable transitives: authlib 1.9.1, pyjwt 2.15.1, joserfc 1.7.7, pydantic 2.14.1, h11 0.16.0, httpcore 1.0.9, sse-starlette 3.5.1, websockets 17.3, mako 1.4.3, markupsafe 3.0.4, keyring 25.7.0. fastmcp also pulls httpx2 2.16.0 / httpcore2 2.16.0 / httpx2-jsfetch 1.0 alongside httpx 0.28.1 (two HTTP client stacks in the tree). pywin32 / pywin32-ctypes appear with Windows-only markers and are not installed on Linux.

## Advisories

| Package | Version | Advisory ID | Severity | Fixed in |
|---|---|---|---|---|
| (none) | - | - | - | - |

pip-audit reported "No known vulnerabilities found" against both the PyPI JSON advisory service and OSV, for the 84 runtime packages and for all 115 locked packages including dev tools. No high or critical advisories apply to the locked set as of 2026-11-09.

## Tests

### Unit tests (`tests`, excluding `tests/integration`)

| Configuration | Passed | Failed | Skipped | Time |
|---|---|---|---|---|
| With Postgres 16 (`DATABASE_TEST_URL=postgresql://test:test@localhost:5432/test`) | 363 | 0 | 0 | 106 s |
| Without Postgres | 159 | 0 | 204 | 3.5 s |

The DB-backed tests read `DATABASE_TEST_URL` (tests/conftest.py); the `migrated_database` fixture drops and recreates the `public` schema and runs the Alembic migrations, so it must point at a disposable database. No failures, no tracebacks.

### Integration tests (`tests/integration`, 29 collected)

Not run. They need a running Docmost (`DOCMOST_TEST_URL`, provisioned via `tests/integration/compose.yaml`). The Docker CLI is installed (29.9.2) but `docker info` cannot reach a daemon (`/var/run/docker.sock` does not exist), so the compose stack cannot be started here. Without `DOCMOST_TEST_URL` the integration conftest marks every test skipped.

### Static checks

| Check | Result |
|---|---|
| `uv run ruff check` | All checks passed |
| `uv run ruff format --check` | 129 files already formatted |
| `uv run mypy src` (strict, pydantic plugin) | Success: no issues in 61 source files |
| `uv run mypy` (configured files: src + tests) | Success: no issues in 112 source files |

## Memory footprint (import only, no server started)

| Command | Max RSS | Wall time |
|---|---|---|
| `.venv/bin/python -c "import docmost_mcp_remote.server"` (3 runs) | 112.8 to 113.0 MiB | 1.5 to 1.7 s |
| `.venv/bin/python -c "import sys"` baseline | 12.9 MiB | 0.02 s |

Importing the server module loads 1267 modules. A running instance will use more (uvicorn workers, DB pool, request buffers); this number is a floor.

## Blockers and caveats

- Integration tests not executed (no Docker daemon). Coverage of real Docmost interaction is unverified by this step.
- Tests ran on Python 3.13 only; the project also claims 3.12 support.
- The advisory result is a point-in-time check; the lock pins exact versions, so later advisories will require a lock refresh.
