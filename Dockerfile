# build
FROM crystallang/crystal:0.34.0-alpine-build as build

WORKDIR /build

COPY shard.yml /build/
COPY shard.lock /build/
RUN mkdir src
COPY ./src /build/src

RUN shards
RUN shards build api --release --static

# prod
FROM alpine:3

WORKDIR /app
COPY --from=build /build/bin/api /app/api

EXPOSE 3000
CMD ["/app/api"]
