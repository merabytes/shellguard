FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    libpam-runtime \
    netcat-openbsd \
    curl \
    ca-certificates \
    python3 \
    nodejs \
    sshpass \
    && rm -rf /var/lib/apt/lists/*

# Test user
RUN useradd -m -s /bin/bash testuser && \
    echo "testuser:testpass" | chpasswd && \
    mkdir -p /run/sshd

# sshd config
RUN sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "UsePAM yes" >> /etc/ssh/sshd_config

# Install shellguard .deb (built before docker build)
ARG SHELLGUARD_VERSION=2.2.3
COPY dist/shellguard_${SHELLGUARD_VERSION}_all.deb /tmp/shellguard.deb
RUN dpkg -i /tmp/shellguard.deb && rm /tmp/shellguard.deb

# E2E config (tokens injected via ENV at runtime)
COPY config/shellguard.conf.e2e /etc/shellguard/shellguard.conf

# PAM hook for SSH specifically
RUN echo "session optional pam_exec.so /usr/lib/shellguard/pam_hook.sh" \
    >> /etc/pam.d/sshd

# Vulnerable servers
COPY tests/e2e/vuln_server_python.py /opt/vuln_server_python.py
COPY tests/e2e/vuln_server_node.js   /opt/vuln_server_node.js

EXPOSE 22 7070 7071

COPY tests/e2e/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
