# Runbook: moving the bundled store from SeaweedFS to RustFS

For self-hosted installs on `deploy/production/compose.yaml` that keep page
images in the bundled store (ADR 0016). Installs on R2 or another external
store skip this.

RustFS can't read SeaweedFS's data, so the new release gives it a new,
empty volume (`objects`) and leaves the old one (`objdata`) alone. The old
store runs once more beside the new one, and the objects are copied from one
to the other directly, which keeps each object's `Content-Type`. Until the
copy is done, page images are missing; nothing else is affected. Plan for
some downtime.

Run each step in `deploy/production`. The commands assume the Compose
project is named `libarrie` (the default), so the network is
`libarrie_default` and the old volume `libarrie_objdata`.

## 1. Back up

Take a full backup first (database, `objdata` volume and `.env`), as
`docs/self-hosting.md` describes.

## 2. Stop writes

Still on the old release:

```sh
docker compose stop api worker
```

## 3. Start RustFS

Update the checkout to the new release, then start only the new store:

```sh
docker compose pull
docker compose up -d objectstore
```

## 4. Start the old store beside it

```sh
docker run -d --name libarrie-seaweedfs-old --network libarrie_default \
  -v libarrie_objdata:/data --env-file .env --entrypoint /bin/sh \
  chrislusf/seaweedfs:4.48 -c '
    printf "{\"identities\":[{\"name\":\"libarrie\",\"credentials\":[{\"accessKey\":\"%s\",\"secretKey\":\"%s\"}],\"actions\":[\"Admin\",\"Read\",\"Write\",\"List\",\"Tagging\"]}]}" \
      "$S3_ACCESS_KEY_ID" "$S3_SECRET_ACCESS_KEY" > /tmp/s3.json
    exec weed server -dir=/data -ip.bind=0.0.0.0 -s3 -s3.port=8333 -s3.config=/tmp/s3.json'
```

Wait about 15 seconds for it to start.

## 5. Copy

```sh
set -a; . ./.env; set +a
docker run --rm --network libarrie_default \
  -e RCLONE_CONFIG_OLD_TYPE=s3 -e RCLONE_CONFIG_OLD_PROVIDER=Other \
  -e RCLONE_CONFIG_OLD_ENDPOINT=http://libarrie-seaweedfs-old:8333 \
  -e RCLONE_CONFIG_OLD_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" \
  -e RCLONE_CONFIG_OLD_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" \
  -e RCLONE_CONFIG_NEW_TYPE=s3 -e RCLONE_CONFIG_NEW_PROVIDER=Other \
  -e RCLONE_CONFIG_NEW_ENDPOINT=http://objectstore:8333 \
  -e RCLONE_CONFIG_NEW_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" \
  -e RCLONE_CONFIG_NEW_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" \
  rclone/rclone:1.71.0 copy old: new: --checksum --metadata --progress
```

This copies every bucket: `libarrie` and, unless `JOURNAL_S3_*` points
elsewhere, `libarrie-journal`. To confirm, run the same command with
`check old: new: --one-way` in place of `copy … --progress`; it reports
`0 differences found`.

## 6. Finish

```sh
docker rm -f libarrie-seaweedfs-old
docker compose up -d
docker compose run --rm api storage-check
```

Open a notebook and check that page images load. Once you're satisfied,
and you have a backup, remove the old volume:

```sh
docker volume rm libarrie_objdata
```
