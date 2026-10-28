# syntax=docker/dockerfile:1

FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/arrow-server ./cmd/arrow-server \
    && mkdir -p /out/data

# distroless/static ships CA certificates (needed for the Anthropic API and
# block list downloads) and runs as an unprivileged user.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/arrow-server /usr/local/bin/arrow-server
COPY --from=build --chown=nonroot:nonroot /out/data /data
ENV ARROW_ADDR=:8787 \
    ARROW_DATA_DIR=/data
EXPOSE 8787
VOLUME ["/data"]
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/arrow-server"]
