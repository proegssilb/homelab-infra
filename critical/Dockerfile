FROM alpine:latest

RUN apk add --no-cache grub-bios grub-efi mtools xorriso p7zip bash curl openssl

RUN mkdir -p /app
WORKDIR /app
VOLUME /app

COPY generate-k3os-isos.sh /bin

CMD generate-k3os-isos.sh
