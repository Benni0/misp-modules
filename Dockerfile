# Base image with python3.9 and enabled powertools and epel repo
ARG BASE_IMAGE=quay.io/centos/centos:stream8
FROM $BASE_IMAGE as base

COPY misp-enable-epel.sh /usr/bin/
RUN echo "tsflags=nodocs" >> /etc/yum.conf && \
    dnf update -y --setopt=install_weak_deps=False && \
    dnf install -y python39 && \
    alternatives --set python3 /usr/bin/python3.9 && \
    bash /usr/bin/misp-enable-epel.sh && \
    sed -i -e 's/enabled=0/enabled=1/' /etc/yum.repos.d/CentOS-Stream-PowerTools.repo && \
    rm -rf /var/cache/dnf

# Build stage that will build required python modules
FROM base as python-build
RUN dnf install -y --setopt=install_weak_deps=False python39-devel python39-wheel gcc gcc-c++ git-core poppler-cpp-devel && \
    rm -rf /var/cache/dnf
ARG MISP_MODULES_VERSION=main
RUN --mount=type=tmpfs,target=/tmp mkdir /tmp/source && \
    cd /tmp/source && \
    git config --system http.sslVersion tlsv1.3 && \
    COMMIT=$(git ls-remote https://github.com/MISP/misp-modules.git $MISP_MODULES_VERSION | cut -f1) && \
    curl --proto '=https' --tlsv1.3 --fail -sSL https://github.com/MISP/misp-modules/archive/$COMMIT.tar.gz | tar zx --strip-components=1 && \
    pip3 --no-cache-dir wheel --wheel-dir /wheels -r REQUIREMENTS && \
    echo $COMMIT > /misp-modules-commit

# Final image
FROM base
# Use system certificates for python requests library
ENV REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-bundle.crt
RUN dnf install -y --setopt=install_weak_deps=False libglvnd-glx poppler-cpp zbar ssdeep-devel && \
    rm -rf /var/cache/dnf && \
    mkdir /opt/misp-modules/
COPY --from=python-build /wheels /wheels
COPY --from=python-build /misp-modules-commit /opt/misp-modules/

ENV VIRTUAL_ENV=/opt/misp-modules/.venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

RUN pip3 --no-cache-dir install --no-warn-script-location /wheels/* sentry-sdk==1.5.1 && \
    echo "__all__ = ['cache', 'sentry']" > /opt/misp-modules/.venv/lib/python3.9/site-packages/misp_modules/helpers/__init__.py && \
    chmod -R u-w /opt/misp-modules/.venv/
COPY sentry.py /opt/misp-modules/.venv/lib/python3.9/site-packages/misp_modules/helpers/

RUN chgrp -R 0 /wheels/ && chmod -R g=u /wheels/
RUN chgrp -R 0 /opt/ && chmod -R g=u /home/

USER 1001

EXPOSE 6666/tcp
CMD ["/opt/misp-modules/.venv/bin/misp-modules", "-l", "0.0.0.0"]
HEALTHCHECK CMD curl -s -o /dev/null localhost:6666/modules
