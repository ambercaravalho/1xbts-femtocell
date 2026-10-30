# Same Debian release as fou-nat, so these rules are written by the same
# iptables-nft version (1.8.9) that fou-nat's entrypoint uses.
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends iptables \
 && rm -rf /var/lib/apt/lists/*

COPY rules.sh /usr/local/bin/rules.sh
RUN chmod 755 /usr/local/bin/rules.sh

ENTRYPOINT ["/usr/local/bin/rules.sh"]
