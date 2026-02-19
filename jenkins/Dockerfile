FROM jenkins/jenkins:lts-jdk21

USER root

# ---- Install system dependencies ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    python3 \
    python3-pip \
    python3-venv \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# ---- Install Docker CLI ----
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
       https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# ---- Install kubectl ----
RUN curl -fsSL "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

# ---- Install ArgoCD CLI ----
RUN curl -fsSL https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 \
    -o /usr/local/bin/argocd \
    && chmod +x /usr/local/bin/argocd

# ---- Install Node.js 22 ----
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ---- Install GitHub CLI ----
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
       https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ---- Allow jenkins user to run docker and kubectl ----
RUN usermod -aG docker jenkins \
    && echo "jenkins ALL=(ALL) NOPASSWD: /usr/sbin/tee -a /etc/hosts" >> /etc/sudoers

USER jenkins

# Install recommended Jenkins plugins
RUN jenkins-plugin-cli --plugins \
    git \
    github \
    pipeline-multibranch-defaults \
    workflow-aggregator \
    credentials-binding \
    blueocean \
    docker-workflow \
    kubernetes-cli \
    ansicolor
