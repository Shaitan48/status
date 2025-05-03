# status/Dockerfile
FROM python:3.11-alpine

WORKDIR /app
ENV PYTHONPATH=/app

COPY requirements.txt .
RUN apk update && \
    apk add --no-cache build-base libffi-dev openssl-dev && \
    pip install --no-cache-dir -r requirements.txt && \
    apk del build-base libffi-dev openssl-dev

# Копируем сначала код приложения (папку app)
COPY . .

# <<< ДОБАВЛЯЕМ СКРИПТ ENTRYPOINT >>>
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh # Делаем исполняемым ВНУТРИ контейнера

# Копируем остальное (например, .env, хотя он монтируется через volume)
# Эту строку можно даже убрать, если больше ничего не нужно копировать
# COPY .env . # Пример

EXPOSE 5000

# <<< УСТАНАВЛИВАЕМ ENTRYPOINT >>>
# Теперь при старте контейнера будет запускаться этот скрипт
ENTRYPOINT ["/app/entrypoint.sh"]

# Основная команда приложения (Gunicorn) остается в CMD.
# entrypoint.sh запустит её с помощью `exec "$@"`
CMD ["gunicorn", "-k", "eventlet", "-w", "1", "--bind", "0.0.0.0:5000", "wsgi:application"]