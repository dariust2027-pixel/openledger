FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -o /openledger-server .

FROM alpine:3.20
COPY --from=build /openledger-server /usr/local/bin/openledger-server
EXPOSE 8420
ENTRYPOINT ["openledger-server"]
