# luahellper key server + paste host + dashboard
FROM python:3.12-slim
# lua5.4 powers the in-dashboard obfuscate button
RUN apt-get update && apt-get install -y --no-install-recommends lua5.4 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . /app
EXPOSE 8080
# $PORT is provided by the host (Render/Railway); falls back to 8080 locally
CMD ["python3", "server/keyserver.py", "serve", "--host", "0.0.0.0"]
