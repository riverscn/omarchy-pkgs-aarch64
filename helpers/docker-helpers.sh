# Docker helper functions for Omarchy package build system

check_docker() {
  if ! command -v docker &>/dev/null; then
    print_error "Docker is not installed"
    exit 1
  fi

  if ! docker info &>/dev/null; then
    print_error "Docker daemon is not running"
    print_warning "Start Docker with: sudo systemctl start docker"
    exit 1
  fi
}

setup_qemu() {
  # Setup QEMU for building ARM64 packages on x86_64 hosts
  if ! docker run --rm --privileged multiarch/qemu-user-static --reset -p yes --credential yes >/dev/null 2>&1; then
    print_error "Failed to setup QEMU for ARM64 emulation"
    exit 1
  fi
  print_success "QEMU ARM64 emulation enabled"
}

build_docker_image() {
  local build_dir="$1"
  local arch="${2:-x86_64}"
  local mirror="${3:-edge}"
  local platform=""
  local image_tag="omarchy-pkg-builder:latest-$arch-$mirror"

  
  case "$arch" in
    x86_64)  platform="linux/amd64" ;;
    aarch64) platform="linux/arm64" ;;
    *)
      print_error "Unsupported architecture: $arch"
      exit 1
      ;;
  esac
  
  print_info "Building Docker image for $arch ($platform) using $mirror mirror..."
  
  docker buildx build \
    --platform "$platform" \
    --build-arg MIRROR="$mirror" \
    --load \
    -t "$image_tag" \
    -f "$build_dir/Dockerfile" \
    "$build_dir"
}

get_platform_arg() {
  local arch="$1"
  case "$arch" in
    x86_64)  echo "--platform linux/amd64" ;;
    aarch64) echo "--platform linux/arm64" ;;
    *)       echo "" ;;
  esac
}

make_dir_writable() {
  local dir="$1"

  # Bind mounts retain host ownership, while the image deliberately runs as an
  # unprivileged builder user. It only needs to create, replace, and unlink
  # entries in this output directory; changing package-file ownership or modes
  # is both unnecessary and can fail with user-namespaced Docker.
  if ! chmod a+rwx "$dir" 2>/dev/null; then
    sudo chmod a+rwx "$dir"
  fi
}
