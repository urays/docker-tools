FROM nvidia/cuda:13.1.1-cudnn-devel-ubuntu22.04
LABEL maintainer="urays.cc@foxmail.com"

# CUDA environment variables
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=${CUDA_HOME}/bin:${PATH}
ENV LD_LIBRARY_PATH=${CUDA_HOME}/lib64:${LD_LIBRARY_PATH}

# Set locale
RUN apt-get update && apt-get install -y --no-install-recommends locales && \
    locale-gen en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8 && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Update apt sources (combined official + aliyun mirrors)
RUN echo "deb http://archive.ubuntu.com/ubuntu/ jammy-updates multiverse\n\
deb http://archive.ubuntu.com/ubuntu/ jammy-backports main restricted universe multiverse\n\
deb http://security.ubuntu.com/ubuntu/ jammy-security main restricted\n\
deb http://security.ubuntu.com/ubuntu/ jammy-security universe\n\
deb http://security.ubuntu.com/ubuntu/ jammy-security multiverse\n\
\n\
deb http://mirrors.aliyun.com/ubuntu/ jammy main restricted universe multiverse\n\
deb-src http://mirrors.aliyun.com/ubuntu/ jammy main restricted universe multiverse\n\
deb http://mirrors.aliyun.com/ubuntu/ jammy-security main restricted universe multiverse\n\
deb-src http://mirrors.aliyun.com/ubuntu/ jammy-security main restricted universe multiverse\n\
deb http://mirrors.aliyun.com/ubuntu/ jammy-updates main restricted universe multiverse\n\
deb-src http://mirrors.aliyun.com/ubuntu/ jammy-updates main restricted universe multiverse\n\
deb http://mirrors.aliyun.com/ubuntu/ jammy-backports main restricted universe multiverse\n\
deb-src http://mirrors.aliyun.com/ubuntu/ jammy-backports main restricted universe multiverse" > /etc/apt/sources.list

# Install prerequisite packages first
RUN apt-get update && apt-get install -y --no-install-recommends \
    sudo \
    apt-transport-https \
    wget \
    ca-certificates \
    gnupg \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Add LLVM sources (using gpg --dearmor instead of deprecated apt-key)
RUN wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | \
    gpg --dearmor -o /usr/share/keyrings/llvm-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/llvm-archive-keyring.gpg] https://mirrors.tuna.tsinghua.edu.cn/llvm-apt/$(lsb_release -sc)/ llvm-toolchain-$(lsb_release -sc)-21 main" \
    > /etc/apt/sources.list.d/llvm-apt.list

