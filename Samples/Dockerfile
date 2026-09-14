FROM swift:6.3-noble AS build
WORKDIR /app

COPY Package.* ./
RUN swift package resolve

COPY Sources ./Sources
RUN swift build -c release --static-swift-stdlib

FROM ubuntu:noble
RUN apt-get update && apt-get install -y ca-certificates
COPY --from=build /app/.build/release/server /usr/local/bin/
EXPOSE 8080
CMD ["server"]
