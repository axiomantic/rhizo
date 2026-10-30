import? 'justfile.local'

default:
    @just --list

# 1. Dependency Setup
setup:
    nimble install --depsOnly -y

# 2. Test Suite Execution
test:
    @just test-nim
    @just test-py

test-nim:
    nimble test

test-py:
    uv run pytest

# 3. Linter Execution
lint:
    python scripts/compile_rules.py --check
    nimble check

# 4. Formatter Execution
fmt:
    python scripts/compile_rules.py

# 5. Build Artifacts
build:
    mkdir -p bin && nimble build -y -d:release

# 8. Clean Build Artifacts
clean:
    rm -rf nimcache htmldocs site docs/dist docs/.astro tools/docgen dist .venv
    find . -name '*.exe' -delete

# 9. Secret Scanning
check-secrets:
    @if command -v gitleaks >/dev/null 2>&1; then \
        gitleaks detect -v; \
    elif command -v pre-commit >/dev/null 2>&1; then \
        pre-commit run gitleaks --all-files; \
    else \
        echo "Error: neither gitleaks nor pre-commit found. Install gitleaks or pre-commit." >&2; exit 1; \
    fi

# 10. Upstream Template Synchronization
update-template:
    uvx copier update --trust
