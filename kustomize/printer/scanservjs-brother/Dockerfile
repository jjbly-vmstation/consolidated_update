# scanservjs + Brother brscan4 SANE backend, for the MFC-9130CW.
#
# Why this exists: scanservjs's stock image only ships the generic SANE
# `net` backend (SANED_NET_HOSTS env var), which talks to a remote `saned`
# daemon. Brother printers don't run saned - they speak their own network
# scan protocol, which needs Brother's proprietary `brscan4` SANE backend.
# Without it `scanimage -L` finds nothing, no matter what IP you point at.
#
# You must supply the actual brscan4 .deb download URL yourself - grab it
# from Brother's official Linux driver page for this model:
#   https://support.brother.com/g/b/downloadtop.aspx?c=us&lang=en&prod=mfc9130cw_us
# -> Linux (deb) -> "Driver Install Tool" or the standalone brscan4 package.
# The URL is per-file and not guessable/stable, so it's not hardcoded here.
#
# Build (see ../README_BROTHER_SCAN.md for full instructions):
#   nerdctl --namespace k8s.io build \
#     --build-arg BROTHER_BRSCAN4_URL="<url from Brother's site>" \
#     -t localhost/scanservjs-brother:latest .

FROM sbs20/scanservjs:latest

ARG BROTHER_BRSCAN4_URL
ARG SCANNER_NAME=BrotherMFC9130CW
ARG SCANNER_MODEL=MFC-9130CW
ARG SCANNER_IP=192.168.4.72

RUN if [ -z "$BROTHER_BRSCAN4_URL" ]; then \
      echo "ERROR: --build-arg BROTHER_BRSCAN4_URL=<url> is required" >&2; \
      exit 1; \
    fi

RUN apt-get update && \
    apt-get install -y --no-install-recommends wget ca-certificates && \
    wget -O /tmp/brscan4.deb "$BROTHER_BRSCAN4_URL" && \
    (dpkg -i /tmp/brscan4.deb || apt-get install -f -y) && \
    rm -f /tmp/brscan4.deb && \
    apt-get purge -y wget && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

# Register the network scanner at build time - IP is static (see
# kustomize/printer/deployment-scanservjs.yaml), no runtime config needed.
RUN brsaneconfig4 -a name="${SCANNER_NAME}" model="${SCANNER_MODEL}" ip="${SCANNER_IP}"

# Sanity check the registration landed (fails the build loudly instead of
# silently producing an image that still finds "No devices found").
RUN brsaneconfig4 -q | grep -q "${SCANNER_NAME}"

ENTRYPOINT ["/entrypoint.sh"]
