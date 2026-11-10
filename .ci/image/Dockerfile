# CI image for the GitLab pipeline.
#
# Every GitLab job runs in this image. It holds what .ci/scripts/tf.sh needs:
#   - bash, ca-certificates and git (for git-sourced modules, if you add any)
#   - OpenTofu (tofu), pinned to the same version as
#     .github/actions/setup-tools/action.yml and TF_IMAGE in
#     .ci/templates/tf-templates.yml
#   - mikefarah yq v4 (tf.sh reads the deployment configs with it)
#   - the AWS CLI v2 and jq (the identity check and its JWT claim decode)
#   - shellcheck (the validate job lints .ci/scripts/*.sh)
#
# Build it for the runner's CPU type (amd64 or arm64) and push it to the
# registry that TF_IMAGE in .ci/templates/tf-templates.yml points at.
# See "CI image" in README.md.
#
# Each download is pinned to a SHA256 hash. To change a version, update the
# version ARG and both of its hash ARGs. The hashes come from:
#   - OpenTofu: the linux_amd64.zip and linux_arm64.zip lines of
#     https://github.com/opentofu/opentofu/releases/download/v<version>/tofu_<version>_SHA256SUMS
#   - yq: the "SHA256" lines of checksums-bsd on the GitHub release
#   - AWS CLI: run sha256sum on the downloaded zip
#     (https://awscli.amazonaws.com/awscli-exe-linux-<x86_64|aarch64>-<version>.zip)
#
# The image has no ENTRYPOINT. GitLab runs each job's script with the image's
# shell, so an ENTRYPOINT such as `tofu` would break every job.

FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad

ARG TOFU_VERSION=1.13.1
ARG TOFU_SHA256_AMD64=8ccbc6f8ee21d2827715f3c6e08a9b3e0209b1e62057c05067ef117e047c1a80
ARG TOFU_SHA256_ARM64=b9614df40575cc3fc10a8a25025b7245d961da279f715ea3efff4ddae8e6938a

ARG YQ_VERSION=4.54.1
ARG YQ_SHA256_AMD64=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f
ARG YQ_SHA256_ARM64=189088da0c6429ec5178dfaab1a114805f6cab0b61b165ab236efedf1d57a71b

ARG AWSCLI_VERSION=2.38.6
ARG AWSCLI_SHA256_AMD64=66974301c11f8116a6cb96bf72acae57453734b61fa8dd3f56422de9eaab0e42
ARG AWSCLI_SHA256_ARM64=a9f355189a5a25834c015fc07d65e1834f0dbbee1d9bd1c418176f43a463067f

# Set by `docker build` / `docker buildx build` from the target platform.
ARG TARGETARCH

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Debian packages are not pinned to versions. The base image digest already
# fixes the Debian release, and old package versions leave the mirrors, which
# would break later builds.
# hadolint ignore=DL3008
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    shellcheck \
    unzip \
  && rm -rf /var/lib/apt/lists/*

# Download, check the hash, install. TARGETARCH picks the hash for this build.
# The downloads go to a temporary folder that this same step deletes, so `cd`
# is used instead of WORKDIR.
# hadolint ignore=DL3003
RUN case "${TARGETARCH:-amd64}" in \
      amd64) tofu_sha="$TOFU_SHA256_AMD64"; yq_sha="$YQ_SHA256_AMD64"; aws_arch=x86_64;  aws_sha="$AWSCLI_SHA256_AMD64" ;; \
      arm64) tofu_sha="$TOFU_SHA256_ARM64"; yq_sha="$YQ_SHA256_ARM64"; aws_arch=aarch64; aws_sha="$AWSCLI_SHA256_ARM64" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}. Use amd64 or arm64." >&2; exit 1 ;; \
    esac \
  && arch="${TARGETARCH:-amd64}" \
  && tmp="$(mktemp -d)" && cd "$tmp" \
  \
  && curl -fsSLo tofu.zip "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${arch}.zip" \
  && echo "${tofu_sha}  tofu.zip" | sha256sum -c - \
  && unzip -q tofu.zip tofu -d /usr/local/bin \
  \
  && curl -fsSLo yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${arch}" \
  && echo "${yq_sha}  yq" | sha256sum -c - \
  && install -m 0755 yq /usr/local/bin/yq \
  \
  && curl -fsSLo awscli.zip "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}-${AWSCLI_VERSION}.zip" \
  && echo "${aws_sha}  awscli.zip" | sha256sum -c - \
  && unzip -q awscli.zip \
  && ./aws/install \
  \
  && cd / && rm -rf "$tmp" \
  && tofu version \
  && yq --version \
  && aws --version

# Plain-text output in CI logs, and no prompts.
ENV TF_IN_AUTOMATION=true \
    AWS_PAGER=""

CMD ["bash"]
