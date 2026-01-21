# Build stage
FROM golang:1.23-alpine AS builder

WORKDIR /app

# Install git for downloading dependencies
RUN apk add --no-cache git

# Copy go mod files
COPY go.mod go.sum* ./

# Download dependencies
RUN go mod download

# Copy source code
COPY . .

# Build the application
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o loadtest-db .

# Final stage
FROM alpine:3.19

WORKDIR /app

# Install ca-certificates for HTTPS connections
RUN apk --no-cache add ca-certificates tzdata

# Copy binary from builder
COPY --from=builder /app/loadtest-db .

# Set timezone
ENV TZ=Asia/Bangkok

# Environment variables (to be overridden)
ENV DB_HOST=localhost
ENV DB_PORT=5432
ENV DB_USER=postgres
ENV DB_PASSWORD=
ENV DB_NAME=postgres

# Run the application
CMD ["./loadtest-db"]
