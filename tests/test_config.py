# tests/test_config.py
# Automated tests for Rhizo configuration and rhizo.toml parsing.

import subprocess
import tempfile
import json
import os
from pathlib import Path

RHIZO_BIN = Path(__file__).parent.parent / "bin" / "rhizo"

def run_rhizo(*args, cwd=None, env=None):
    cmd = [str(RHIZO_BIN)] + list(args)
    run_env = os.environ.copy()
    for k in list(run_env.keys()):
        if k.startswith("RHIZO_"):
            del run_env[k]
    if env:
        run_env.update(env)
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, env=run_env)
    return proc.returncode, proc.stdout, proc.stderr

def test_config_defaults():
    with tempfile.TemporaryDirectory() as tmpdir:
        # Isolate from user's global ~/.config/rhizo/config.toml
        code, out, err = run_rhizo("config", "show", "--format", "json", cwd=tmpdir, env={"XDG_CONFIG_HOME": tmpdir, "HOME": tmpdir})
        assert code == 0, f"Error: {err}"
        data = json.loads(out)
        assert data["redis_url"]["value"] == "redis://127.0.0.1:6379"
        assert data["prefix"]["value"] == "rhizo:"
        assert data["heartbeat_ttl"]["value"] == "150"
        assert data["listen_timeout"]["value"] == "0"
        assert data["message_ttl"]["value"] == "604800"

def test_config_reads_rhizo_toml():
    with tempfile.TemporaryDirectory() as tmpdir:
        toml_path = Path(tmpdir) / "rhizo.toml"
        toml_content = """# rhizo.toml - Custom Project Configuration
redis_url = "redis://redis.internal:6379"
prefix = "mycustom:"
project = "custom-project"
encrypt = true
heartbeat_ttl = 120

[profiles.staging]
redis_url = "rediss://staging.internal:6380"
prefix = "stg:rhizo:"
"""
        toml_path.write_text(toml_content)

        # Default profile from toml
        code, out, err = run_rhizo("config", "show", "--config", str(toml_path), "--format", "json")
        assert code == 0, f"Error: {err}"
        data = json.loads(out)
        
        assert data["redis_url"]["value"] == "redis://redis.internal:6379"
        assert data["prefix"]["value"] == "mycustom:"
        assert data["project"]["value"] == "custom-project"
        assert data["encrypt"]["value"] == "true"
        assert data["heartbeat_ttl"]["value"] == "120"

        # Staging profile from toml
        code2, out2, err2 = run_rhizo("config", "show", "--config", str(toml_path), "--profile", "staging", "--format", "json")
        assert code2 == 0, f"Error: {err2}"
        data2 = json.loads(out2)
        assert data2["redis_url"]["value"] == "rediss://staging.internal:6380"
        assert data2["prefix"]["value"] == "stg:rhizo:"

def test_config_cli_overrides():
    code, out, err = run_rhizo(
        "config", "show",
        "--redis-url", "redis://cli-override:6379",
        "--prefix", "cli:",
        "--project", "test-project",
        "--format", "json"
    )
    assert code == 0, f"Error: {err}"
    data = json.loads(out)
    assert data["redis_url"]["value"] == "redis://cli-override:6379"
    assert data["prefix"]["value"] == "cli:"
    assert data["project"]["value"] == "test-project"
    assert data["redis_url"]["source"] == "cli flag"

def test_config_dotenv_loading():
    with tempfile.TemporaryDirectory() as tmpdir:
        dotenv_path = Path(tmpdir) / ".env"
        dotenv_path.write_text("""
RHIZO_PROJECT=dotenv-project
RHIZO_REDIS_URL="redis://dotenv.internal:6379"
export RHIZO_PREFIX="env_pfx:"
""")
        code, out, err = run_rhizo("config", "show", "--format", "json", cwd=tmpdir, env={"XDG_CONFIG_HOME": tmpdir, "HOME": tmpdir})
        assert code == 0, f"Error: {err}"
        data = json.loads(out)
        assert data["project"]["value"] == "dotenv-project"
        assert data["redis_url"]["value"] == "redis://dotenv.internal:6379"
        assert data["prefix"]["value"] == "env_pfx:"

