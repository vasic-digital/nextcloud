sudo docker run \
  --init \
  --sig-proxy=false \
  --name nextcloud-aio-nezha \
  --restart always \
  --publish 8080:8080 \
  -e SKIP_DOMAIN_VALIDATION=true \
  -e APACHE_PORT=11000 \
  -e APACHE_IP_BINDING=127.0.0.1 \
  --volume nextcloud_aio_mastercontainer:/mnt/Nextcloud/Data \
  --volume /var/run/docker.sock:/mnt/Nextcloud/Container:ro \
  ghcr.io/nextcloud-releases/all-in-one:latest
