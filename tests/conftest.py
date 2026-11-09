import os

# Critical test isolation: ensure tests run in an Antigravity shell never spawn
# live background daemons against the host developer session.
os.environ.setdefault("RHIZO_EAR_DISABLED", "1")