def test_config_dotenv_local_overrides_dotenv():
    with tempfile.TemporaryDirectory() as tmpdir:
        dotenv_path = Path(tmpdir) / ".env"
        dotenv_path.write_text("""
RHIZO_PROJECT=base-project
RHIZO_REDIS_URL=redis://base.internal:6379
""")
        dotenv_local = Path(tmpdir) / ".env.local"
        dotenv_local.write_text("""
RHIZO_REDIS_URL=redis://local-override.internal:6379
""")
        code, out, err = run_rhizo("config", "show", "--format", "json", cwd=tmpdir, env={"XDG_CONFIG_HOME": tmpdir, "HOME": tmpdir})
        assert code == 0, f"Error: {err}"
        data = json.loads(out)
        assert data["project"]["value"] == "base-project"
        assert data["redis_url"]["value"] == "redis://local-override.internal:6379"

def test_config_process_env_overrides_dotenv():
    with tempfile.TemporaryDirectory() as tmpdir:
        dotenv_path = Path(tmpdir) / ".env"
        dotenv_path.write_text("""
RHIZO_PROJECT=dotenv-project
RHIZO_REDIS_URL=redis://dotenv:6379
""")
        code, out, err = run_rhizo("config", "show", "--format", "json", cwd=tmpdir, env={
            "XDG_CONFIG_HOME": tmpdir,
            "HOME": tmpdir,
            "RHIZO_PROJECT": "process-env-project"
        })
        assert code == 0, f"Error: {err}"
        data = json.loads(out)
        assert data["project"]["value"] == "process-env-project"
        assert data["redis_url"]["value"] == "redis://dotenv:6379"

def test_config_local_toml_layers_over_workspace_toml():
    with tempfile.TemporaryDirectory() as tmpdir:
        base_toml = Path(tmpdir) / ".rhizo.toml"
        base_toml.write_text("""
project = "base-team-project"
prefix = "team:"
encrypt = true
""")
        local_toml = Path(tmpdir) / ".rhizo.local.toml"
        local_toml.write_text("""
redis_url = "redis://my-dev-box:6379"
prefix = "my-dev:"
""")
        code, out, err = run_rhizo("config", "show", "--format", "json", cwd=tmpdir, env={"XDG_CONFIG_HOME": tmpdir, "HOME": tmpdir})
        assert code == 0, f"Error: {err}"
        data = json.loads(out)
        assert data["project"]["value"] == "base-team-project"
        assert data["encrypt"]["value"] == "true"
        assert data["project"]["source"] == "workspace config"
        assert data["redis_url"]["value"] == "redis://my-dev-box:6379"
        assert data["prefix"]["value"] == "my-dev:"
        assert data["redis_url"]["source"] == "local workspace config"

def test_config_prefixed_environment_variables():
    """Verify RHIZO_* prefixed environment variables take effect cleanly."""
    with tempfile.TemporaryDirectory() as tmpdir:
        # Test RHIZO_CONFIG pointing to custom path
        custom_cfg = Path(tmpdir) / "custom.toml"
        custom_cfg.write_text("""project = "custom-env-project"
prefix = "custom-env:"
""")
        code, out, err = run_rhizo("config", "show", "--format", "json", env={
            "RHIZO_CONFIG": str(custom_cfg),
            "RHIZO_REDIS_URL": "redis://rhizo-env-redis:6379",
            "RHIZO_HOSTNAME": "rhizo-test-host",
            "RHIZO_AGENT_NAME": "test-prefixed-agent",
        })
        assert code == 0, f"Error: {err}"
        data = json.loads(out)
        assert data["project"]["value"] == "custom-env-project"
        assert data["redis_url"]["value"] == "redis://rhizo-env-redis:6379"
        assert data["agent_name"]["value"] == "test-prefixed-agent"

