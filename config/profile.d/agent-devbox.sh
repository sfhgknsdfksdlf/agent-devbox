# Load the shared agent-devbox environment for Bash login shells (Docker and WSL).
# agent-env.sh uses Bash arrays; POSIX sh (dash) must skip it or the OpenCode
# Desktop `sh -lc` probe aborts before it can print the CLI path.
if [ -n "${BASH_VERSION:-}" ] && [ -r /usr/local/bin/agent-env.sh ]; then
  # shellcheck source=/dev/null
  . /usr/local/bin/agent-env.sh
fi
