## t2api: the T2 query service, as one static binary in an empty image.
##   docker compose build        (see docker-compose.yml)
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
COPY cmd ./cmd
## go.sum pins the dependency set: -mod=readonly fails the build rather than change go.mod/go.sum
## (pure Go: no C compiler needed)
RUN CGO_ENABLED=0 go build -mod=readonly -trimpath -ldflags "-s -w" -o /out/t2api ./cmd/t2api \
 && CGO_ENABLED=0 go build -mod=readonly -trimpath -ldflags "-s -w" -o /out/loadtest ./cmd/loadtest \
 && go vet -mod=readonly ./...

## nothing in the final image but the two binaries: no shell, no package manager
FROM scratch
COPY --from=build /out/t2api /t2api
COPY --from=build /out/loadtest /loadtest
USER 999:999
EXPOSE 8080
ENTRYPOINT ["/t2api"]
