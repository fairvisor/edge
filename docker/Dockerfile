FROM openresty/openresty:1.25.3.2-jammy

RUN apt-get update && apt-get upgrade -y --no-install-recommends \
  && apt-get install -y --no-install-recommends \
  gettext-base \
  python3 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/fairvisor

RUN mkdir -p /etc/fairvisor /etc/nginx/iplists

COPY src /opt/fairvisor/src
COPY bin/generate_asn_type_map.py /opt/fairvisor/bin/generate_asn_type_map.py
COPY bin/generate_tor_exit_geo.py /opt/fairvisor/bin/generate_tor_exit_geo.py
COPY docker/nginx.conf.template /opt/fairvisor/nginx.conf.template
COPY docker/entrypoint.sh /opt/fairvisor/entrypoint.sh
RUN python3 /opt/fairvisor/bin/generate_asn_type_map.py --output /etc/fairvisor/asn_type.map
RUN python3 /opt/fairvisor/bin/generate_tor_exit_geo.py --output /etc/nginx/iplists/tor_exits.geo
RUN test -s /etc/fairvisor/asn_type.map && test -s /etc/nginx/iplists/tor_exits.geo

RUN chmod +x /opt/fairvisor/entrypoint.sh

ARG FAIRVISOR_EDGE_VERSION=0.1.0
RUN printf '%s\n' \
  '-- Edge runtime version (injected at image build time).' \
  "return \"${FAIRVISOR_EDGE_VERSION}\"" \
  > /opt/fairvisor/src/fairvisor/version.lua

ENV FAIRVISOR_SHARED_DICT_SIZE=128m \
    FAIRVISOR_LOG_LEVEL=info \
    FAIRVISOR_MODE=decision_service \
    FAIRVISOR_CONFIG_POLL_INTERVAL=30 \
    FAIRVISOR_HEARTBEAT_INTERVAL=5 \
    FAIRVISOR_EVENT_FLUSH_INTERVAL=60

EXPOSE 8080

ENTRYPOINT ["/opt/fairvisor/entrypoint.sh"]
