# Sync-Server des Personal Trackers V2 – kompiliert, ohne Dart-SDK im Laufzeit-Image.
FROM dart:stable AS bau
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY . .
RUN dart pub get --offline && dart compile exe bin/server.dart -o /src/pt-sync

FROM debian:stable-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-0 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home /daten pt \
 && mkdir /daten && chown pt /daten
COPY --from=bau /src/pt-sync /usr/local/bin/pt-sync
ENV PT_DB=/daten/sync.db PT_HOST=0.0.0.0 PT_PORT=8743
VOLUME /daten
USER pt
EXPOSE 8743
ENTRYPOINT ["/usr/local/bin/pt-sync"]
