# Build stage
FROM golang:latest AS builder

RUN apk add --no-cache git

WORKDIR /app

# Copy go mod files
COPY go.mod go.sum ./
RUN go mod download

# Copy source
COPY . .

# Build the faker service
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o faker cmd/faker/main.go

# Final stage
FROM alpine:3.20

RUN apk --no-cache add ca-certificates wget

# Create data directory for persistent storage
RUN mkdir -p /data

WORKDIR /root/

# Copy the binary from builder
COPY --from=builder /app/faker .

# Expose port
EXPOSE 8080

# Run the faker service
CMD ["./faker"]