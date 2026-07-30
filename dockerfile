ARG IGNITION_VERSION
FROM inductiveautomation/ignition:${IGNITION_VERSION:-latest}

COPY --chown=ignition:ignition services /usr/local/bin/ignition/data