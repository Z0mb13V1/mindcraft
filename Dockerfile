FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    # git \
    # unzip \
    python3 \
    python3-pip \
    # tmux \
    xvfb \
    xauth \
    libgl1-mesa-dev \
    libgles2-mesa-dev \
    libosmesa6-dev \
    build-essential \
    libcairo2-dev \
    libpango1.0-dev \
    libjpeg-dev \
    libgif-dev \
    librsvg2-dev \
    libxi-dev \
    libxinerama-dev \
    libxrandr-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy package files first for better caching
COPY package*.json ./
RUN npm install

# Copy requirements and install Python deps
COPY requirements.txt ./
RUN pip3 install --no-cache-dir --break-system-packages -r requirements.txt

# Copy source code
COPY . .

# Run tests during build
RUN npm test

# Create non-root user for runtime security
RUN groupadd --gid 1001 mindcraft && \
    useradd --uid 1001 --gid mindcraft --shell /bin/bash --create-home mindcraft && \
    chown -R mindcraft:mindcraft /app

USER mindcraft

CMD ["npm", "start"]