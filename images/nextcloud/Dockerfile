FROM nextcloud:apache

# Inspired by https://github.com/nextcloud/docker/tree/master/.examples

RUN apt-get update && apt-get install -y \
    supervisor procps smbclient ffmpeg ghostscript libmagickcore-6.q16-6-extra libbz2-dev \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir /var/log/supervisord /var/run/supervisord

COPY supervisord.conf /

ENV NEXTCLOUD_UPDATE=1

CMD ["/usr/bin/supervisord", "-c", "/supervisord.conf"]