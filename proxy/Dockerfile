FROM haproxy:2.8-alpine
USER root

RUN apk add --no-cache gettext bash curl

COPY haproxy.cfg.template /usr/local/etc/haproxy/haproxy.cfg.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5000 5001 7000

ENTRYPOINT ["/entrypoint.sh"]
