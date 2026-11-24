# Export the per-UID memory service endpoint/key for interactive login shells.
# The service is started by the boot scripts; this only reads its published
# state and never starts anything. Must never abort the login shell.
if [ -r /usr/local/bin/memory-env.sh ]; then
  # shellcheck source=/dev/null
  . /usr/local/bin/memory-env.sh
fi

return 0
