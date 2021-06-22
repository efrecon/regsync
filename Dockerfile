FROM alpine:3.14

LABEL MAINTAINER "efrecon+github@gmail.com"
LABEL org.opencontainers.image.title="regsync"
LABEL org.opencontainers.image.description="Selectively copy Docker images from source to destination registry"
LABEL org.opencontainers.image.authors="Emmanuel Frécon <efrecon+github@gmail.com>"
LABEL org.opencontainers.image.created=${BUILD_DATE}
LABEL org.opencontainers.image.url="https://github.com/Mitigram/regsync"
LABEL org.opencontainers.image.documentation="https://github.com/Mitigram/regsync/README.md"
LABEL org.opencontainers.image.source="https://github.com/Mitigram/regsync/Dockerfile"
LABEL org.opencontainers.image.vendor="Mitigram AB"
LABEL org.opencontainers.image.licenses="MIT"

ARG REG_VERSION=v0.16.0
ARG REG_SHA256=0470b6707ac68fa89d0cd92c83df5932c9822df7176fcf02d131d75f74a36a19
ARG GH_ROOT=https://github.com
ARG GH_PROJ=genuinetools/reg

# Add jq for quicker JSON parsing
RUN apk add --no-cache jq docker curl \
    && curl -fsqSL "${GH_ROOT%/}/${GH_PROJ}/releases/download/v${REG_VERSION#v}/reg-linux-amd64" -o "/usr/local/bin/reg" \
    && echo "${REG_SHA256}  /usr/local/bin/reg" | sha256sum -c - \
	  && chmod a+x "/usr/local/bin/reg"

ADD lib/mg.sh/ /usr/local/lib/mg.sh/
ADD sync.sh /usr/local/bin/

ENV MGSH_DIR=/usr/local/lib/mg.sh
ENTRYPOINT [ "/usr/local/bin/sync.sh" ]

CMD [ "--help" ]