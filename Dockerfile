FROM quay.io/prometheus/node-exporter:v0.15.1 AS node-exporter

FROM docker:17.06-dind
COPY --from=node-exporter /bin/node_exporter /bin/

RUN apk add bash rsync --no-cache

WORKDIR /dind-images-lib
ADD . /dind-images-lib

CMD ["./run.sh"]