# Install basic tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    lsb-core \
    unzip \
    pkg-config \
    parallel \
    poppler-utils \
    qpdf \
    vim \
    && rm -rf /var/lib/apt/lists/*

# Install build tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    make \
    cmake \
    ninja-build \
    ccache \
    gcc \
    g++ \
    gdb \
    flex \
    bison \
    && rm -rf /var/lib/apt/lists/*

# Install LLVM/Clang toolchain
RUN apt-get update && apt-get install -y --no-install-recommends \
    clang \
    clangd \
    lldb \
    lld \
    clang-format \
    clang-tidy \
    && rm -rf /var/lib/apt/lists/*

# Install math libraries
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas-dev \
    libomp-dev \
    libgmp-dev \
    && rm -rf /var/lib/apt/lists/*

# Install development libraries
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl-dev \
    libcurl4-openssl-dev \
    libtinfo-dev \
    libz-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Install documentation tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    doxygen \
    graphviz \
    texinfo \
    && rm -rf /var/lib/apt/lists/*

# Install additional tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    z3 \
    libz3-dev \
    qtwayland5 \
    && rm -rf /var/lib/apt/lists/*

# System upgrade and cleanup
RUN apt-get update && apt-get upgrade -y && \
    apt-get clean && apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

# Check if nvcc exists in PATH
RUN echo "Verifying CUDA installation..." && \
    nvcc --version && \
    echo "CUDA verification completed successfully."

# Install Miniforge (uses conda-forge, no TOS required)
RUN cd /tmp && \
    wget -q https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh && \
    chmod +x Miniforge3-Linux-x86_64.sh && \
    ./Miniforge3-Linux-x86_64.sh -b -p /opt/conda && \
    /opt/conda/bin/conda update -y --all && \
    /opt/conda/bin/conda clean -ya && \
    /opt/conda/bin/conda install conda-build -y && \
    /opt/conda/bin/conda clean -ya && \
    chmod -R a+w /opt/conda/ && \
    rm -f Miniforge3-Linux-x86_64.sh

ENV PATH=/opt/conda/bin:${PATH}

# Configure conda channels (using conda-forge as primary)
RUN echo -e "channels:\n\
  - conda-forge\n\
  - defaults\n\
show_channel_urls: true\n\
auto_activate_base: false" > /opt/conda/.condarc

# Initialize conda for bash (global)
RUN /opt/conda/bin/conda init bash

# Create tens conda environment with Python 3.12
RUN /opt/conda/bin/conda create -n tens python=3.12 -y -c conda-forge && \
    /opt/conda/bin/conda clean -ya

# Install libstdcxx-ng to fix GLIBCXX_3.4.30 issue
RUN /opt/conda/bin/conda install -n tens -y libstdcxx-ng -c conda-forge && \
    /opt/conda/bin/conda clean -ya

# Copy and install Python packages from requirements.txt (if exists)
# Note: Create an empty file if requirements.txt doesn't exist in scripts/
COPY requirements.tx[t] /tmp/
RUN if [ -f /tmp/requirements.txt ]; then \
        /bin/bash -c "source /opt/conda/bin/activate tens && \
        pip install --no-cache-dir -r /tmp/requirements.txt" && \
        rm -f /tmp/requirements.txt; \
    fi

# User setup - using build args for flexibility
ARG USERNAME=urays
ARG USER_UID=42752
ARG USER_GID=42752

RUN groupadd --gid ${USER_GID} ${USERNAME} || true && \
    useradd --uid ${USER_UID} --gid ${USER_GID} -m ${USERNAME} && \
    echo "${USERNAME} ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} && \
    chmod 0440 /etc/sudoers.d/${USERNAME}

# Copy conda configuration to user home
RUN cp /opt/conda/.condarc /home/${USERNAME}/.condarc && \
    chown ${USER_UID}:${USER_GID} /home/${USERNAME}/.condarc

RUN su - ${USERNAME} -c "/opt/conda/bin/conda init bash" && \
    chown ${USER_UID}:${USER_GID} /home/${USERNAME}/.bashrc

# Create .bash_profile to source .bashrc (needed for login shell)
RUN echo 'if [ -f ~/.bashrc ]; then . ~/.bashrc; fi' > /home/${USERNAME}/.bash_profile && \
    chown ${USER_UID}:${USER_GID} /home/${USERNAME}/.bash_profile

# ============================================================================
# Custom Shell Prompt Configuration
RUN cat >> /home/${USERNAME}/.bashrc << 'BASHRC_EOF'

# Git branch function
parse_git_branch() {
    git branch 2>/dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/ (\1)/'
}

# Git status indicators
parse_git_status() {
    local status=""
    local git_status=$(git status --porcelain 2>/dev/null)
    if [[ -n "$git_status" ]]; then
        if echo "$git_status" | grep -q "^??"; then
            status+="?"  # Untracked files
        fi
        if echo "$git_status" | grep -q "^ M\|^M \|^MM"; then
            status+="*"  # Modified files
        fi
        if echo "$git_status" | grep -q "^A \|^AM"; then
            status+="+"  # Staged files
        fi
    fi
    [[ -n "$status" ]] && echo " $status"
}

# Conda environment indicator
get_conda_env() {
    if [[ -n "$CONDA_DEFAULT_ENV" ]]; then
        echo "$CONDA_DEFAULT_ENV"
    fi
}

# Disable conda's default prompt modification (we handle it ourselves)
conda config --set changeps1 False 2>/dev/null || true

# Color definitions
C_RESET='\[\e[0m\]'
C_BOLD='\[\e[1m\]'
C_RED='\[\e[0;31m\]'
C_GREEN='\[\e[0;32m\]'
C_YELLOW='\[\e[0;33m\]'
C_BLUE='\[\e[0;34m\]'
C_PURPLE='\[\e[0;35m\]'
C_CYAN='\[\e[0;36m\]'
C_WHITE='\[\e[0;37m\]'
C_BOLD_RED='\[\e[1;31m\]'
C_BOLD_GREEN='\[\e[1;32m\]'
C_BOLD_YELLOW='\[\e[1;33m\]'
C_BOLD_BLUE='\[\e[1;34m\]'
C_BOLD_PURPLE='\[\e[1;35m\]'
C_BOLD_CYAN='\[\e[1;36m\]'
C_BG_PURPLE='\[\e[45m\]'
C_ORANGE='\[\e[38;5;208m\]'
C_BOLD_ORANGE='\[\e[1;38;5;208m\]'

# Build prompt function
set_prompt() {
    local last_exit=$?
    
    # Docker tag
    PS1=""

    if [[ $last_exit -eq 0 ]]; then
        PS1+="${C_BOLD_GREEN}[✓]${C_RESET} "
    else
        PS1+="${C_BOLD_RED}[✗]${C_RESET} "
    fi

    # Conda env
    local conda_env=$(get_conda_env)
    if [[ -n "$conda_env" ]]; then
        PS1+="(${C_BOLD_YELLOW}${conda_env}${C_RESET})"
    fi
    
    # User@host
    PS1+="${C_BOLD_ORANGE}\u${C_RESET}"
    PS1+="${C_WHITE}@${C_RESET}"
    PS1+="${C_BOLD_CYAN}\h${C_RESET}:"
    
    # Path
    PS1+="${C_BLUE}\w${C_RESET}"
    
    # Git info
    PS1+="${C_BOLD_PURPLE}\$(parse_git_branch)${C_RESET}"
    PS1+="${C_BOLD_RED}\$(parse_git_status)${C_RESET}"

    PS1+="${C_WHITE}\$${C_RESET} "
}

PROMPT_COMMAND=set_prompt

# Useful Aliases
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# Directory navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# Git aliases
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline -10'
alias gd='git diff'
alias gco='git checkout'
alias gb='git branch'

# Safety aliases
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Quick conda activation
alias tens='conda activate tens'

# Show GPU status
alias gpustat='nvidia-smi'
alias gpuwatch='watch -n 1 nvidia-smi'

BASHRC_EOF

# Fix ownership of .bashrc
RUN chown ${USER_UID}:${USER_GID} /home/${USERNAME}/.bashrc
# ============================================================================

# Set default user (optional, can be overridden by docker run --user)
USER ${USERNAME}
WORKDIR /home/${USERNAME}

ENTRYPOINT [ "/bin/bash", "-l"]