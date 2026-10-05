## t2api: the T2 query service, as one static binary in an empty image.
##   docker compose build        (see docker-compose.yml)
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
## resolve + download dependencies (pure Go: no C compiler needed), then build static
RUN go mod tidy && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/t2api ./cmd/t2api \
 && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/loadtest ./cmd/loadtest \
 && go vet ./...

## nothing in the final image but the two binaries: no shell, no package manager
FROM scratch
COPY --from=build /out/t2api /t2api
COPY --from=build /out/loadtest /loadtest
USER 999:999
EXPOSE 8080
ENTRYPOINT ["/t2api"]
