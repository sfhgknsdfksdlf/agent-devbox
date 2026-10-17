# Load the shared agent-devbox environment for every login shell (Docker and WSL).
if [ -r /usr/local/bin/agent-env.sh ]; then
  . /usr/local/bin/agent-env.sh
fi
