# Scansion (https://hg.prosody.im/scansion/), the XMPP integration test tool
# used by Prosody. Based on scansion's own Dockerfile, on a current Debian.
FROM debian:trixie-slim AS source
ARG SCANSION_REV=d6b61aa4f56b
RUN apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates mercurial \
	&& hg clone -r "$SCANSION_REV" https://hg.prosody.im/scansion/ /src

FROM debian:trixie-slim
RUN apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		lua5.2 lua-cjson lua-expat lua-filesystem lua-luaossl lua-sec lua-socket lua-unbound make \
	&& rm -rf /var/lib/apt/lists/* \
	&& ln -s /usr/bin/lua5.2 /usr/local/bin/lua
COPY --from=source /src /tmp/build
RUN cd /tmp/build \
	&& ./configure && make \
	&& install build/scansion /usr/local/bin/scansion \
	&& install -D -m 644 verse.lua /usr/local/share/lua/5.2/verse.lua \
	&& rm -rf /tmp/build
USER nobody
WORKDIR /scripts
ENTRYPOINT ["/usr/local/bin/scansion"]
