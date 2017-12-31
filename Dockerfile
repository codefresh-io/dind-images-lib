FROM docker:17.06-dind
RUN apk add bash --no-cache

WORKDIR /dind-images-lib
ADD . /dind-images-lib

CMD ["./run.sh"]
