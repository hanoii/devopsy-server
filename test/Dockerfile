# A server for test/run.sh: the distribution's image with systemd as its
# first process, as a cloud server boots, and systemd-resolved, which
# cloud images run and Docker's images lack.
ARG BASE=debian:trixie
FROM ${BASE}
RUN apt-get update -q \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
    systemd systemd-sysv systemd-resolved iproute2 ca-certificates \
  && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
